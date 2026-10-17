from __future__ import annotations 

# Inlined support modules: this script runs without sibling Python files.

from collections import OrderedDict
from concurrent.futures import Future, TimeoutError as FutureTimeoutError
import ipaddress
import math
import queue
import socket
import threading
import time


class DNSLookupError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status =status


class DNSResolver:
    def __init__(self, max_workers=4, max_queue=16, max_records=512,
                 success_ttl=60.0, failure_ttl=2.0, lookup=None, clock=None):
        self.max_workers =max(1, min(4, int(max_workers)))
        self.max_queue =max(1, min(16, int(max_queue)))
        self.max_records =max(1, min(512, int(max_records)))
        self.success_ttl =max(0.0, min(60.0, float(success_ttl)))
        self.failure_ttl =max(0.0, min(2.0, float(failure_ttl)))
        self._lookup =lookup or socket.getaddrinfo
        self._clock =clock or time.monotonic
        self._lock =threading.Lock()
        self._queue =queue.Queue(maxsize=self.max_queue)
        self._stop =threading.Event()
        self._workers =[]
        self._inflight ={}
        self._cache =OrderedDict()
        self._active =0
        self._counts ={
            'submitted': 0, 'shared': 0, 'cache_hits': 0, 'timeouts': 0,
            'rejected': 0, 'completed': 0, 'failed': 0,
        }

    def resolve(self, host, port, timeout=3.0):
        timeout =float(timeout)
        if not math.isfinite(timeout) or timeout <0:
            raise ValueError('DNS timeout must be finite and nonnegative')
        deadline =self._clock() +timeout
        if not isinstance(host, str) or not host or '\x00' in host:
            raise DNSLookupError('invalid DNS hostname')
        # URL parsers normally remove IPv6 brackets. Accept them here as well.
        literal =host[1:-1] if host.startswith('[') and host.endswith(']') else host
        try:
            return [str(ipaddress.ip_address(literal))]
        except ValueError:
            pass
        try:
            normalized =host.rstrip('.').encode('idna').decode('ascii').lower()
            port =int(port)
            if not normalized or len(normalized) >253 or not 1 <=port <=65535:
                raise ValueError('invalid DNS query')
        except (UnicodeError, TypeError, ValueError) as error:
            raise DNSLookupError('invalid DNS query') from error
        key =(normalized, port)
        with self._lock:
            if self._stop.is_set():
                raise DNSLookupError('DNS resolver is closed', status=503)
            now =self._clock()
            cached =self._cache.get(key)
            if cached is not None:
                expires, addresses, error =cached
                if now <expires:
                    self._cache.move_to_end(key)
                    self._counts['cache_hits'] +=1
                    if error is not None:
                        raise DNSLookupError(str(error), status=error.status)
                    return list(addresses)
                self._cache.pop(key, None)
            future =self._inflight.get(key)
            if future is not None:
                self._counts['shared'] +=1
            else:
                future =Future()
                self._inflight[key] =future
                # Workers are daemon threads and created only for outstanding
                # demand. They may remain stuck in libc without blocking exit.
                try:
                    self._start_workers_locked()
                    self._queue.put_nowait((key, future))
                except queue.Full:
                    self._inflight.pop(key, None)
                    future.cancel()
                    self._counts['rejected'] +=1
                    raise DNSLookupError('DNS lookup capacity exhausted', status=503)
                except Exception as error:
                    self._inflight.pop(key, None)
                    future.cancel()
                    self._counts['rejected'] +=1
                    raise DNSLookupError('cannot start DNS worker', status=503) from error
                self._counts['submitted'] +=1
        try:
            return list(future.result(timeout=max(0.0, deadline -self._clock())))
        except FutureTimeoutError as error:
            with self._lock:
                self._counts['timeouts'] +=1
            raise DNSLookupError('DNS lookup timed out', status=504) from error
        except DNSLookupError as error:
            # Do not reuse traceback-bearing exception instances between callers.
            raise DNSLookupError(str(error), status=error.status) from error

    def _start_workers_locked(self):
        desired =min(self.max_workers, len(self._inflight))
        while len(self._workers) <desired:
            worker =threading.Thread(target=self._worker, daemon=True,
                                    name=f'ysp-dns-{id(self):x}-{len(self._workers) +1}')
            worker.start()
            self._workers.append(worker)

    def _worker(self):
        while not self._stop.is_set():
            try:
                key, future =self._queue.get(timeout=0.1)
            except queue.Empty:
                continue
            with self._lock:
                skip =self._stop.is_set() or future.done()
                if not skip:
                    self._active +=1
            if skip:
                self._queue.task_done()
                continue
            addresses, failure =None, None
            try:
                records =self._lookup(key[0], key[1], type=socket.SOCK_STREAM)
                addresses =tuple(dict.fromkeys(str(ipaddress.ip_address(record[4][0])) for record in records))
                if not addresses:
                    raise DNSLookupError('DNS response contained no addresses')
            except Exception as error:
                failure =error if isinstance(error, DNSLookupError) else DNSLookupError('DNS lookup failed')
            finally:
                with self._lock:
                    self._active -=1
                    if self._inflight.get(key) is future:
                        self._inflight.pop(key, None)
                    if not self._stop.is_set():
                        ttl =self.failure_ttl if failure is not None else self.success_ttl
                        if ttl >0.0:
                            self._cache[key] =(self._clock() +ttl, addresses, failure)
                            self._cache.move_to_end(key)
                            self._trim_cache_locked()
                        self._counts['completed'] +=1
                        if failure is not None:
                            self._counts['failed'] +=1
                    if not future.done():
                        if failure is not None:
                            future.set_exception(failure)
                        else:
                            future.set_result(addresses)
                self._queue.task_done()

    def _trim_cache_locked(self):
        now =self._clock()
        for key, cached in list(self._cache.items()):
            if cached[0] <=now:
                self._cache.pop(key, None)
        while len(self._cache) >self.max_records:
            self._cache.popitem(last=False)

    def clear_cache(self):
        with self._lock:
            self._cache.clear()

    def stats(self):
        with self._lock:
            return dict(self._counts, active=self._active,
                        queued=self._queue.qsize(), inflight=len(self._inflight),
                        cached=len(self._cache), workers=len(self._workers),
                        closed=self._stop.is_set())

    def close(self):
        """Wake callers immediately; blocked libc calls stay on daemon threads."""
        with self._lock:
            self._stop.set()
            self._cache.clear()
            for future in self._inflight.values():
                if not future.done():
                    future.set_exception(DNSLookupError('DNS resolver is closed', status=503))
            self._inflight.clear()
            while True:
                try:
                    self._queue.get_nowait()
                    self._queue.task_done()
                except queue.Empty:
                    break


_default_resolver =None
_default_lock =threading.Lock()


def bounded_dns_addresses(host, port, timeout=3.0):
    global _default_resolver
    with _default_lock:
        if _default_resolver is None:
            _default_resolver =DNSResolver()
        resolver =_default_resolver
    return resolver.resolve(host, port, timeout=timeout)

from concurrent.futures import Future
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass
import json
import os
import tempfile
import threading
import time


class ThreadPoolExecutor:
    """Bounded daemon pool implementing the service's Executor API.

    A system network call cannot be killed safely. Daemon workers deliberately
    avoid the standard thread pool's interpreter-exit join, while Future states
    and cancellation retain the usual running/pending distinction.
    """
    def __init__(self, max_workers=None, thread_name_prefix='', *, max_queue=128):
        if max_workers is None:
            max_workers =min(32, (os.cpu_count() or 1) +4)
        if not isinstance(max_workers, int) or max_workers <=0:
            raise ValueError('max_workers must be a positive integer')
        self._max_workers =max_workers
        self._max_queue =max(1, min(128, int(max_queue)))
        self._prefix =thread_name_prefix or 'ysp-worker'
        self._condition =threading.Condition()
        self._tasks =deque()
        self._threads =[]
        self._active =0
        self._shutdown =False

    def submit(self, fn, /, *args, **kwargs):
        with self._condition:
            if self._shutdown:
                raise RuntimeError('cannot schedule new futures after shutdown')
            if len(self._tasks) >=self._max_queue:
                raise RuntimeError('worker queue capacity exhausted')
            future =Future()
            task =(future, fn, args, kwargs)
            self._tasks.append(task)
            desired =min(self._max_workers, self._active +len(self._tasks))
            try:
                while len(self._threads) <desired:
                    worker =threading.Thread(target=self._worker, daemon=True,
                                            name=f'{self._prefix}_{len(self._threads)}')
                    worker.start()
                    self._threads.append(worker)
            except Exception as error:
                # Workers cannot take this task while we hold the condition.
                # Keep previously started workers and their accepted tasks.
                self._tasks.remove(task)
                future.cancel()
                self._condition.notify_all()
                raise RuntimeError('cannot start worker thread') from error
            self._condition.notify()
            return future

    def _worker(self):
        while True:
            with self._condition:
                while not self._tasks:
                    if self._shutdown:
                        return
                    self._condition.wait()
                future, fn, args, kwargs =self._tasks.popleft()
                self._active +=1
            try:
                if future.set_running_or_notify_cancel():
                    try:
                        result =fn(*args, **kwargs)
                    except BaseException as error:
                        future.set_exception(error)
                    else:
                        future.set_result(result)
            finally:
                with self._condition:
                    self._active -=1
                    self._condition.notify_all()

    def shutdown(self, wait=True, *, cancel_futures=False):
        cancelled =[]
        with self._condition:
            self._shutdown =True
            if cancel_futures:
                while self._tasks:
                    cancelled.append(self._tasks.popleft()[0])
            workers =list(self._threads)
            self._condition.notify_all()
        # Future callbacks may acquire application locks or call back into this
        # executor, so run them after releasing the queue condition.
        for future in cancelled:
            future.cancel()
        if wait:
            for worker in workers:
                if worker is not threading.current_thread():
                    worker.join()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.shutdown(wait=True)
        return False


@dataclass
class RawPlaylist:
    source_key: tuple
    body: str
    content_type: str
    cached_at: float
    expires_at: float
    stale_until: float


_path_locks = {}
_path_locks_lock = threading.Lock()
_persistence_errors = {}


@contextmanager
def persistence_lock(path):
    path = os.path.abspath(path)
    with _path_locks_lock:
        lock = _path_locks.setdefault(path, threading.RLock())
    with lock:
        yield


def persistence_error(path, error):
    with _path_locks_lock:
        _persistence_errors[os.path.abspath(path)] = {
            "error": str(error), "at": time.time()
        }


def persistence_status():
    with _path_locks_lock:
        return {path: dict(value) for path, value in _persistence_errors.items()}


def atomic_json_write(path, payload):
    """Serialize concurrent writers, use a unique inode, and atomically publish."""
    path = os.path.abspath(path)
    with persistence_lock(path):
        parent = os.path.dirname(path)
        os.makedirs(parent, exist_ok=True)
        temporary = None
        try:
            descriptor, temporary = tempfile.mkstemp(
                prefix="." + os.path.basename(path) + ".", suffix=".tmp", dir=parent
            )
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, indent=2, ensure_ascii=False, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            temporary = None
            # Directory fsync is supported on POSIX, but not all deployment OSes.
            if hasattr(os, "O_DIRECTORY"):
                directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
        except Exception as error:
            persistence_error(path, error)
            raise
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass

import dataclasses
import datetime
import functools
import hashlib
import math
import re
import urllib.parse

_URI = re.compile(r'(?P<name>\b(?:URI|SERVER-URI))=(?:"(?P<quoted>[^"]*)"|(?P<plain>[^\s,]+))')
_ATTR = re.compile(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)')
_VOLATILE = {'sig', 'signature', 'sign', 'token', 'auth', 'auth_key', 'expires', 'expire', 'wssecret', 'wstime', 'txsecret', 'txtime', 'upt', 'vkey'}
_GLOBAL = ('#EXTM3U', '#EXT-X-VERSION:', '#EXT-X-TARGETDURATION:', '#EXT-X-MEDIA-SEQUENCE:', '#EXT-X-DISCONTINUITY-SEQUENCE:', '#EXT-X-PLAYLIST-TYPE:', '#EXT-X-INDEPENDENT-SEGMENTS', '#EXT-X-START:', '#EXT-X-SERVER-CONTROL:', '#EXT-X-DEFINE:')

class UnsafePlaylist(ValueError):
    pass

def attributes(line):
    return {k: v.strip('"') for k, v in _ATTR.findall(line.partition(':')[2])}

def rewrite_uris(text, base_url, mapper=None):
    """Resolve every URI against its effective response URL, including tag attributes."""
    def absolute(value):
        resolved = urllib.parse.urljoin(base_url, value)
        return mapper(resolved) if mapper and urllib.parse.urlsplit(resolved).scheme in ('http', 'https') else resolved
    out = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith('#'):
            line = _URI.sub(lambda m: m.group('name') + '="' + absolute(m.group('quoted') if m.group('quoted') is not None else m.group('plain')) + '"', line)
        elif s:
            line = absolute(s)
        out.append(line)
    return '\n'.join(out) + ('\n' if text.endswith(('\n', '\r')) else '')

def select_variant(text, quality='fhd'):
    """Highest available rendition for best; preserve independent media groups."""
    variants = analyze_playlist(text).variants
    if not variants or any(v.external_groups for v in variants):
        return None
    quality = (quality or 'best').lower()
    if quality == 'auto':
        return None
    if quality == 'best':
        return max(variants, key=lambda v: (v.profile.height, v.profile.width, v.profile.bandwidth)).uri
    cap = {'sd': 576, 'hd': 720, 'shd': 720, 'fhd': 1080, 'uhd': 2160, '4k': 2160, '8k': 4320, 'stable': 720}.get(quality)
    if cap:
        within = [v for v in variants if 0 < v.profile.height <= cap]
        if within:
            return max(within, key=lambda v: (v.profile.height, v.profile.bandwidth)).uri
        measured = [v for v in variants if v.profile.height]
        if measured:
            return min(measured, key=lambda v: (v.profile.height, v.profile.bandwidth)).uri
    budget = {'shd': 3_000_000, 'hd': 3_000_000, 'stable': 3_000_000, 'sd': 1_500_000}.get(quality, 8_000_000)
    within = [v for v in variants if v.profile.bandwidth <= budget]
    return (max(within, key=lambda v: v.profile.bandwidth) if within else min(variants, key=lambda v: v.profile.bandwidth)).uri


def filter_master_quality(text, quality='best'):
    """Keep one video rendition and all media groups; do not orphan independent audio."""
    if not text:
        return text
    analysis = analyze_playlist(text)
    if not analysis.variants or quality == 'auto':
        return text
    variants = analysis.variants
    if quality == 'best':
        selected = max(variants, key=lambda v: (v.profile.height, v.profile.width, v.profile.bandwidth))
    else:
        cap = {'fhd': 1080, 'shd': 720, 'hd': 720, 'sd': 576}.get(quality)
        measured = [v for v in variants if v.profile.height]
        within = [v for v in measured if cap and v.profile.height <= cap]
        if within:
            selected = max(within, key=lambda v: (v.profile.height, v.profile.bandwidth))
        elif measured and cap:
            selected = min(measured, key=lambda v: (v.profile.height, v.profile.bandwidth))
        else:
            budget = 3_000_000 if quality in ('shd', 'hd', 'sd') else 8_000_000
            within = [v for v in variants if v.profile.bandwidth <= budget]
            selected = max(within, key=lambda v: v.profile.bandwidth) if within else min(variants, key=lambda v: v.profile.bandwidth)
    wanted, index, pending, out = variants.index(selected), -1, [], []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith('#EXT-X-STREAM-INF:'):
            index += 1
            pending = [raw]
        elif pending:
            pending.append(raw)
            if line and not line.startswith('#'):
                if index == wanted:
                    out.extend(pending)
                pending = []
        else:
            out.append(raw)
    result = '\n'.join(out) + '\n'
    if result != text:
        remember_playlist_profile(result, selected.profile)
    return result


def pdt_seconds(value):
    if not value:
        return None
    try:
        dt = datetime.datetime.fromisoformat(value[:-1] + '+00:00' if value.upper().endswith('Z') else value)
        if dt.tzinfo is None:
            return None  # HLS PDT requires an explicit zone.
        return dt.timestamp()
    except (TypeError, ValueError, OverflowError):
        return None

def stable_uri(uri, _depth=0):
    p = urllib.parse.urlsplit(uri)
    # Opaque gateway tokens can rotate while the underlying segment stays unchanged.
    if _depth < 2:
        query_parts = urllib.parse.parse_qs(p.query)
        if p.path in ('/proxy', '/proxy.ts', '/engine_proxy') and query_parts.get('resource'):
            try:
                return stable_uri(resolve_resource(query_parts['resource'][0]).url, _depth + 1)
            except (ProxyError, NameError):
                pass
        if p.path == '/segment' and p.hostname in ('127.0.0.1', 'localhost') and query_parts.get('url'):
            return stable_uri(query_parts['url'][0], _depth + 1)
    # Preserve query parameters that may identify the media itself.
    query = urllib.parse.urlencode([(k, v) for k, v in urllib.parse.parse_qsl(p.query, keep_blank_values=True) if k.lower() not in _VOLATILE])
    return urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, query, ''))

@dataclasses.dataclass(frozen=True)
class Segment:
    source_sequence: int
    duration: float
    pdt: str
    uri: str
    tags: list[str]
    key: str | None
    init_map: str | None
    byte_range: str | None
    discontinuity: int = 0

    @functools.cached_property
    def identity(self):
        stamp = pdt_seconds(self.pdt)
        if stamp is not None:
            return ('pdt', round(stamp, 6), self.byte_range)
        return ('uri', stable_uri(self.uri), self.byte_range)

@dataclasses.dataclass(frozen=True)
class MediaPlaylist:
    headers: list[str]
    segments: list[Segment]
    trailing: list[str]
    sequence: int = 0
    discontinuity_sequence: int = 0
    target: float = 6.0
    unsafe: bool = False
    original_text: str = ''


def _parse_media_uncached(text):
    if '#EXT-X-STREAM-INF:' in text or '#EXT-X-I-FRAME-STREAM-INF:' in text:
        return None
    headers, pending, segments, trailing = [], [], [], []
    sequence, discontinuity_sequence, duration, target = 0, 0, 6.0, 6.0
    key = init_map = byte_range = None
    pdt = ''
    inherited_pdt = None
    range_end, range_uri = None, None
    unsafe = False
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith(('#EXT-X-PART:', '#EXT-X-PRELOAD-HINT:', '#EXT-X-SKIP:', '#EXT-X-RENDITION-REPORT:')):
            unsafe = True
        if s.startswith('#EXT-X-MEDIA-SEQUENCE:'):
            sequence = int(s.partition(':')[2])
            if sequence < 0 or sequence >= 2 ** 128:
                raise UnsafePlaylist('invalid media sequence')
            headers.append(s)
        elif s.startswith('#EXT-X-DISCONTINUITY-SEQUENCE:'):
            discontinuity_sequence = int(s.partition(':')[2])
            headers.append(s)
        elif s.startswith('#EXT-X-TARGETDURATION:'):
            target = float(s.partition(':')[2])
            if not math.isfinite(target) or target <= 0:
                raise UnsafePlaylist('invalid target duration')
            headers.append(s)
        elif s.startswith('#EXTINF:'):
            duration = float(s.partition(':')[2].split(',')[0])
            if not math.isfinite(duration) or duration <= 0:
                raise UnsafePlaylist('invalid segment duration')
            pending.append(s)
        elif s.startswith('#EXT-X-PROGRAM-DATE-TIME:'):
            pdt = s.partition(':')[2]
            inherited_pdt = pdt_seconds(pdt)
            pending.append(s)
        elif s.startswith('#EXT-X-KEY:'):
            key = s
            pending.append(s)
        elif s.startswith('#EXT-X-MAP:'):
            init_map = s
            pending.append(s)
        elif s.startswith('#EXT-X-BYTERANGE:'):
            byte_range = s.partition(':')[2]
            pending.append(s)
        elif s.startswith('#EXT-X-ENDLIST'):
            trailing.append(s)
        elif any(s.startswith(prefix) for prefix in _GLOBAL):
            headers.append(s)
        elif s.startswith('#'):
            pending.append(s)
        else:
            if not any(t.startswith('#EXTINF:') for t in pending):
                unsafe = True
            actual_range = byte_range
            if byte_range:
                match = re.fullmatch(r'(\d+)(?:@(\d+))?', byte_range)
                if not match:
                    unsafe = True
                else:
                    length = int(match.group(1))
                    offset = int(match.group(2)) if match.group(2) is not None else range_end
                    if offset is None or (match.group(2) is None and range_uri != s):
                        unsafe = True
                    else:
                        actual_range = f'{length}@{offset}'
                        range_end, range_uri = offset + length, s
            else:
                range_end, range_uri = None, None
            if not pdt and inherited_pdt is not None:
                pdt = datetime.datetime.fromtimestamp(inherited_pdt, datetime.timezone.utc).isoformat()
            segments.append(Segment(sequence + len(segments), duration, pdt, s, tuple(pending), key, init_map, actual_range, pending.count('#EXT-X-DISCONTINUITY')))
            if inherited_pdt is not None:
                inherited_pdt += duration
            pending, pdt, byte_range = [], '', None
    trailing = pending + trailing
    return MediaPlaylist(tuple(headers), tuple(segments), tuple(trailing), sequence, discontinuity_sequence, target, unsafe, text)


def render_media(media, segments=None, sequences=None, *, live=False, boundary=None, discontinuity_base=None):
    """Render complete segment state; make AES-128 implicit IV explicit before renumbering."""
    if media.unsafe:
        raise UnsafePlaylist('playlist requires passthrough (LL-HLS or incomplete segment metadata)')
    segments = list(media.segments if segments is None else segments)
    if not segments:
        raise UnsafePlaylist('empty media playlist')
    sequences = list(range(segments[0].source_sequence, segments[0].source_sequence + len(segments))) if sequences is None else list(sequences)
    if len(sequences) != len(segments) or any(b != a + 1 for a, b in zip(sequences, sequences[1:])):
        raise UnsafePlaylist('non-contiguous output sequence')
    out = []
    for line in media.headers:
        if line.startswith(('#EXT-X-MEDIA-SEQUENCE:', '#EXT-X-DISCONTINUITY-SEQUENCE:')):
            continue
        if live and line.startswith(('#EXT-X-PLAYLIST-TYPE:', '#EXT-X-START:')):
            continue
        if line.startswith('#EXT-X-TARGETDURATION:'):
            line = '#EXT-X-TARGETDURATION:' + str(math.ceil(max(media.target, max(s.duration for s in segments))))
        out.append(line)
    if '#EXTM3U' not in out:
        out.insert(0, '#EXTM3U')
    if not any(s.startswith('#EXT-X-TARGETDURATION:') for s in out):
        out.append('#EXT-X-TARGETDURATION:' + str(math.ceil(max(s.duration for s in segments))))
    out.append('#EXT-X-MEDIA-SEQUENCE:' + str(sequences[0]))
    disc_base = media.discontinuity_sequence if discontinuity_base is None else discontinuity_base
    first_index = next((i for i, s in enumerate(media.segments) if s.identity == segments[0].identity), 0)
    omitted = sum(s.discontinuity for s in media.segments[:first_index])
    out.append('#EXT-X-DISCONTINUITY-SEQUENCE:' + str(disc_base + omitted))
    previous_key = previous_map = None
    for segment, output_seq in zip(segments, sequences):
        key = segment.key
        if key:
            attr = attributes(key)
            method = attr.get('METHOD')
            if method not in ('NONE', 'AES-128') and output_seq != segment.source_sequence:
                raise UnsafePlaylist('cannot renumber this encryption method')
            if method == 'AES-128' and 'IV' not in attr:
                if attr.get('KEYFORMAT', 'identity') != 'identity' or segment.init_map:
                    raise UnsafePlaylist('cannot infer initialization-map encryption IV')
                key += ',IV=0x' + format(segment.source_sequence, '032x')
        if boundary is not None and output_seq == boundary and '#EXT-X-DISCONTINUITY' not in segment.tags:
            out.append('#EXT-X-DISCONTINUITY')
        if key != previous_key:
            if key:
                out.append(key)
            elif previous_key:
                out.append('#EXT-X-KEY:METHOD=NONE')
            previous_key = key
        if segment.init_map != previous_map:
            if segment.init_map:
                out.append(segment.init_map)
            previous_map = segment.init_map
        if segment.pdt and not any(tag.startswith('#EXT-X-PROGRAM-DATE-TIME:') for tag in segment.tags):
            out.append('#EXT-X-PROGRAM-DATE-TIME:' + segment.pdt)
        for tag in segment.tags:
            if tag.startswith(('#EXT-X-KEY:', '#EXT-X-MAP:', '#EXT-X-BYTERANGE:')):
                continue
            out.append(tag)
        if segment.byte_range:
            # Explicit offsets make a trimmed first segment independently interpretable.
            out.append('#EXT-X-BYTERANGE:' + segment.byte_range)
        out.append(segment.uri)
    out.extend(t for t in media.trailing if not live or t != '#EXT-X-ENDLIST')
    return '\n'.join(out) + '\n'


import collections


@dataclasses.dataclass(frozen=True)
class StreamProfile:
    width: int = 0
    height: int = 0
    bandwidth: int = 0
    codecs: str = ''
    audio_group: str = ''

    @property
    def resolution(self):
        return f'{self.width}x{self.height}' if self.width and self.height else None


@dataclasses.dataclass(frozen=True)
class Variant:
    uri: str
    profile: StreamProfile
    external_groups: bool = False


def _manifest_variants(text):
    pending, variants = None, []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith('#EXT-X-STREAM-INF:'):
            pending = attributes(line)
        elif line and not line.startswith('#') and pending is not None:
            resolution = re.fullmatch(r'(\d+)x(\d+)', pending.get('RESOLUTION', '').lower())
            try:
                width, height = map(int, resolution.groups()) if resolution else (0, 0)
                bandwidth = max(0, int(pending.get('AVERAGE-BANDWIDTH', pending.get('BANDWIDTH', 0))))
            except (ValueError, OverflowError):
                width, height, bandwidth = 0, 0, 0
            profile = StreamProfile(width, height, bandwidth, pending.get('CODECS', ''), pending.get('AUDIO', ''))
            variants.append(Variant(line, profile, any(pending.get(k) for k in ('AUDIO', 'VIDEO', 'SUBTITLES'))))
            pending = None
    return tuple(variants)


@dataclasses.dataclass(frozen=True)
class PlaylistAnalysis:
    media: MediaPlaylist | None
    signature: str | None
    target: float
    variants: tuple
    profile: StreamProfile = StreamProfile()
    body_digest: bytes = b''
    validation_error: str = ''


class PlaylistAnalysisCache:
    """Immutable parse results; one parse per shared body, conservative byte charges."""
    def __init__(self, max_entries=128, max_bytes=8 * 2**20, ttl=15, clock=time.monotonic):
        self.lock = threading.RLock()
        self.entries = collections.OrderedDict()
        self.max_entries, self.max_bytes, self.ttl, self.clock = max_entries, max_bytes, ttl, clock
        self.charged_bytes = self.hits = self.misses = self.parses = 0

    def get(self, text):
        with self.lock:
            now = self.clock()
            item = self.entries.get(text)
            if item and item[1] > now:
                self.entries.move_to_end(text)
                self.hits += 1
                return item[0]
            if item:
                self.charged_bytes -= self.entries.pop(text)[2]
            self.misses += 1
            if len(text) > 2 * 2**20 or text.count('\n') > 8192:
                raise UnsafePlaylist('playlist analysis budget exceeded')
            encoded = text.encode('utf-8')
            if len(encoded) > 2 * 2**20:
                raise UnsafePlaylist('playlist analysis budget exceeded')
            media = _parse_media_uncached(text)
            self.parses += 1
            variants = _manifest_variants(text) if media is None else ()
            signature, target = None, media.target if media else 6.0
            if media and media.segments:
                last = media.segments[-1]
                signature = hashlib.sha256(repr((last.source_sequence, last.identity)).encode()).hexdigest()
            profile = max((v.profile for v in variants), key=lambda p: (p.height, p.width, p.bandwidth), default=StreamProfile())
            header = text.lstrip('\ufeff \t\r\n')
            line_end = header.find('\n')
            header = header[:line_end] if line_end >= 0 else header
            valid_header = header.strip() == '#EXTM3U'
            has_media = bool(variants or (media and media.segments))
            has_parts = bool(media and media.unsafe and any(
                line.strip().startswith('#EXT-X-PART:') and attributes(line.strip()).get('URI')
                for line in text.splitlines()))
            validation_error = 'source did not return an HLS document' if not valid_header else ('source playlist contains no playable media' if not has_media and not has_parts else '')
            analysis = PlaylistAnalysis(media, signature, target, variants, profile, hashlib.sha256(encoded).digest(), validation_error)
            # Includes copies of tag/URI strings, segment containers, identities and dict overhead.
            charge = 8192 + len(encoded) * 8 + (len(media.segments) * 768 if media else len(variants) * 768)
            while self.entries and (len(self.entries) >= self.max_entries or self.charged_bytes + charge > self.max_bytes):
                self.charged_bytes -= self.entries.popitem(last=False)[1][2]
            if charge <= self.max_bytes and self.max_entries > 0:
                self.entries[text] = (analysis, now + self.ttl, charge)
                self.charged_bytes += charge
            return analysis

    def remember_profile(self, text, profile):
        self.get(text)
        with self.lock:
            item = self.entries.get(text)
            if item:
                self.entries[text] = (dataclasses.replace(item[0], profile=profile), item[1], item[2])

    def stats(self):
        with self.lock:
            return {'entries': len(self.entries), 'charged_bytes': self.charged_bytes,
                    'budget_bytes': self.max_bytes, 'hits': self.hits, 'misses': self.misses, 'parses': self.parses}


playlist_analysis_cache = PlaylistAnalysisCache()


def analyze_playlist(text):
    return playlist_analysis_cache.get(text)


def parse_media(text):
    return analyze_playlist(text).media


def remember_playlist_profile(text, profile):
    playlist_analysis_cache.remember_profile(text, profile)


def media_signature(text):
    analysis = analyze_playlist(text)
    return analysis.signature, analysis.target

import base64
import collections
import dataclasses
import hashlib
import http.client
import ipaddress
import json
import os
import re
import secrets
import socket
import ssl
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import ThreadingHTTPServer

DEFAULT_SUFFIXES = ('.cctv.cn', '.cctv.com', '.cctvpic.com', '.citvc.com',
    '.yangshipin.cn', '.cntv.cn', '.cntv.com', '.myqcloud.com', '.qqlive.com',
    '.gtimg.cn', '.smtcdns.net', '.smtcdns.com', '.tcdnlive.com', '.alicdn.com',
    '.alikunlun.com', '.wscdns.com', '.chinanetcenter.com', '.bdydns.com',
    '.ksyungslb.com', '.ks-cdn.com')
PASS_HEADERS = {'content-type', 'content-length', 'content-range', 'accept-ranges',
    'etag', 'last-modified', 'content-encoding'}
SENSITIVE = {'authorization', 'cookie', 'uid', 'appid', 'apprandomstr', 'appsign'}
_TLS_CONTEXT = ssl.create_default_context()


class ProxyError(Exception):
    def __init__(self, status, message, category=''):
        super().__init__(message)
        self.status, self.category = status, category


@dataclasses.dataclass(frozen=True)
class Resource:
    url: str
    headers: dict
    channel: str = ''
    generation: int = 0


class ResourceRegistry:
    def __init__(self, limit=16384, ttl=600):
        self.limit, self.ttl = limit, ttl
        self.lock = threading.Lock()
        self.entries = collections.OrderedDict()
        self.secret = secrets.token_bytes(32)

    def register(self, url, headers=None, channel='', generation=0):
        headers = dict(headers or {})
        signature = json.dumps([url, sorted(headers.items()), channel, generation], separators=(',', ':'))
        # Opaque capabilities are generated by the server, never accepted as arbitrary URLs.
        digest = hashlib.blake2s(signature.encode(), key=self.secret, digest_size=24).digest()
        token = base64.urlsafe_b64encode(digest).decode().rstrip('=')
        now = time.monotonic()
        with self.lock:
            self.entries[token] = (Resource(url, headers, channel, generation), now + self.ttl)
            self.entries.move_to_end(token)
            while self.entries and (len(self.entries) > self.limit or next(iter(self.entries.values()))[1] <= now):
                self.entries.popitem(last=False)
        return token

    def resolve(self, token):
        if not token or len(token) > 128:
            raise ProxyError(403, 'invalid media resource')
        with self.lock:
            item = self.entries.get(token)
            if not item or item[1] <= time.monotonic():
                self.entries.pop(token, None)
                raise ProxyError(403, 'media resource expired; reload the playlist')
            return item[0]


_registry = ResourceRegistry()
register_resource = _registry.register
resolve_resource = _registry.resolve


class URLPolicy:
    def __init__(self, allowed_suffixes=None, allow_private=False, engine_port=8787):
        self.allowed_suffixes = tuple(DEFAULT_SUFFIXES if allowed_suffixes is None else allowed_suffixes)
        self.allow_private = allow_private  # Test injection only; no CLI switch enables this.
        self.engine_port = engine_port

    def resolve_for_request(self, target, deadline):
        return self.resolve(target, deadline=deadline)

    def resolve(self, target, _depth=0, deadline=None):
        try:
            if deadline is not None and time.monotonic() >= deadline:
                raise ProxyError(504, 'media request deadline exceeded before DNS')
            if len(target) > 16384 or _depth > 2:
                raise ValueError('URL too long or nested')
            parsed = urllib.parse.urlsplit(target)
            host = (parsed.hostname or '').rstrip('.').lower()
            port = parsed.port or (443 if parsed.scheme == 'https' else 80)
            if parsed.scheme not in ('http', 'https') or not host or parsed.username or parsed.password:
                raise ValueError('unsupported target')
            # Only this narrowly scoped local route is a legitimate companion-engine target.
            engine = (parsed.scheme == 'http' and host in ('127.0.0.1', 'localhost')
                      and port == self.engine_port and parsed.path == '/segment')
            if engine:
                inner = urllib.parse.parse_qs(parsed.query).get('url', [''])[0]
                self.resolve(inner, _depth + 1, deadline=deadline)
                return parsed, ['127.0.0.1']
            allowed = any(host == suffix.lstrip('.') or host.endswith('.' + suffix.lstrip('.'))
                          for suffix in self.allowed_suffixes)
            if not allowed or (not self.allow_private and port not in (80, 443)):
                raise ProxyError(403, 'media target is not allowed', category='target_policy')
            dns_timeout = min(3.0, deadline - time.monotonic()) if deadline is not None else 3.0
            if dns_timeout <= 0:
                raise ProxyError(504, 'media request deadline exceeded before DNS')
            addresses = bounded_dns_addresses(host, port, timeout=dns_timeout)
            if not addresses:
                raise ValueError('empty DNS response')
            if not self.allow_private and any(not ipaddress.ip_address(addr).is_global for addr in addresses):
                raise ProxyError(403, 'non-public media target', category='target_policy')
            return parsed, addresses
        except ProxyError:
            raise
        except DNSLookupError as exc:
            raise ProxyError(exc.status, str(exc)) from exc
        except (ValueError, OSError) as exc:
            raise ProxyError(403, 'invalid or unresolved media target', category='target_policy') from exc


class _PinnedHTTP(http.client.HTTPConnection):
    def __init__(self, host, port, address, timeout):
        super().__init__(host, port, timeout=timeout)
        self.address = address

    def connect(self):
        self.sock = socket.create_connection((self.address, self.port), self.timeout)


class _PinnedHTTPS(_PinnedHTTP):
    def connect(self):
        super().connect()
        try:
            self.sock = _TLS_CONTEXT.wrap_socket(self.sock, server_hostname=self.host)
        except BaseException:
            self.sock.close()
            raise


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class RemoteResponse:
    def __init__(self, response, connection, effective_url):
        self.response, self.connection, self.effective_url = response, connection, effective_url
        self.status = response.status if hasattr(response, 'status') else response.code
        self.headers = {k.lower(): v for k, v in response.headers.items()}
        self.content_lengths = [v for k, v in response.headers.items() if k.lower() == 'content-length']
        self.deadline = None

    def read(self, size):
        if self.deadline is not None:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise ProxyError(504, 'upstream response deadline exceeded')
            sock = getattr(self.connection, 'sock', None)
            if sock is None:
                raw = getattr(getattr(self.response, 'fp', None), 'raw', None)
                sock = getattr(raw, '_sock', None)
            if sock is not None:
                sock.settimeout(min(15, remaining))
        reader = getattr(self.response, 'read1', self.response.read)
        return reader(size)

    def close(self):
        try:
            self.response.close()
        finally:
            if self.connection is not None:
                self.connection.close()


def _safe_close(remote):
    if remote is not None:
        try:
            remote.close()
        except Exception:
            pass  # A close failure must never skip transfer notification or budget release.


def open_remote(target, headers=None, method='GET', policy=None, timeout=15, deadline=None):
    """Validate every hop. Direct connections pin DNS; configured proxies retain policy ownership."""
    policy = policy or URLPolicy()
    deadline = deadline or time.monotonic() + timeout
    current, request_headers = target, dict(headers or {})
    request_headers.update({'Accept-Encoding': 'identity', 'Connection': 'close'})
    for _ in range(5):
        timed_resolver = getattr(policy, 'resolve_for_request', None)
        parsed, addresses = timed_resolver(current, deadline) if timed_resolver else policy.resolve(current)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProxyError(504, 'media request deadline exceeded')
        request_timeout = min(timeout, remaining)
        host, port = parsed.hostname, parsed.port or (443 if parsed.scheme == 'https' else 80)
        connection = None
        # Respect the configured proxy path instead of globally replacing urllib's opener.
        proxies = urllib.request.getproxies()
        use_proxy = proxies.get(parsed.scheme) and not urllib.request.proxy_bypass(host)
        try:
            if use_proxy:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies), _NoRedirect(),
                                                     urllib.request.HTTPSHandler(context=_TLS_CONTEXT))
                req = urllib.request.Request(current, headers=request_headers, method=method)
                try:
                    response = opener.open(req, timeout=request_timeout)
                except urllib.error.HTTPError as exc:
                    response = exc
            else:
                cls = _PinnedHTTPS if parsed.scheme == 'https' else _PinnedHTTP
                request_path = urllib.parse.urlunsplit(('', '', parsed.path or '/', parsed.query, ''))
                failure = None
                for address in addresses:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    connection = cls(host, port, address, min(request_timeout, remaining))
                    try:
                        connection.request(method, request_path, headers=request_headers)
                        response = connection.getresponse()
                        break
                    except (OSError, http.client.HTTPException) as exc:
                        failure = exc
                        connection.close()
                else:
                    raise failure or OSError('no reachable media address')
                if time.monotonic() >= deadline:
                    raise ProxyError(504, 'media request deadline exceeded')
            result = RemoteResponse(response, connection, current)
            result.deadline = deadline
        except ProxyError:
            _safe_close(connection)
            raise
        except (OSError, http.client.HTTPException, urllib.error.URLError) as exc:
            _safe_close(connection)
            raise ProxyError(502, 'upstream media connection failed') from exc
        invalid_length = (len(result.content_lengths) > 1 or
                          any(not re.fullmatch(r'[0-9]+', value.strip()) for value in result.content_lengths))
        if invalid_length or (result.headers.get('transfer-encoding') and result.headers.get('content-length')):
            _safe_close(result)
            raise ProxyError(502, 'ambiguous upstream response framing')
        if result.status in (301, 302, 303, 307, 308) and result.headers.get('location'):
            next_url = urllib.parse.urljoin(current, result.headers['location'])
            _safe_close(result)
            next_parts = urllib.parse.urlsplit(next_url)
            if parsed.scheme == 'https' and next_parts.scheme != 'https':
                raise ProxyError(502, 'HTTPS media redirect downgrade rejected')
            if (next_parts.scheme, next_parts.hostname, next_parts.port) != (parsed.scheme, parsed.hostname, parsed.port):
                request_headers = {k: v for k, v in request_headers.items() if k.lower() not in SENSITIVE}
            current = next_url
            continue
        return result
    raise ProxyError(502, 'too many media redirects')


def fetch_bytes(target, headers=None, method='GET', policy=None, timeout=15, max_bytes=2 * 1024 * 1024, deadline=None):
    deadline = min(deadline, time.monotonic() + timeout) if deadline is not None else time.monotonic() + timeout
    remote = open_remote(target, headers, method, policy, timeout, deadline)
    try:
        chunks, total = [], 0
        while method != 'HEAD':
            if time.monotonic() >= deadline:
                raise ProxyError(504, 'upstream response deadline exceeded')
            chunk = remote.read(min(65536, max_bytes - total + 1))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise ProxyError(502, 'upstream response too large')
        declared = remote.headers.get('content-length')
        if method != 'HEAD' and declared is not None:
            try:
                if int(declared) != total:
                    raise ProxyError(502, 'incomplete upstream response')
            except ValueError:
                raise ProxyError(502, 'invalid upstream content length')
        return remote.status, remote.headers, b''.join(chunks), remote.effective_url
    finally:
        _safe_close(remote)


def render_media_playlist(text, effective_url, headers=None):
    def convert(value):
        absolute = urllib.parse.urljoin(effective_url, value)
        token = register_resource(absolute, headers)
        return '/proxy?resource=' + token
    out = []
    for index, line in enumerate(text.splitlines()):
        if index >= 8192:
            raise ProxyError(502, 'playlist has too many entries')
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            out.append(convert(stripped))
        else:
            out.append(re.sub(r'URI="([^"]+)"', lambda match: 'URI="' + convert(match.group(1)) + '"', line))
    return '\n'.join(out) + '\n'


@dataclasses.dataclass
class _Transfer:
    url: str
    request_headers: dict
    condition: threading.Condition = dataclasses.field(default_factory=threading.Condition)
    file: object = dataclasses.field(default_factory=tempfile.TemporaryFile)
    status: int = 0
    headers: dict = dataclasses.field(default_factory=dict)
    size: int = 0
    reserved: int = 0
    subscribers: int = 0
    done: bool = False
    error: ProxyError | None = None
    closed: bool = False
    io_lock: threading.Lock = dataclasses.field(default_factory=threading.Lock)


def _read_at(task, count, offset):
    if hasattr(os, 'pread'):
        return os.pread(task.file.fileno(), count, offset)
    with task.io_lock:
        task.file.seek(offset)
        return task.file.read(count)


def _write_at(task, data, offset):
    with task.io_lock:
        task.file.seek(offset)
        task.file.write(data)
        task.file.flush()


@dataclasses.dataclass
class _CacheEntry:
    chunks: tuple
    headers: dict
    size: int
    expires: float
    readers: int = 0
    retired: bool = False


def _client_write(handler, data, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ProxyError(504, 'client transfer deadline exceeded')
    connection = getattr(handler, 'connection', None)
    if connection is not None:
        current = connection.gettimeout()
        connection.settimeout(min(current or remaining, remaining))
    handler.wfile.write(data)


class SharedMediaProxy:
    """One producer, independent file cursors; RAM cache holds immutable chunks only.

    In-flight files are temporary, capped globally, and removed after the final reader.
    A disconnected/slow viewer never owns the producer's network socket.
    """
    def __init__(self, policy=None, max_cache_bytes=200 * 1024 * 1024,
                 max_inflight_bytes=256 * 1024 * 1024, max_downloads=8, timeout=30,
                 max_resource_bytes=64 * 1024 * 1024, temp_dir=None):
        self.policy = policy or URLPolicy()
        self.max_cache_bytes = max(0, int(max_cache_bytes))
        self.max_inflight_bytes = max(65536, int(max_inflight_bytes))
        self.max_resource_bytes = min(max_resource_bytes, self.max_inflight_bytes)
        self.timeout = max(1.0, timeout)
        self.temp_dir = temp_dir
        self.lock = threading.RLock()
        self.slots = threading.BoundedSemaphore(max(1, max_downloads))
        self.tasks, self.cache = {}, collections.OrderedDict()
        self.cache_bytes = self.inflight_bytes = 0
        self.hits = self.misses = self.coalesced = self.downloads = self.errors = 0
        self.stop = threading.Event()

    @staticmethod
    def _key(url, headers):
        return (url, tuple(sorted((k.lower(), str(v)) for k, v in headers.items())))

    def cached_prefix(self, url, headers, offset=0, length=65536):
        """Copy only a small prefix while the immutable completed entry is protected."""
        with self.lock:
            entry = self.cache.get(self._key(url, headers))
            if not entry or entry.expires <= time.monotonic() or offset >= entry.size:
                return None
            end, position, chunks = min(entry.size, offset + min(length, 65536)), 0, []
            for chunk in entry.chunks:
                next_position = position + len(chunk)
                if next_position > offset and position < end:
                    chunks.append(chunk[max(0, offset - position):min(len(chunk), end - position)])
                position = next_position
                if position >= end:
                    break
            return b''.join(chunks)

    def stats(self):
        with self.lock:
            return {'count': len(self.cache), 'size_mb': round(self.cache_bytes / 2**20, 2),
                    'hits': self.hits, 'misses': self.misses, 'coalesced': self.coalesced,
                    'downloads': self.downloads, 'errors': self.errors,
                    'inflight_count': len(self.tasks), 'inflight_mb': round(self.inflight_bytes / 2**20, 2),
                    'hit_rate': f'{100 * self.hits / max(1, self.hits + self.misses):.1f}%'}

    def _reserve(self, task, amount):
        with self.lock:
            if self.inflight_bytes + amount > self.max_inflight_bytes:
                raise ProxyError(503, 'media transfer budget exhausted')
            self.inflight_bytes += amount
            task.reserved += amount

    def _cleanup(self, key, task):
        with self.lock:
            if task.done and not task.subscribers and not task.closed:
                task.closed = True
                if self.tasks.get(key) is task:
                    self.tasks.pop(key, None)
                self.inflight_bytes -= task.reserved
                try:
                    task.file.close()
                except OSError:
                    pass

    def _store_cache(self, key, task):
        if not self.max_cache_bytes or task.status != 200 or not task.size or task.size > self.max_cache_bytes:
            return
        if 'mpegurl' in task.headers.get('content-type', '').lower() or '.m3u8' in urllib.parse.urlsplit(task.url).path:
            return
        with self.lock:
            if self.stop.is_set():
                return
            now = time.monotonic()
            for oldkey, item in list(self.cache.items()):
                if item.expires <= now:
                    self._retire_cache(item)
                    self.cache.pop(oldkey, None)
            while self.cache and self.cache_bytes + task.size > self.max_cache_bytes:
                _, item = self.cache.popitem(last=False)
                self._retire_cache(item)
            if self.cache_bytes + task.size > self.max_cache_bytes:
                return  # Evicted entries pinned by readers still count against the budget.
            # Evict before allocating. Immutable chunks avoid a second complete bytes copy.
            chunks = tuple(_read_at(task, min(65536, task.size - offset), offset)
                           for offset in range(0, task.size, 65536))
            previous = self.cache.pop(key, None)
            if previous:
                self._retire_cache(previous)
            self.cache[key] = _CacheEntry(chunks, dict(task.headers), task.size, now + 180)
            self.cache_bytes += task.size

    def _retire_cache(self, entry):
        entry.retired = True
        if not entry.readers:
            self.cache_bytes -= entry.size

    def _release_cache(self, entry):
        with self.lock:
            entry.readers -= 1
            if entry.retired and not entry.readers:
                self.cache_bytes -= entry.size

    def _produce(self, key, task):
        remote = None
        try:
            deadline = time.monotonic() + self.timeout
            remote = open_remote(task.url, task.request_headers, policy=self.policy,
                                 timeout=min(15, self.timeout), deadline=deadline)
            headers = {k: v for k, v in remote.headers.items() if k in PASS_HEADERS}
            expected = None
            if headers.get('content-length'):
                try:
                    expected = int(headers['content-length'])
                    if expected < 0 or expected > self.max_resource_bytes:
                        raise ProxyError(502, 'upstream resource too large')
                except ValueError:
                    raise ProxyError(502, 'invalid upstream content length')
            playlist = ('mpegurl' in headers.get('content-type', '').lower()
                        or urllib.parse.urlsplit(remote.effective_url).path.lower().endswith('.m3u8'))
            if playlist and remote.status == 200:
                if headers.get('content-encoding') not in (None, 'identity'):
                    raise ProxyError(502, 'unexpected compressed playlist')
                data, total = [], 0
                while True:
                    if time.monotonic() >= deadline:
                        raise ProxyError(504, 'media request deadline exceeded')
                    chunk = remote.read(65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > 2 * 1024 * 1024:
                        raise ProxyError(502, 'playlist too large')
                    data.append(chunk)
                text = b''.join(data).decode('utf-8', 'strict')
                if not text.lstrip().startswith('#EXTM3U'):
                    raise ProxyError(502, 'invalid upstream playlist')
                body = render_media_playlist(text, remote.effective_url, task.request_headers).encode()
                if len(body) > 2 * 1024 * 1024:
                    raise ProxyError(502, 'rendered playlist too large')
                self._reserve(task, len(body))
                _write_at(task, body, 0)
                headers['content-length'] = str(len(body))
                headers['content-type'] = 'application/vnd.apple.mpegurl'
                with task.condition:
                    task.status, task.headers, task.size = remote.status, headers, len(body)
                    task.condition.notify_all()
            else:
                if expected:
                    self._reserve(task, expected)
                with task.condition:
                    task.status, task.headers = remote.status, headers
                    task.condition.notify_all()
                first = True
                while True:
                    if self.stop.is_set() or time.monotonic() >= deadline:
                        raise ProxyError(504, 'media request deadline exceeded')
                    chunk = remote.read(65536)
                    if not chunk:
                        break
                    if first and remote.status == 200 and chunk.lstrip()[:16].lower().startswith((b'<!doctype html', b'<html')):
                        raise ProxyError(502, 'upstream returned an error page')
                    first = False
                    if task.size + len(chunk) > self.max_resource_bytes:
                        raise ProxyError(502, 'upstream resource too large')
                    additional = task.size + len(chunk) - task.reserved
                    if additional > 0:
                        self._reserve(task, additional)
                    _write_at(task, chunk, task.size)
                    with task.condition:
                        task.size += len(chunk)
                        task.condition.notify_all()
                if expected is not None and task.size != expected:
                    raise ProxyError(502, 'incomplete upstream resource')
                self._store_cache(key, task)
        except ProxyError as exc:
            with task.condition:
                task.error = exc
        except Exception:
            with task.condition:
                task.error = ProxyError(502, 'upstream media transfer failed')
        finally:
            _safe_close(remote)
            with task.condition:
                task.done = True
                task.condition.notify_all()
            with self.lock:
                self.errors += bool(task.error)
            self.slots.release()
            self._cleanup(key, task)

    @staticmethod
    def _headers(handler, status, headers, cache_status):
        handler.send_response(status)
        for key, value in headers.items():
            if key.lower() in PASS_HEADERS:
                handler.send_header(key, value)
        handler.send_header('Access-Control-Allow-Origin', '*')
        handler.send_header('Cache-Control', 'private, max-age=60' if status == 200 else 'no-store')
        handler.send_header('X-Cache', cache_status)
        handler.end_headers()

    def _serve_direct(self, handler, url, headers, head_only):
        if not self.slots.acquire(blocking=False):
            raise ProxyError(503, 'media download capacity reached')
        remote, started, reserved = None, False, True
        try:
            deadline = time.monotonic() + self.timeout
            remote = open_remote(url, headers, 'HEAD' if head_only else 'GET', self.policy,
                                 min(15, self.timeout), deadline)
            response_headers = {k: v for k, v in remote.headers.items() if k in PASS_HEADERS}
            status = remote.status
            if head_only:
                _safe_close(remote)
                remote = None
                self.slots.release()
                reserved = False
                self._headers(handler, status, response_headers, 'BYPASS')
                started = True
                return status
            self._headers(handler, remote.status, response_headers, 'BYPASS')
            started = True
            size = 0
            if not head_only:
                while True:
                    if time.monotonic() >= deadline:
                        raise ProxyError(504, 'media request deadline exceeded')
                    chunk = remote.read(65536)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > self.max_resource_bytes:
                        raise ProxyError(502, 'upstream resource too large')
                    _client_write(handler, chunk, deadline)
            return remote.status
        except Exception:
            if started:
                handler.close_connection = True
            else:
                raise
            return None
        finally:
            _safe_close(remote)
            if reserved:
                self.slots.release()

    def serve(self, handler, url, headers=None, head_only=False):
        client_deadline = time.monotonic() + self.timeout + 1
        if self.stop.is_set():
            raise ProxyError(503, 'media service is shutting down')
        headers = dict(headers or {})
        # Check before cache access as well as every connection and redirect.
        self.policy.resolve(url)
        range_header = handler.headers.get('Range')
        if range_header:
            if len(range_header) > 256 or not re.fullmatch(r'bytes=(?:\d+-\d*|-\d+)', range_header):
                raise ProxyError(416, 'unsupported byte range')
            headers['Range'] = range_header
            if handler.headers.get('If-Range'):
                headers['If-Range'] = handler.headers['If-Range'][:512]
        key = self._key(url, headers)
        with self.lock:
            cached = self.cache.get(key)
            if cached and cached.expires <= time.monotonic():
                self.cache.pop(key)
                self._retire_cache(cached)
                cached = None
            if cached:
                self.hits += 1
                cached.readers += 1
        if cached:
            try:
                self._headers(handler, 200, cached.headers, 'HIT-RAM')
                if not head_only:
                    for chunk in cached.chunks:
                        _client_write(handler, chunk, client_deadline)
            except (OSError, TimeoutError, ProxyError):
                handler.close_connection = True
            finally:
                self._release_cache(cached)
            return 200
        if head_only or range_header:
            return self._serve_direct(handler, url, headers, head_only)
        with self.lock:
            self.misses += 1
            task = self.tasks.get(key)
            if task and task.done and task.error:
                # Do not retain failed transfers as a negative cache.
                task = None
            if task:
                task.subscribers += 1
                self.coalesced += 1
            else:
                if not self.slots.acquire(blocking=False):
                    raise ProxyError(503, 'media download capacity reached')
                task = None
                try:
                    task = _Transfer(url, headers, file=tempfile.TemporaryFile(dir=self.temp_dir), subscribers=1)
                    self.tasks[key] = task
                    threading.Thread(target=self._produce, args=(key, task), daemon=True,
                                     name='media-download').start()
                    self.downloads += 1
                except Exception as exc:
                    if task is not None:
                        self.tasks.pop(key, None)
                        try:
                            task.file.close()
                        except OSError:
                            pass
                    self.slots.release()
                    raise ProxyError(503, 'media download could not start') from exc
        started = False
        deadline = client_deadline
        try:
            with task.condition:
                while not task.status and not task.done:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ProxyError(504, 'media response timed out')
                    task.condition.wait(min(remaining, 1))
                if task.error:
                    raise task.error
                status, response_headers = task.status, dict(task.headers)
            self._headers(handler, status, response_headers, 'SHARED' if task.subscribers > 1 else 'MISS-UPSTREAM')
            started = True
            offset = 0
            while True:
                with task.condition:
                    while offset >= task.size and not task.done:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise ProxyError(504, 'media transfer timed out')
                        task.condition.wait(min(remaining, 1))
                    available = task.size - offset
                    done, error = task.done, task.error
                if available:
                    chunk = _read_at(task, min(65536, available), offset)
                    if not chunk:
                        raise ProxyError(502, 'media buffer unavailable')
                    _client_write(handler, chunk, deadline)
                    offset += len(chunk)
                elif done:
                    if error:
                        raise error
                    break
            return status
        except Exception:
            if started:
                handler.close_connection = True
            else:
                raise
            return None
        finally:
            with self.lock:
                task.subscribers -= 1
            self._cleanup(key, task)

    def close(self):
        self.stop.set()
        with self.lock:
            for entry in self.cache.values():
                self._retire_cache(entry)
            self.cache.clear()
        # Active readers have their own bounded socket deadline; producers observe stop.


class BoundedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, max_connections=64, client_timeout=20):
        self.request_queue_size = max(16, min(256, int(max_connections)))
        self.admission = threading.BoundedSemaphore(max_connections)
        self.client_timeout = client_timeout
        self.active = 0
        self.rejected = 0
        self.count_lock = threading.Lock()
        super().__init__(address, handler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(self.client_timeout)
        return request, address

    def process_request(self, request, client_address):
        if not self.admission.acquire(blocking=False):
            with self.count_lock:
                self.rejected += 1
            try:
                request.sendall(b'HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nRetry-After: 1\r\nConnection: close\r\n\r\n')
            except OSError:
                pass
            self.shutdown_request(request)
            return
        with self.count_lock:
            self.active += 1
        try:
            super().process_request(request, client_address)
        except BaseException:
            with self.count_lock:
                self.active -= 1
            self.admission.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.count_lock:
                self.active -= 1
            self.admission.release()

# YSP gateway implementation
import argparse 
import atexit 
import base64 
import binascii 
import collections 
import contextlib 
import dataclasses 
import datetime 
import gzip 
import hashlib 
import hmac as _hmac 
import http .client 
import http .cookiejar 
from http .server import BaseHTTPRequestHandler ,ThreadingHTTPServer 
import json 
import math 
import os 
import random 
import re 
import secrets 
import shutil 
import signal 
import socket 
import ssl 
import struct 
import sys 
import threading 
import time 
import urllib .error 
import urllib .parse 
import urllib .request 
import uuid 
from collections import deque 
__version__ = '9.5.4-local'
AUTHOR_COMMUNITY ='https://t.me/garysclub'
AUTHOR_CHANNEL ='https://t.me/garysclubchannel'
AUTHOR_NOTICE =f'''📢 首发地址
社区：Gary's Club ({AUTHOR_COMMUNITY})
频道：Gary's Club Channel ({AUTHOR_CHANNEL})
⚠️ 其他任何分发渠道均非作者本人！'''
AK ='9f5c54c4ed0e50109b800f7e28fec205'
RSA_PUBLIC_KEY_B64 ='MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkKeLy4ywWLSnBkwRyqYgF3HMIj05V5uuh5HjyEsZOWnu1NHu3jPQv3sr32wwQNYv5qapsNXmNgLUDHtgHZxqPQAYXltjSRc0qhcD286t62wOIHId8zXS3s1Jy4rgU4qjQWzI9rp/1sE0pMsmwTaJa4zuJ5iz8VwF8Av5oJ1k+HxY+/HLnjNlW1hmWLpuDYmkZYuAoTHa1VGeHQh9FEKI8ZcL3GTQphShUoC+Kg3P1hGUVTtCYapmzPS5lkAdwebuzwvTCfGiTErYZCnPBUSeV7BVlgjtLYIi29KvF0a8FHsJMfe/UdHcyW/RihsIYOtDQcRRpFGXyPXbVrzFJse24QIDAQAB'
CLOUD_GET_URL ='https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/get'
CLOUD_REGISTER_URL ='https://ytpcloudws.cctv.cn/cloudps/wssapi/device/v2/register'
APP_START_URL ='https://ytpaddr.cctv.cn/gsnw/api/app/start/v1/01'
DRM_CONFIG_URL ='https://ytpaddr.cctv.cn/gsnw/drm/config/obtain/v1'
VERSION_CONFIG_URL ='https://ytpaddr.cctv.cn/gsnw/version/config/obtain/v1'
DICTIONARY_URL ='https://ytpaddr.cctv.cn/gsnw/player/dictionary/obtain/v1'
INDEX_URL ='https://ytpaddr.cctv.cn/gsnw/api/index/v1/01'
REPORT_SINGLE_URL ='https://ytpdata.cctv.cn/das/app/data/message/single'
COLLECT_REPORT_URL ='https://collect.cctv.cn/cctvmobileinf/rest/cctv/receive/new/app'
LIVE_V1_01_URL ='https://ytpaddr.cctv.cn/gsnw/api/live/v1/01'
LIVE_V1_02_URL ='https://ytpaddr.cctv.cn/gsnw/api/live/v1/02'
VDN_GETSTREAM_URL ='https://ytpvdn.cctv.cn/cctvmobileinf/rest/cctv/videoliveUrl/getstream'
DEFAULT_LIVE_USER_ID ='BAEBFF2B-C516-4F34-ABC0-A824A6461CBD'
DEFAULT_DEVICE_NAME ='央视频电视投屏助手'
VDN_APP_NAME ='央视频电视投屏助手'
REPORT_APP_KEY ='1178c84d-4818-44ff-b415-02106e87e144'
COLLECT_SDK_VERSION ='1.0.0'
DEFAULT_PAGE_NAME ='com.cctv.tv.mvp.ui.activity.MainActivity'
DEFAULT_ACCEPT_LANGUAGE ='zh-CN,zh;q=0.8'
RESULT_OK =0 
RESULT_NEEDS_REGISTER =601 
RESULT_GET_MISSING_OR_INVALID =2 
RESULT_REGISTERED_ELSEWHERE =694 
RESULT_REGISTER_RETRY_LATER =695 
_SBOX =(99 ,124 ,119 ,123 ,242 ,107 ,111 ,197 ,48 ,1 ,103 ,43 ,254 ,215 ,171 ,118 ,202 ,130 ,201 ,125 ,250 ,89 ,71 ,240 ,173 ,212 ,162 ,175 ,156 ,164 ,114 ,192 ,183 ,253 ,147 ,38 ,54 ,63 ,247 ,204 ,52 ,165 ,229 ,241 ,113 ,216 ,49 ,21 ,4 ,199 ,35 ,195 ,24 ,150 ,5 ,154 ,7 ,18 ,128 ,226 ,235 ,39 ,178 ,117 ,9 ,131 ,44 ,26 ,27 ,110 ,90 ,160 ,82 ,59 ,214 ,179 ,41 ,227 ,47 ,132 ,83 ,209 ,0 ,237 ,32 ,252 ,177 ,91 ,106 ,203 ,190 ,57 ,74 ,76 ,88 ,207 ,208 ,239 ,170 ,251 ,67 ,77 ,51 ,133 ,69 ,249 ,2 ,127 ,80 ,60 ,159 ,168 ,81 ,163 ,64 ,143 ,146 ,157 ,56 ,245 ,188 ,182 ,218 ,33 ,16 ,255 ,243 ,210 ,205 ,12 ,19 ,236 ,95 ,151 ,68 ,23 ,196 ,167 ,126 ,61 ,100 ,93 ,25 ,115 ,96 ,129 ,79 ,220 ,34 ,42 ,144 ,136 ,70 ,238 ,184 ,20 ,222 ,94 ,11 ,219 ,224 ,50 ,58 ,10 ,73 ,6 ,36 ,92 ,194 ,211 ,172 ,98 ,145 ,149 ,228 ,121 ,231 ,200 ,55 ,109 ,141 ,213 ,78 ,169 ,108 ,86 ,244 ,234 ,101 ,122 ,174 ,8 ,186 ,120 ,37 ,46 ,28 ,166 ,180 ,198 ,232 ,221 ,116 ,31 ,75 ,189 ,139 ,138 ,112 ,62 ,181 ,102 ,72 ,3 ,246 ,14 ,97 ,53 ,87 ,185 ,134 ,193 ,29 ,158 ,225 ,248 ,152 ,17 ,105 ,217 ,142 ,148 ,155 ,30 ,135 ,233 ,206 ,85 ,40 ,223 ,140 ,161 ,137 ,13 ,191 ,230 ,66 ,104 ,65 ,153 ,45 ,15 ,176 ,84 ,187 ,22 )
_RCON =(1 ,2 ,4 ,8 ,16 ,32 ,64 ,128 ,27 ,54 )
def _xtime (a :int )->int :
    return (a <<1 ^283 )&255 if a &128 else a <<1 &255 
def _aes256_key_schedule (key :bytes ):
    assert len (key )==32 
    w =[int .from_bytes (key [i :i +4 ],'big')for i in range (0 ,32 ,4 )]
    for i in range (8 ,60 ):
        temp =w [i -1 ]
        if i %8 ==0 :
            temp =_SBOX [temp >>16 &255 ]<<24 |_SBOX [temp >>8 &255 ]<<16 |_SBOX [temp &255 ]<<8 |_SBOX [temp >>24 &255 ]
            temp ^=_RCON [i //8 -1 ]<<24 
        elif i %8 ==4 :
            temp =_SBOX [temp >>24 &255 ]<<24 |_SBOX [temp >>16 &255 ]<<16 |_SBOX [temp >>8 &255 ]<<8 |_SBOX [temp &255 ]
        w .append (w [i -8 ]^temp )
    return [b''.join ((word .to_bytes (4 ,'big')for word in w [i :i +4 ]))for i in range (0 ,60 ,4 )]
def _add_round_key (state ,rk :bytes ):
    for i in range (16 ):
        state [i ]^=rk [i ]
def _sub_bytes (state ):
    for i in range (16 ):
        state [i ]=_SBOX [state [i ]]
def _shift_rows (s ):
    s [1 ],s [5 ],s [9 ],s [13 ]=(s [5 ],s [9 ],s [13 ],s [1 ])
    s [2 ],s [6 ],s [10 ],s [14 ]=(s [10 ],s [14 ],s [2 ],s [6 ])
    s [3 ],s [7 ],s [11 ],s [15 ]=(s [15 ],s [3 ],s [7 ],s [11 ])
def _mix_columns (s ):
    for c in range (4 ):
        a0 ,a1 ,a2 ,a3 =(s [4 *c ],s [4 *c +1 ],s [4 *c +2 ],s [4 *c +3 ])
        s [4 *c ]=_xtime (a0 )^(_xtime (a1 )^a1 )^a2 ^a3 
        s [4 *c +1 ]=a0 ^_xtime (a1 )^(_xtime (a2 )^a2 )^a3 
        s [4 *c +2 ]=a0 ^a1 ^_xtime (a2 )^(_xtime (a3 )^a3 )
        s [4 *c +3 ]=_xtime (a0 )^a0 ^a1 ^a2 ^_xtime (a3 )
def _aes256_encrypt_block_rk (rk :list ,block :bytes )->bytes :
    s =bytearray (block )
    _add_round_key (s ,rk [0 ])
    for rnd in range (1 ,14 ):
        _sub_bytes (s )
        _shift_rows (s )
        _mix_columns (s )
        _add_round_key (s ,rk [rnd ])
    _sub_bytes (s )
    _shift_rows (s )
    _add_round_key (s ,rk [14 ])
    return bytes (s )
def aes256_encrypt_block (key :bytes ,block :bytes )->bytes :
    return _aes256_encrypt_block_rk (_aes256_key_schedule (key ),block )
def _gf_mult (x :int ,y :int )->int :
    r =299076299051606071403356588563077529600 
    z =0 
    v =y 
    for _ in range (128 ):
        if x &170141183460469231731687303715884105728 :
            z ^=v 
        if v &1 :
            v =v >>1 ^r 
        else :
            v >>=1 
        x =x <<1 &340282366920938463463374607431768211455 
    return z 
def _ghash (h :int ,aad :bytes ,ct :bytes )->int :
    x =0 
    def _blocks (data :bytes ):
        for i in range (0 ,len (data ),16 ):
            blk =data [i :i +16 ]
            if len (blk )<16 :
                blk =blk +b'\x00'*(16 -len (blk ))
            yield int .from_bytes (blk ,'big')
    for b in _blocks (aad ):
        x =_gf_mult (x ^b ,h )
    for b in _blocks (ct ):
        x =_gf_mult (x ^b ,h )
    lens =len (aad )*8 <<64 |len (ct )*8 
    x =_gf_mult (x ^lens ,h )
    return x 
def _inc32 (block :bytes )->bytes :
    ctr =int .from_bytes (block [12 :],'big')
    return block [:12 ]+(ctr +1 &4294967295 ).to_bytes (4 ,'big')
def _gctr_rk (rk :list ,icb :bytes ,data :bytes )->bytes :
    out =bytearray ()
    cb =icb 
    for i in range (0 ,len (data ),16 ):
        ks =_aes256_encrypt_block_rk (rk ,cb )
        chunk =data [i :i +16 ]
        out +=bytes ((a ^b for a ,b in zip (chunk ,ks )))
        cb =_inc32 (cb )
    return bytes (out )
def _gctr (key :bytes ,icb :bytes ,data :bytes )->bytes :
    return _gctr_rk (_aes256_key_schedule (key ),icb ,data )
def aes_gcm_encrypt (key :bytes ,nonce :bytes ,plaintext :bytes ,aad :bytes =b'')->bytes :
    assert len (key )==32 and len (nonce )==12 
    rk =_aes256_key_schedule (key )
    h =int .from_bytes (_aes256_encrypt_block_rk (rk ,b'\x00'*16 ),'big')
    j0 =nonce +b'\x00\x00\x00\x01'
    ct =_gctr_rk (rk ,_inc32 (j0 ),plaintext )
    s =_ghash (h ,aad ,ct ).to_bytes (16 ,'big')
    tag =bytes ((a ^b for a ,b in zip (_aes256_encrypt_block_rk (rk ,j0 ),s )))
    return ct +tag 
def aes_gcm_decrypt (key :bytes ,nonce :bytes ,ct_and_tag :bytes ,aad :bytes =b'')->bytes :
    if len (ct_and_tag )<16 :
        raise ValueError ('AES-GCM payload too short')
    ct ,tag =(ct_and_tag [:-16 ],ct_and_tag [-16 :])
    rk =_aes256_key_schedule (key )
    h =int .from_bytes (_aes256_encrypt_block_rk (rk ,b'\x00'*16 ),'big')
    j0 =nonce +b'\x00\x00\x00\x01'
    s =_ghash (h ,aad ,ct ).to_bytes (16 ,'big')
    expect =bytes ((a ^b for a ,b in zip (_aes256_encrypt_block_rk (rk ,j0 ),s )))
    if not _hmac .compare_digest (tag ,expect ):
        raise ValueError ('AES-GCM decrypt failed')
    return _gctr_rk (rk ,_inc32 (j0 ),ct )
def _mgf1_sha256 (seed :bytes ,length :int )->bytes :
    out =bytearray ()
    counter =0 
    while len (out )<length :
        out +=hashlib .sha256 (seed +counter .to_bytes (4 ,'big')).digest ()
        counter +=1 
    return bytes (out [:length ])
def _oaep_encode_sha256 (message :bytes ,k :int ,seed :bytes )->bytes :
    hlen =32 
    if len (message )>k -2 *hlen -2 :
        raise ValueError ('OAEP message too long')
    lhash =hashlib .sha256 (b'').digest ()
    ps =b'\x00'*(k -len (message )-2 *hlen -2 )
    db =lhash +ps +b'\x01'+message 
    db_mask =_mgf1_sha256 (seed ,k -hlen -1 )
    masked_db =bytes ((a ^b for a ,b in zip (db ,db_mask )))
    seed_mask =_mgf1_sha256 (masked_db ,hlen )
    masked_seed =bytes ((a ^b for a ,b in zip (seed ,seed_mask )))
    return b'\x00'+masked_seed +masked_db 
def _der_read_tlv (der :bytes ,pos :int ):
    assert der [pos ]==48 ,'expected SEQUENCE'
    pos +=1 
    ln ,pos =_der_read_len (der ,pos )
    end =pos +ln 
    items =[]
    while pos <end :
        tag =der [pos ]
        pos +=1 
        ln2 ,pos =_der_read_len (der ,pos )
        items .append ((tag ,der [pos :pos +ln2 ]))
        pos +=ln2 
    return items 
def _der_read_len (der :bytes ,pos :int ):
    first =der [pos ]
    pos +=1 
    if first &128 ==0 :
        return (first ,pos )
    n =first &127 
    return (int .from_bytes (der [pos :pos +n ],'big'),pos +n )
def _der_read_int (raw :bytes )->int :
    return int .from_bytes (raw ,'big')
def parse_spki_rsa_pubkey (der :bytes ):
    outer =_der_read_tlv (der ,0 )
    bitstring =outer [1 ][1 ]
    assert bitstring [0 ]==0 
    inner =_der_read_tlv (bitstring [1 :],0 )
    n =_der_read_int (inner [0 ][1 ])
    e =_der_read_int (inner [1 ][1 ])
    return (n ,e )
def rsa_oaep_sha256_encrypt (der :bytes ,message :bytes ,seed :bytes )->bytes :
    n ,e =parse_spki_rsa_pubkey (der )
    k =(n .bit_length ()+7 )//8 
    em =_oaep_encode_sha256 (message ,k ,seed )
    m =int .from_bytes (em ,'big')
    c =pow (m ,e ,n )
    return c .to_bytes (k ,'big')
class YsptpError (Exception ):
    pass 
def now_f64 ()->float :
    return time .time ()
def current_time_ms ()->int :
    return int (now_f64 ()*1000.0 )
def rust_round (x :float )->float :
    return math .floor (x +0.5 )
def sha1_upper (value :str )->str :
    return hashlib .sha1 (value .encode ('utf-8')).hexdigest ().upper ()
def sha256_hex (value :str )->str :
    return hashlib .sha256 (value .encode ('utf-8')).hexdigest ()
def md5_hex (value :str )->str :
    return hashlib .md5 (value .encode ('utf-8')).hexdigest ()
global_log_ring =collections .deque (maxlen =120 )
_log_lock =threading .Lock ()
_last_log_times ={}
def log (msg ,min_interval =0.0 ):
    now =time .time ()
    clean_msg =str (msg ).strip ()
    if not clean_msg :
        return 
    with _log_lock :
        interval =min_interval if min_interval >0.0 else 1.5 
        last_t =_last_log_times .get (clean_msg ,0.0 )
        if now -last_t <interval :
            return 
        _last_log_times [clean_msg ]=now 
        if len (_last_log_times )>600 :
            _last_log_times .clear ()
        line ='[%s] %s'%(time .strftime ('%H:%M:%S'),clean_msg )
        global_log_ring .append (line )
    print (line ,flush =True )
def java_string_hashcode (value :str )->int :
    h =0 
    for ch in value :
        h =h *31 +ord (ch )&4294967295 
    return h -4294967296 if h &2147483648 else h 
def java_uuid_from_hashes (msb_hash :int ,lsb_hash :int )->str :
    msb =msb_hash &18446744073709551615 
    lsb =lsb_hash &18446744073709551615 
    return f'{msb <<64 |lsb :032x}'
def native_day0_ms (now_s :int )->int :
    return 86400000 *((now_s +28800 )//86400 )-28800000 
def compute_fingerprint (x_uid :str ,now_ms :int ):
    day0_ms =native_day0_ms (now_ms //1000 )
    first =sha256_hex (f'{AK }{x_uid }{now_ms }{day0_ms }')
    return (sha256_hex (first ),now_ms ,day0_ms )
def random_hex_string (length :int )->str :
    return ''.join ((secrets .choice ('0123456789abcdef')for _ in range (length )))
def random_mac_address ()->str :
    raw =bytearray (secrets .token_bytes (6 ))
    raw [0 ]=(raw [0 ]|2 )&254 
    return ':'.join ((f'{b :02x}'for b in raw ))
def sanitize_profile_id (value :str )->str :
    out =[]
    last_underscore =False 
    for ch in value :
        if ch .isascii ()and ch .isalnum ():
            out .append (ch .lower ())
            last_underscore =False 
        elif not last_underscore :
            out .append ('_')
            last_underscore =True 
    return ''.join (out ).strip ('_')
def resolution_from_screen_param (screen_param :str )->str :
    parts =screen_param .split ('-')
    if len (parts )>=2 and parts [0 ]and parts [1 ]:
        return f'{parts [0 ]}*{parts [1 ]}'
    return '3840*2160'
def channels ():
    return [('cctv1','Live1717729995180256'),('cctv2','Live1718261577870260'),('cctv3','Live1718261955077261'),('cctv4','Live1718276148119264'),('cctv5','Live1719474204987287'),('cctv5p','Live1719473996025286'),('cctv7','Live1718276412224269'),('cctv8','Live1718276458899270'),('cctv9','Live1718276503187272'),('cctv10','Live1718276550002273'),('cctv11','Live1718276603690275'),('cctv12','Live1718276623932276'),('cctv13','Live1718276575708274'),('cctv14','Live1718276498748271'),('cctv15','Live1718276319614267'),('cctv16','Live1718276256572265'),('cctv17','Live1718276138318263'),('cctv4k','Live1767871224782105'),('cctv8k','Live1688400593818102'),('cctv164k','Live1704966749996185'),('cgtn','Live1719392219423280'),('cgtnfr','Live1719392670442283'),('cgtnru','Live1719392779653284'),('cgtnar','Live1719392885692285'),('cgtnes','Live1719392560433282'),('cgtndoc','Live1719392360336281')]
def channel_by_name (name :str ):
    for c ,live_id in channels ():
        if c ==name :
            return live_id 
    return None 
def has_http_400 (lower :str )->bool :
    return 'http 400'in lower or 'status=400'in lower 
def is_session_core_http_400 (lower :str )->bool :
    return has_http_400 (lower )and any ((needle in lower for needle in ('app/start','live/v1/01','live/v1/02','vdn','heartbeat')))
def is_control_plane_http_400 (lower :str )->bool :
    return has_http_400 (lower )and any ((needle in lower for needle in ('app/start','dictionary','app event','page event','cloud_get','cloud get','cloud_register','cloud register','device info','heartbeat','index','drm config','version config','live/v1/01','live/v1/02','vdn','collect report')))
def is_session_invalidating_error (message :str )->bool :
    lower =message .lower ()
    return 'app/start'in lower or 'decrypt'in lower or 'session_key'in lower or ('missing encrypted session key'in lower )or is_session_core_http_400 (lower )or ('live/v1/01 http 400'in lower )or ('live/v1/01 http 401'in lower )or ('live/v1/01 http 403'in lower )or ('live/v1/02 http 400'in lower )or ('live/v1/02 http 401'in lower )or ('live/v1/02 http 403'in lower )or ('vdn http 400'in lower )or ('vdn http 401'in lower )or ('vdn http 403'in lower )or ('内部错误'in lower )or ('no usable url'in lower )or ('missing videos'in lower )
def is_identity_recoverable_error (message :str )->bool :
    lower =message .lower ()
    return is_session_invalidating_error (message )or is_control_plane_http_400 (lower )or 'upstream m3u8 http 400'in lower or ('upstream m3u8 http 401'in lower )or ('upstream m3u8 http 403'in lower )or ('upstream m3u8 http 404'in lower )or ('playlist response missing'in lower )or ('invalid playlist status'in lower )or ('connection reset'in lower )or ('connection refused'in lower )or ('operation timed out'in lower )or ('timed out'in lower )or ('network is unreachable'in lower )or ('nodename nor servname'in lower )or ('failed to lookup address'in lower )
def normalize_channel (raw :str )->str :
    key =raw .strip ().strip ('/').lower ()
    if key .endswith ('.m3u8'):
        key =key [:-len ('.m3u8')]
    if key in ('cctv16-4k','cctv16_4k','cctv16/4k','cctv16(4k)'):
        return 'cctv164k'
    return key 
TRUE_4K_CHANNELS ={'cctv4k','cctv8k','cctv164k'}
@dataclasses .dataclass 
class DeviceProfile :
    android_id :str =''
    mac :str =''
    hardware :str =''
    board :str =''
    brand :str =''
    device :str =''
    manufacturer :str =''
    model :str =''
    product :str =''
    tags :str =''
    build_type :str =''
    user :str =''
    resolution :str =''
    display :str =''
    version_id :str =''
    host :str =''
    fingerprint :str =''
    report_model :str =''
    @classmethod 
    def from_dict (cls ,d :dict )->'DeviceProfile':
        return cls (**{f .name :str (d .get (f .name ,''))for f in dataclasses .fields (cls )})
@dataclasses .dataclass 
class DeviceState :
    schema_version :int =1 
    profile_source :str =''
    profile :DeviceProfile =dataclasses .field (default_factory =DeviceProfile )
    screen_param :str =''
    cast_model :str =''
    x_uid :str =''
    cloud_guid :str =''
    registered_at :float =0.0 
    updated_at :float =0.0 
@dataclasses .dataclass 
class Identity :
    x_uid :str =''
    x_fingerprint :str =''
    fingerprint_timestamp_ms :int =0 
    headers :dict =dataclasses .field (default_factory =dict )
@dataclasses .dataclass 
class ChannelEntry :
    channel :str =''
    live_id :str =''
    final_url :str =''
    playback_headers :dict =dataclasses .field (default_factory =dict )
    android_id :str =''
    x_uid :str =''
    rate :str =''
    rate_name :str =''
    raw_live_host :str =''
    final_host :str =''
    refreshed_at :float =0.0 
    expires_at :float =0.0 
    generation :int =0 
    last_refresh_error :str =''
    last_refresh_failed_at :float =0.0 
    session_generation :int =0 
    def fresh (self ,now :float )->bool :
        return bool (self .final_url )and now <self .expires_at 
    def stale_usable (self ,now :float ,ttl :float )->bool :
        return bool (self .final_url )and ttl >0.0 and (now <self .expires_at +ttl )
    @classmethod 
    def from_dict (cls ,d :dict )->'ChannelEntry':
        kwargs ={}
        for f in dataclasses .fields (cls ):
            v =d .get (f .name ,f .default if f .default is not dataclasses .MISSING else None )
            if f .name =='playback_headers':
                v =dict (v )if isinstance (v ,dict )else {}
            kwargs [f .name ]=v 
        return cls (**kwargs )
@dataclasses .dataclass 
class PlaylistCacheEntry :
    body :str =''
    content_type :str =''
    cached_at :float =0.0 
    expires_at :float =0.0 
    final_url :str =''
    android_id :str =''
    proxy_origin :str =''
    proxy_prefix :str =''
@dataclasses .dataclass 
class PlaylistCacheProbe :
    state :str =''
    age_ms :int |None =None 
@dataclasses .dataclass 
class AppStartResult :
    session_key :str =''
@dataclasses .dataclass 
class Live01Result :
    live_url :str =''
    rate :str =''
    rate_name :str =''
@dataclasses .dataclass 
class VdnGetStreamResult :
    final_url :str =''
    app_sign :str =''
    app_random_str :str =''
def inspect_playlist_cache (cached ,entry :ChannelEntry ,proxy_origin :str ,proxy_prefix ,now :float )->PlaylistCacheProbe :
    if cached is None :
        return PlaylistCacheProbe (state ='miss:not_found',age_ms =None )
    age_ms =int (rust_round (max (0.0 ,now -cached .cached_at )*1000.0 ))
    fresh =now <cached .expires_at 
    same_final_url =cached .final_url ==entry .final_url 
    same_android_id =cached .android_id ==entry .android_id 
    same_origin =cached .proxy_origin ==proxy_origin 
    same_prefix =cached .proxy_prefix ==(proxy_prefix or '')
    if fresh and same_final_url and same_android_id and same_origin and same_prefix :
        return PlaylistCacheProbe (state ='hit',age_ms =age_ms )
    reasons =[]
    if not fresh :
        reasons .append ('expired')
    if not same_final_url :
        reasons .append ('final_url_changed')
    if not same_android_id :
        reasons .append ('android_id_changed')
    if not same_origin :
        reasons .append ('origin_changed')
    if not same_prefix :
        reasons .append ('prefix_changed')
    if not reasons :
        reasons .append ('unknown')
    return PlaylistCacheProbe (state ='miss:'+'+'.join (reasons ),age_ms =age_ms )
DEVICE_PROFILE_POOL =[{'source':'sony_8k_pool.XR-85Z9K','brand':'Sony','manufacturer':'Sony','model':'XR-85Z9K','report_model':'XR85Z9K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_85Z9K','screen_param':'7680-4320-280','cast_model':'XR-85Z9K'},{'source':'sony_8k_pool.XR-75Z9K','brand':'Sony','manufacturer':'Sony','model':'XR-75Z9K','report_model':'XR75Z9K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_75Z9K','screen_param':'7680-4320-260','cast_model':'XR-75Z9K'},{'source':'sony_8k_pool.XR-85Z9J','brand':'Sony','manufacturer':'Sony','model':'XR-85Z9J','report_model':'XR85Z9J','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2021.XR_85Z9J','screen_param':'7680-4320-280','cast_model':'XR-85Z9J'},{'source':'sony_8k_pool.XR-75Z9J','brand':'Sony','manufacturer':'Sony','model':'XR-75Z9J','report_model':'XR75Z9J','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2021.XR_75Z9J','screen_param':'7680-4320-260','cast_model':'XR-75Z9J'},{'source':'sony_8k_pool.KD-98ZG9','brand':'Sony','manufacturer':'Sony','model':'KD-98ZG9','report_model':'KD98ZG9','hardware':'mt5893','board':'mt5893','version_id':'SONYTV.2019.KD_98ZG9','screen_param':'7680-4320-320','cast_model':'KD-98ZG9'},{'source':'sony_8k_pool.KD-85ZG9','brand':'Sony','manufacturer':'Sony','model':'KD-85ZG9','report_model':'KD85ZG9','hardware':'mt5893','board':'mt5893','version_id':'SONYTV.2019.KD_85ZG9','screen_param':'7680-4320-280','cast_model':'KD-85ZG9'},{'source':'sony_8k_pool.KD-85ZH8','brand':'Sony','manufacturer':'Sony','model':'KD-85ZH8','report_model':'KD85ZH8','hardware':'mt5893','board':'mt5893','version_id':'SONYTV.2020.KD_85ZH8','screen_param':'7680-4320-280','cast_model':'KD-85ZH8'},{'source':'sony_8k_pool.KD-75ZH8','brand':'Sony','manufacturer':'Sony','model':'KD-75ZH8','report_model':'KD75ZH8','hardware':'mt5893','board':'mt5893','version_id':'SONYTV.2020.KD_75ZH8','screen_param':'7680-4320-260','cast_model':'KD-75ZH8'},{'source':'samsung_8k_pool.QA85QN900A','brand':'Samsung','manufacturer':'Samsung','model':'QA85QN900A','report_model':'QA85QN900A','hardware':'s5e9925','board':'neo8k','version_id':'SAMSUNGTV.2021.QN900A','screen_param':'7680-4320-280','cast_model':'QA85QN900A'},{'source':'samsung_8k_pool.QA75QN900A','brand':'Samsung','manufacturer':'Samsung','model':'QA75QN900A','report_model':'QA75QN900A','hardware':'s5e9925','board':'neo8k','version_id':'SAMSUNGTV.2021.QN900A','screen_param':'7680-4320-260','cast_model':'QA75QN900A'},{'source':'samsung_8k_pool.QA85QN900B','brand':'Samsung','manufacturer':'Samsung','model':'QA85QN900B','report_model':'QA85QN900B','hardware':'s5e9925','board':'neo8k','version_id':'SAMSUNGTV.2022.QN900B','screen_param':'7680-4320-280','cast_model':'QA85QN900B'},{'source':'samsung_8k_pool.QA75QN900B','brand':'Samsung','manufacturer':'Samsung','model':'QA75QN900B','report_model':'QA75QN900B','hardware':'s5e9925','board':'neo8k','version_id':'SAMSUNGTV.2022.QN900B','screen_param':'7680-4320-260','cast_model':'QA75QN900B'},{'source':'samsung_8k_pool.QA85QN900C','brand':'Samsung','manufacturer':'Samsung','model':'QA85QN900C','report_model':'QA85QN900C','hardware':'s5e9935','board':'neo8k','version_id':'SAMSUNGTV.2023.QN900C','screen_param':'7680-4320-280','cast_model':'QA85QN900C'},{'source':'samsung_8k_pool.QA75QN900C','brand':'Samsung','manufacturer':'Samsung','model':'QA75QN900C','report_model':'QA75QN900C','hardware':'s5e9935','board':'neo8k','version_id':'SAMSUNGTV.2023.QN900C','screen_param':'7680-4320-260','cast_model':'QA75QN900C'},{'source':'samsung_8k_pool.QA85QN900D','brand':'Samsung','manufacturer':'Samsung','model':'QA85QN900D','report_model':'QA85QN900D','hardware':'s5e9945','board':'neo8k','version_id':'SAMSUNGTV.2024.QN900D','screen_param':'7680-4320-280','cast_model':'QA85QN900D'},{'source':'samsung_8k_pool.QA98QN990C','brand':'Samsung','manufacturer':'Samsung','model':'QA98QN990C','report_model':'QA98QN990C','hardware':'s5e9935','board':'neo8k','version_id':'SAMSUNGTV.2023.QN990C','screen_param':'7680-4320-320','cast_model':'QA98QN990C'},{'source':'samsung_8k_pool.QA85QN800C','brand':'Samsung','manufacturer':'Samsung','model':'QA85QN800C','report_model':'QA85QN800C','hardware':'s5e9935','board':'neo8k','version_id':'SAMSUNGTV.2023.QN800C','screen_param':'7680-4320-280','cast_model':'QA85QN800C'},{'source':'samsung_8k_pool.QA75QN800D','brand':'Samsung','manufacturer':'Samsung','model':'QA75QN800D','report_model':'QA75QN800D','hardware':'s5e9945','board':'neo8k','version_id':'SAMSUNGTV.2024.QN800D','screen_param':'7680-4320-260','cast_model':'QA75QN800D'},{'source':'lg_8k_pool.OLED88Z1PCA','brand':'LG','manufacturer':'LGE','model':'OLED88Z1PCA','report_model':'OLED88Z1PCA','hardware':'alpha9gen4','board':'lg8k','version_id':'LGTV.2021.OLED88Z1','screen_param':'7680-4320-320','cast_model':'OLED88Z1PCA'},{'source':'lg_8k_pool.OLED77Z1PCA','brand':'LG','manufacturer':'LGE','model':'OLED77Z1PCA','report_model':'OLED77Z1PCA','hardware':'alpha9gen4','board':'lg8k','version_id':'LGTV.2021.OLED77Z1','screen_param':'7680-4320-260','cast_model':'OLED77Z1PCA'},{'source':'lg_8k_pool.OLED88Z2PCA','brand':'LG','manufacturer':'LGE','model':'OLED88Z2PCA','report_model':'OLED88Z2PCA','hardware':'alpha9gen5','board':'lg8k','version_id':'LGTV.2022.OLED88Z2','screen_param':'7680-4320-320','cast_model':'OLED88Z2PCA'},{'source':'lg_8k_pool.OLED77Z2PCA','brand':'LG','manufacturer':'LGE','model':'OLED77Z2PCA','report_model':'OLED77Z2PCA','hardware':'alpha9gen5','board':'lg8k','version_id':'LGTV.2022.OLED77Z2','screen_param':'7680-4320-260','cast_model':'OLED77Z2PCA'},{'source':'lg_8k_pool.OLED88Z3PCA','brand':'LG','manufacturer':'LGE','model':'OLED88Z3PCA','report_model':'OLED88Z3PCA','hardware':'alpha9gen6','board':'lg8k','version_id':'LGTV.2023.OLED88Z3','screen_param':'7680-4320-320','cast_model':'OLED88Z3PCA'},{'source':'lg_8k_pool.OLED77Z3PCA','brand':'LG','manufacturer':'LGE','model':'OLED77Z3PCA','report_model':'OLED77Z3PCA','hardware':'alpha9gen6','board':'lg8k','version_id':'LGTV.2023.OLED77Z3','screen_param':'7680-4320-260','cast_model':'OLED77Z3PCA'},{'source':'lg_8k_pool.OLED88Z4PCA','brand':'LG','manufacturer':'LGE','model':'OLED88Z4PCA','report_model':'OLED88Z4PCA','hardware':'alpha9gen7','board':'lg8k','version_id':'LGTV.2024.OLED88Z4','screen_param':'7680-4320-320','cast_model':'OLED88Z4PCA'},{'source':'lg_8k_pool.86QNED99','brand':'LG','manufacturer':'LGE','model':'86QNED99','report_model':'86QNED99','hardware':'alpha9gen4','board':'lg8k','version_id':'LGTV.2021.86QNED99','screen_param':'7680-4320-300','cast_model':'86QNED99'},{'source':'sony_4k_pool.XR-85X95K','brand':'Sony','manufacturer':'Sony','model':'XR-85X95K','report_model':'XR85X95K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_85X95K','screen_param':'3840-2160-300','cast_model':'XR-85X95K'},{'source':'sony_4k_pool.XR-75X95K','brand':'Sony','manufacturer':'Sony','model':'XR-75X95K','report_model':'XR75X95K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_75X95K','screen_param':'3840-2160-280','cast_model':'XR-75X95K'},{'source':'sony_4k_pool.XR-65X90K','brand':'Sony','manufacturer':'Sony','model':'XR-65X90K','report_model':'XR65X90K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_65X90K','screen_param':'3840-2160-260','cast_model':'XR-65X90K'},{'source':'sony_4k_pool.XR-55X90K','brand':'Sony','manufacturer':'Sony','model':'XR-55X90K','report_model':'XR55X90K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_55X90K','screen_param':'3840-2160-240','cast_model':'XR-55X90K'},{'source':'sony_4k_pool.XR-65A95K','brand':'Sony','manufacturer':'Sony','model':'XR-65A95K','report_model':'XR65A95K','hardware':'mt5895','board':'mt5895','version_id':'SONYTV.2022.XR_65A95K','screen_param':'3840-2160-260','cast_model':'XR-65A95K'},{'source':'samsung_4k_pool.QA85QN90C','brand':'Samsung','manufacturer':'Samsung','model':'QA85QN90C','report_model':'QA85QN90C','hardware':'s5e9935','board':'neo4k','version_id':'SAMSUNGTV.2023.QN90C','screen_param':'3840-2160-300','cast_model':'QA85QN90C'},{'source':'samsung_4k_pool.QA75QN90C','brand':'Samsung','manufacturer':'Samsung','model':'QA75QN90C','report_model':'QA75QN90C','hardware':'s5e9935','board':'neo4k','version_id':'SAMSUNGTV.2023.QN90C','screen_param':'3840-2160-280','cast_model':'QA75QN90C'},{'source':'samsung_4k_pool.QA65QN90C','brand':'Samsung','manufacturer':'Samsung','model':'QA65QN90C','report_model':'QA65QN90C','hardware':'s5e9935','board':'neo4k','version_id':'SAMSUNGTV.2023.QN90C','screen_param':'3840-2160-260','cast_model':'QA65QN90C'},{'source':'samsung_4k_pool.QA55QN90C','brand':'Samsung','manufacturer':'Samsung','model':'QA55QN90C','report_model':'QA55QN90C','hardware':'s5e9935','board':'neo4k','version_id':'SAMSUNGTV.2023.QN90C','screen_param':'3840-2160-240','cast_model':'QA55QN90C'},{'source':'samsung_4k_pool.QA65S95C','brand':'Samsung','manufacturer':'Samsung','model':'QA65S95C','report_model':'QA65S95C','hardware':'s5e9935','board':'oled4k','version_id':'SAMSUNGTV.2023.S95C','screen_param':'3840-2160-260','cast_model':'QA65S95C'},{'source':'lg_4k_pool.OLED83C3PCA','brand':'LG','manufacturer':'LGE','model':'OLED83C3PCA','report_model':'OLED83C3PCA','hardware':'alpha9gen6','board':'lg4k','version_id':'LGTV.2023.OLED83C3','screen_param':'3840-2160-300','cast_model':'OLED83C3PCA'},{'source':'lg_4k_pool.OLED77C3PCA','brand':'LG','manufacturer':'LGE','model':'OLED77C3PCA','report_model':'OLED77C3PCA','hardware':'alpha9gen6','board':'lg4k','version_id':'LGTV.2023.OLED77C3','screen_param':'3840-2160-280','cast_model':'OLED77C3PCA'},{'source':'lg_4k_pool.OLED65C3PCA','brand':'LG','manufacturer':'LGE','model':'OLED65C3PCA','report_model':'OLED65C3PCA','hardware':'alpha9gen6','board':'lg4k','version_id':'LGTV.2023.OLED65C3','screen_param':'3840-2160-260','cast_model':'OLED65C3PCA'},{'source':'lg_4k_pool.OLED55C3PCA','brand':'LG','manufacturer':'LGE','model':'OLED55C3PCA','report_model':'OLED55C3PCA','hardware':'alpha9gen6','board':'lg4k','version_id':'LGTV.2023.OLED55C3','screen_param':'3840-2160-240','cast_model':'OLED55C3PCA'},{'source':'lg_4k_pool.86QNED90','brand':'LG','manufacturer':'LGE','model':'86QNED90','report_model':'86QNED90','hardware':'alpha7gen5','board':'lg4k','version_id':'LGTV.2022.86QNED90','screen_param':'3840-2160-300','cast_model':'86QNED90'},{'source':'tcl_8k_pool.85X925PRO','brand':'TCL','manufacturer':'TCL','model':'85X925 PRO','report_model':'85X925PRO','hardware':'mt9615','board':'tcl8k','version_id':'TCLTV.2021.X925PRO','screen_param':'7680-4320-280','cast_model':'85X925 PRO'},{'source':'tcl_8k_pool.75X925PRO','brand':'TCL','manufacturer':'TCL','model':'75X925 PRO','report_model':'75X925PRO','hardware':'mt9615','board':'tcl8k','version_id':'TCLTV.2021.X925PRO','screen_param':'7680-4320-260','cast_model':'75X925 PRO'},{'source':'tcl_4k_pool.85C845','brand':'TCL','manufacturer':'TCL','model':'85C845','report_model':'85C845','hardware':'mt9615','board':'tcl4k','version_id':'TCLTV.2023.C845','screen_param':'3840-2160-300','cast_model':'85C845'},{'source':'tcl_4k_pool.75C845','brand':'TCL','manufacturer':'TCL','model':'75C845','report_model':'75C845','hardware':'mt9615','board':'tcl4k','version_id':'TCLTV.2023.C845','screen_param':'3840-2160-280','cast_model':'75C845'},{'source':'tcl_4k_pool.65C845','brand':'TCL','manufacturer':'TCL','model':'65C845','report_model':'65C845','hardware':'mt9615','board':'tcl4k','version_id':'TCLTV.2023.C845','screen_param':'3840-2160-260','cast_model':'65C845'},{'source':'tcl_4k_pool.75C745','brand':'TCL','manufacturer':'TCL','model':'75C745','report_model':'75C745','hardware':'mt9615','board':'tcl4k','version_id':'TCLTV.2023.C745','screen_param':'3840-2160-280','cast_model':'75C745'},{'source':'tcl_4k_pool.65C745','brand':'TCL','manufacturer':'TCL','model':'65C745','report_model':'65C745','hardware':'mt9615','board':'tcl4k','version_id':'TCLTV.2023.C745','screen_param':'3840-2160-260','cast_model':'65C745'},{'source':'changhong_4k_pool.U65G7','brand':'CHANGHONG','manufacturer':'CHANGHONG','model':'U65G7','report_model':'U65G7','hardware':'mt9632','board':'changhong4k','version_id':'CHANGHONGTV.2022.U65G7','screen_param':'3840-2160-260','cast_model':'U65G7'},{'source':'changhong_4k_pool.U55G7','brand':'CHANGHONG','manufacturer':'CHANGHONG','model':'U55G7','report_model':'U55G7','hardware':'mt9632','board':'changhong4k','version_id':'CHANGHONGTV.2022.U55G7','screen_param':'3840-2160-240','cast_model':'U55G7'},{'source':'changhong_4k_pool.L55QCN1','brand':'CHANGHONG','manufacturer':'CHANGHONG','model':'L55QCN1','report_model':'L55QCN1','hardware':'mt9632','board':'changhong4k','version_id':'CHANGHONGTV.2021.L55QCN1','screen_param':'3840-2160-240','cast_model':'L55QCN1'},{'source':'changhong_4k_pool.U43QCN1','brand':'CHANGHONG','manufacturer':'CHANGHONG','model':'U43QCN1','report_model':'U43QCN1','hardware':'mt9632','board':'changhong4k','version_id':'CHANGHONGTV.2021.U43QCN1','screen_param':'3840-2160-220','cast_model':'U43QCN1'},{'source':'changhong_4k_pool.UD65YC5500UA','brand':'CHANGHONG','manufacturer':'CHANGHONG','model':'UD65YC5500UA','report_model':'UD65YC5500UA','hardware':'mt9632','board':'changhong4k','version_id':'CHANGHONGTV.2020.UD65YC5500UA','screen_param':'3840-2160-260','cast_model':'UD65YC5500UA'}]
def random_device_template ()->dict :
    pool_8k =[t for t in DEVICE_PROFILE_POOL if '8k'in t .get ('source','')]
    return secrets .choice (pool_8k if pool_8k else DEVICE_PROFILE_POOL )
def device_profile_from_template (template :dict ,android_id :str ,mac :str )->DeviceProfile :
    brand_id =sanitize_profile_id (template ['brand'])
    model_id =sanitize_profile_id (template ['model'])
    device =f'{brand_id }_{model_id }'
    product =f'{brand_id }_{model_id }'
    return DeviceProfile (android_id =android_id ,mac =mac ,hardware =template ['hardware'],board =template ['board'],brand =template ['brand'],device =device ,manufacturer =template ['manufacturer'],model =template ['model'],product =product ,tags ='release-keys',build_type ='user',user ='build',resolution =resolution_from_screen_param (template ['screen_param']),display =f"{template ['model']}-user 13 {template ['version_id']} 2024 release-keys",version_id =template ['version_id'],host =f'{brand_id }-tv-build',fingerprint =f"{template ['manufacturer']}/{product }/{device }:13/{template ['version_id']}/2024:user/release-keys",report_model =template ['report_model'])
def default_device_state ()->DeviceState :
    template =random_device_template ()
    profile =device_profile_from_template (template ,random_hex_string (16 ),random_mac_address ())
    return DeviceState (schema_version =1 ,profile_source =template ['source'],profile =profile ,screen_param =template ['screen_param'],cast_model =template ['cast_model'],x_uid =compute_x_uid (profile ),cloud_guid ='',registered_at =0.0 ,updated_at =now_f64 ())
def create_and_save_new_device (path :str )->DeviceState :
    new_state =default_device_state ()
    new_state .updated_at =now_f64 ()
    try :
        save_device_state (path ,new_state )
    except OSError :
        pass 
    return new_state 
def binary_dir ()->str :
    return os .path .dirname (os .path .abspath (__file__ ))or '.'
def load_device_state (path :str ):
    try :
        with open (path ,encoding ='utf-8')as f :
            text =f .read ()
    except FileNotFoundError :
        return (default_device_state (),False )
    except OSError as error :
        persistence_error(path, error)
        log(f'[持久化] 无法读取设备文件 {path}: {error}', min_interval=30.0)
        return (default_device_state (),False )
    try :
        data =json .loads (text )
    except ValueError as error :
        persistence_error(path, error)
        log(f'[持久化] 设备文件格式损坏 {path}: {error}', min_interval=30.0)
        return (default_device_state (),False )
    try :
        profile =DeviceProfile .from_dict (data .get ('profile',{}))
        state =DeviceState (schema_version =int (data .get ('schema_version',1 )),profile_source =str (data .get ('profile_source','')),profile =profile ,screen_param =str (data .get ('screen_param','')),cast_model =str (data .get ('cast_model','')),x_uid =str (data .get ('x_uid','')),cloud_guid =str (data .get ('cloud_guid','')),registered_at =float (data .get ('registered_at',0.0 )),updated_at =float (data .get ('updated_at',0.0 )))
    except (ValueError ,TypeError ,AttributeError ):
        return (default_device_state (),False )
    if len (state .profile .android_id )!=16 or not state .profile .mac :
        return (default_device_state (),False )
    state .x_uid =compute_x_uid (state .profile )
    if not state .screen_param :
        state .screen_param ='7680-4320-280'
    if not state .cast_model :
        state .cast_model =state .profile .model 
    return (state ,True )
def save_device_state (path :str ,state :DeviceState )->None :
    with persistence_lock(path):
        payload =dataclasses.asdict(state)
        try:
            with open(path, encoding='utf-8') as stream:
                previous =json.load(stream)
            if float(previous.get('updated_at', 0.0)) >state.updated_at:
                return
        except (OSError, ValueError, TypeError, AttributeError):
            pass
        try:
            atomic_json_write(path, payload)
        except OSError as error:
            log(f'[持久化] 无法保存设备文件 {path}: {error}', min_interval=30.0)
            raise
def infer_os_version (profile :DeviceProfile )->str :
    if ':'in profile .fingerprint :
        tail =profile .fingerprint .split (':',1 )[1 ]
        if '/'in tail :
            return tail .split ('/',1 )[0 ]
    return ''
def infer_sdk_int (profile :DeviceProfile )->str :
    major =infer_os_version (profile ).split ('.')[0 ]if infer_os_version (profile )else ''
    return {'13':'33','12':'31','11':'30','10':'29','9':'28','8':'26','7':'24','6':'23'}.get (major ,'')
def compute_x_uid (profile :DeviceProfile )->str :
    build_identity_str ='1698'+profile .hardware +profile .board +profile .brand +profile .device +profile .manufacturer +profile .model +profile .product +profile .tags +profile .build_type +profile .user +profile .resolution +profile .mac 
    uuid_part =java_uuid_from_hashes (java_string_hashcode (build_identity_str ),java_string_hashcode (profile .model ))
    return sha1_upper (f'{profile .android_id }|{uuid_part }')
def build_identity (profile :DeviceProfile ,app_channel :str ,version :str )->Identity :
    x_uid =compute_x_uid (profile )
    x_fingerprint ,ts ,_day0 =compute_fingerprint (x_uid ,current_time_ms ())
    headers ={'Accept':'application/json','Accept-Language':DEFAULT_ACCEPT_LANGUAGE ,'Referer':'api.cctv.cn','User-Agent':'cctv_app_tv','UID':profile .android_id ,'appChannel':app_channel ,'X-Uid':x_uid ,'X-Fingerprint':x_fingerprint ,'X-Version':version ,'Content-Type':'application/json; charset=utf-8','Connection':'Keep-Alive','Accept-Encoding':'gzip','Cache-Control':'no-cache'}
    return Identity (x_uid =x_uid ,x_fingerprint =x_fingerprint ,fingerprint_timestamp_ms =ts ,headers =headers )
def next_request_timestamp_ms ()->int :
    return current_time_ms ()
def fresh_headers (template :dict ,content_type :str ,accept =None ,force_ts =None )->dict :
    headers ={}
    if accept is not None :
        headers ['Accept']=accept 
    req_ts =force_ts if force_ts is not None else next_request_timestamp_ms ()
    headers ['X-Timestamp']=str (req_ts )
    headers ['X-Nonce']=str (uuid .uuid4 ())
    for key in ('Accept-Language', 'Referer', 'User-Agent', 'UID', 'appChannel', 'X-Uid', 'X-Fingerprint', 'X-Version'):
        if key in template:
            headers[key] = template[key]
    if content_type :
        headers ['Content-Type']=content_type 
    for key in ('Connection','Accept-Encoding','Cache-Control'):
        if key in template :
            headers [key ]=template [key ]
    return headers 
def compact_json_bytes (value ,escape_forward_slashes :bool )->bytes :
    text =json .dumps (value ,separators =(',',':'),ensure_ascii =False ,sort_keys =True )
    if escape_forward_slashes :
        text =text .replace ('/','\\/')
    return text .encode ('utf-8')
def normalize_aes_key (value :str )->bytes :
    raw =value .encode ('utf-8')
    return (raw +b'\x00'*32 )[:32 ]
def aes_gcm_decrypt_b64 (value :str ,key :str )->str :
    try :
        raw =base64 .b64decode (value ,validate =True )
    except (binascii .Error ,ValueError )as e :
        raise YsptpError (f'base64 decode failed: {e }')
    if len (raw )<=12 :
        raise YsptpError ('AES-GCM payload too short')
    try :
        plain =aes_gcm_decrypt (normalize_aes_key (key ),raw [:12 ],raw [12 :])
    except ValueError :
        raise YsptpError ('AES-GCM decrypt failed')
    try :
        return plain .decode ('utf-8')
    except UnicodeDecodeError as e :
        raise YsptpError (f'AES-GCM plaintext is not UTF-8: {e }')
def aes_gcm_encrypt_b64 (value :str ,key :str )->str :
    nonce =secrets .token_bytes (12 )
    try :
        encrypted =aes_gcm_encrypt (normalize_aes_key (key ),nonce ,value .encode ('utf-8'))
    except ValueError :
        raise YsptpError ('AES-GCM encrypt failed')
    return base64 .b64encode (nonce +encrypted ).decode ('ascii')
def rsa_encrypt_device_id (device_id :str )->str :
    try :
        der =base64 .b64decode (RSA_PUBLIC_KEY_B64 ,validate =True )
    except (binascii .Error ,ValueError )as e :
        raise YsptpError (f'RSA public key base64 decode failed: {e }')
    n ,e =parse_spki_rsa_pubkey (der )
    k =(n .bit_length ()+7 )//8 
    hlen =32 
    chunk_size =k -2 *hlen -2 
    out =bytearray ()
    data =device_id .encode ('utf-8')
    for i in range (0 ,len (data ),chunk_size ):
        chunk =data [i :i +chunk_size ]
        out +=rsa_oaep_sha256_encrypt (der ,chunk ,secrets .token_bytes (hlen ))
    return base64 .b64encode (bytes (out )).decode ('ascii')
def report_model_from_build (profile :DeviceProfile )->str :
    return profile .model .replace (profile .manufacturer ,'').replace (' ','')
def app_start_field (value ,limit :int )->str :
    return str (value )[:limit ]if limit >=0 else str (value )
def build_report_common_value (profile :DeviceProfile ,x_uid :str ,app_channel :str ,version :str ,sdk_version :str ,data_time_ms :int )->dict :
    model =profile .report_model or report_model_from_build (profile )
    return {'cctv_id':app_start_field (x_uid ,64 ),'device_id':app_start_field (profile .android_id ,64 ),'idfa':'','idfv':'','user_id':'','app_key':app_start_field (REPORT_APP_KEY ,64 ),'imei':'','android_id':app_start_field (profile .android_id ,64 ),'mac':app_start_field (profile .mac ,64 ),'device_builder_type':app_start_field (profile .build_type ,64 ),'device_hardware':app_start_field (profile .hardware ,64 ),'device_board':app_start_field (profile .board ,64 ),'device_brand':app_start_field (profile .brand ,64 ),'device_params':app_start_field (profile .device ,64 ),'device_display':app_start_field (profile .display ,64 ),'device_version_id':app_start_field (profile .version_id ,64 ),'device_host':app_start_field (profile .host ,128 ),'device_product':app_start_field (profile .product ,64 ),'device_tags':app_start_field (profile .tags ,64 ),'device_user':app_start_field (profile .user ,30 ),'device_fingerprint':app_start_field (profile .fingerprint ,128 ),'device_manufacturer':app_start_field (profile .manufacturer ,64 ),'device_model':app_start_field (model ,50 ),'device_resolution':app_start_field (profile .resolution ,20 ),'system_type':'Android','device_type':'TV','app_language':'CHINESE','app_version':app_start_field (version ,30 ),'sdk_version':app_start_field (sdk_version ,30 ),'os_version':app_start_field (infer_os_version (profile ),20 ),'app_channel':app_start_field (app_channel ,50 ),'data_time':app_start_field (data_time_ms ,13 )}
def build_app_start_body (profile :DeviceProfile ,x_uid :str ,app_channel :str ,version :str ,data_time_ms :int )->dict :
    return {'key':'app_start_d1','value':build_report_common_value (profile ,x_uid ,app_channel ,version ,'',data_time_ms )}
def build_collect_headers (profile :DeviceProfile )->dict :
    release =infer_os_version (profile )
    return {'Content-type':'application/x-www-form-urlencoded','Charset':'UTF-8','User-Agent':'Dalvik/2.1.0 (Linux; U; Android '+(release if release else 'Android')+f'; {profile .model } Build/{profile .version_id })','Connection':'Keep-Alive','Accept-Encoding':'gzip'}
def parse_result_code (value )->int |None :
    if isinstance (value ,dict ):
        for key in ('result','code','errCode','errcode','ret'):
            if key in value :
                raw =value [key ]
                if isinstance (raw ,bool ):
                    continue 
                if isinstance (raw ,int ):
                    return raw 
                if isinstance (raw ,str ):
                    try :
                        return int (raw )
                    except ValueError :
                        pass 
        for key in ('data','error','response'):
            if key in value :
                found =parse_result_code (value [key ])
                if found is not None :
                    return found 
    return None 
def extract_guid (value )->str :
    if isinstance (value ,dict ):
        data =value .get ('data')
        if isinstance (data ,dict ):
            guid =data .get ('guid')
            if isinstance (guid ,str ):
                return guid 
    return ''
def root_headers (version :str )->dict :
    return {'X-Uid':'ROOT','X-Fingerprint':'ROOT','X-Nonce':str (uuid .uuid4 ()),'X-Timestamp':str (next_request_timestamp_ms ()),'X-Version':version ,'UID':'ROOT','Referer':'api.cctv.cn','User-Agent':'cctv_app_tv','appChannel':'ROOT','Connection':'Keep-Alive','Accept-Encoding':'gzip'}
def build_vdn_appcommon (version :str )->str :
    return json .dumps ({'adid':'','av':version ,'an':VDN_APP_NAME ,'ap':'cctv_app_tv'},separators =(',',':'),ensure_ascii =False ,sort_keys =True )
def url_host (url :str )->str :
    try :
        return urllib .parse .urlsplit (url ).hostname or ''
    except ValueError :
        return ''
def live_playback_host_needs_signed_headers (host :str )->bool :
    lower =host .lower ()
    return 'liveali'in lower or 'liveten'in lower 
def default_cctv_playback_headers (uid :str )->dict :
    return {'UID':uid ,'APPID':AK ,'Referer':'api.cctv.cn','User-Agent':'cctv_app_tv'}
def cctv_playback_headers_for_entry (entry :ChannelEntry )->dict :
    headers =default_cctv_playback_headers (entry .android_id )
    for key in ('UID','APPID','APPRANDOMSTR','Referer','User-Agent','APPSIGN'):
        value =entry .playback_headers .get (key )
        if value :
            headers [key ]=value 
    return headers 
def entry_missing_signed_playback_headers (entry :ChannelEntry )->bool :
    host =entry .final_host or url_host (entry .final_url )
    if not live_playback_host_needs_signed_headers (host ):
        return False 
    for key in ('APPID','APPSIGN','APPRANDOMSTR'):
        value =entry .playback_headers .get (key ,'')
        if not value .strip ():
            return True 
    return False 
def ts_path_matches_final_url (ts_path :str ,final_url :str )->bool :
    try :
        parsed =urllib .parse .urlsplit (final_url )
    except ValueError :
        return False 
    prefix =parsed .path 
    if prefix .endswith ('.m3u8'):
        prefix =prefix [:-len ('.m3u8')]
    return bool (prefix )and ts_path .startswith (prefix )
def generate_app_random_str ()->str :
    return f'{secrets .randbits (32 ):08x}-0000-{secrets .randbits (32 )&65535 :04x}-0000-00000000{secrets .randbits (32 )&65535 :04x}'
def compute_vdn_code (app_secret :str ,random_str =None ):
    r =random_str if random_str is not None else generate_app_random_str ()
    return (md5_hex (f'{AK }{app_secret }{r }'),r )
def is_ts_url (value :str )->bool :
    try :
        path =urllib .parse .urlsplit (value ).path 
    except ValueError :
        return False 
    return path .lower ().endswith ('.ts')
def _rs_lines (text :str ):
    norm =text .replace ('\r\n','\n')
    lines =norm .split ('\n')
    if norm .endswith ('\n'):
        lines .pop ()
    return [ln [:-1 ]if ln .endswith ('\r')else ln for ln in lines ]
def rewrite_playlist_urls (text :str ,base_url :str )->str :
    return rewrite_uris(text, base_url)
def header_value_clean (value :str )->str :
    return value .replace ('\r','').replace ('\n','')
def form_urlencode_value (s :str )->str :
    out =[]
    for byte in s .encode ('utf-8'):
        ch =chr (byte )
        if ch .isascii ()and (ch .isalnum ()or ch in '*-._'):
            out .append (ch )
        elif byte ==32 :
            out .append ('+')
        else :
            out .append (f'%{byte :02X}')
    return ''.join (out )
def form_encode (pairs )->bytes :
    return '&'.join ((f'{form_urlencode_value (k )}={form_urlencode_value (v )}'for k ,v in pairs )).encode ('utf-8')
def _normalize_network_error (e :Exception )->str :
    if isinstance (e ,ConnectionRefusedError ):
        return f'connection refused: {e }'
    if isinstance (e ,ConnectionResetError ):
        return f'connection reset by peer: {e }'
    if isinstance (e ,(socket .timeout ,TimeoutError )):
        return f'operation timed out: {e }'
    if isinstance (e ,socket .gaierror ):
        return f'failed to lookup address: {e }'
    if isinstance (e ,urllib .error .URLError ):
        reason =e .reason 
        if isinstance (reason ,Exception ):
            return _normalize_network_error (reason )
        return f'network error: {e }'
    return f'network error: {e }'
class HttpResponse :
    def __init__ (self ,status :int ,reason :str ,headers :dict ,body :bytes ):
        self .status =status 
        self .reason =reason 
        self .headers =headers 
        self .body =body 
    def text (self )->str :
        return self .body .decode ('utf-8',errors ='replace')
class HttpClient :
    def __init__ (self ,timeout :float ,insecure_tls :bool ):
        self ._timeout =max (timeout ,0.1 )
        if insecure_tls :
            self ._ctx =ssl ._create_unverified_context ()
        else :
            self ._ctx =ssl .create_default_context ()
        jar =http .cookiejar .CookieJar ()
        https_handler =urllib .request .HTTPSHandler (context =self ._ctx )
        self ._opener =urllib .request .build_opener (urllib .request .ProxyHandler (),urllib .request .HTTPCookieProcessor (jar ),https_handler )
        self ._jar =jar 
    def _send (self ,method :str ,url :str ,headers :dict ,data :bytes |None )->HttpResponse :
        req =urllib .request .Request (url ,data =data ,method =method )
        for k ,v in headers .items ():
            req .add_header (k ,v )
        try :
            try :
                with self ._opener .open (req ,timeout =self ._timeout )as resp :
                    status =resp .status 
                    reason =resp .reason or ''
                    hdrs ={k .lower ():v for k ,v in resp .headers .items ()}
                    body =resp .read ()
            except urllib .error .HTTPError as e :
                status =e .code 
                reason =e .reason or ''
                try :
                    hdrs ={k .lower ():v for k ,v in e .headers .items ()}if e .headers else {}
                except Exception :
                    hdrs ={}
                try :
                    body =e .read ()
                except Exception :
                    body =b''
        except Exception as e :
            raise YsptpError (_normalize_network_error (e ))
        if 'gzip'in hdrs .get ('content-encoding','').lower ():
            try :
                body =gzip .decompress (body )
            except (OSError ,EOFError ):
                pass 
        return HttpResponse (status ,reason ,hdrs ,body )
    def get (self ,url :str ,headers :dict )->HttpResponse :
        return self ._send ('GET',url ,headers ,None )
    def post_bytes (self ,url :str ,headers :dict ,data :bytes )->HttpResponse :
        return self ._send ('POST',url ,headers ,data )
    def post_json (self ,url :str ,headers :dict ,body )->HttpResponse :
        data =json .dumps (body ,separators =(',',':'),ensure_ascii =False ,sort_keys =True ).encode ('utf-8')
        return self ._send ('POST',url ,headers ,data )
    def post_form (self ,url :str ,headers :dict ,pairs )->HttpResponse :
        return self ._send ('POST',url ,headers ,form_encode (pairs ))
def response_json (resp :HttpResponse ):
    status =resp .status 
    text =resp .text ()
    try :
        value =json .loads (text )
    except ValueError :
        value =None 
    return (status ,text ,value )
def http_status_text (status :int ,reason :str )->str :
    return f'{status } {reason }'.strip ()if reason else str (status )
class ResolverState :
    def __init__ (self ):
        self .cache :dict [str ,ChannelEntry ]={}
        self .playlist_cache :dict [str ,PlaylistCacheEntry ]={}
        self .background_refreshing :dict [str ,float ]={}
        self .channel_failures :dict [str ,tuple [float ,str ,int ]]={}
        self .generation =0 
        self .session_generation =0 
        self .sessions :dict [int ,AppSession ]={}
        self .channel_slot_map :dict [str ,int ]={}
        self .slot_last_reset :dict [int ,float ]={}
        self .last_control_request_at =0.0 
        self .last_business_end_at =0.0 
        self .refreshing_channel =''
        self .last_error =''
        self .last_error_at =0.0 
        self .identity_reset_error_count =0 
        self .channel_last_access :dict [str ,float ]={}
        self .identity_reset_count =0 
        self .last_identity_reset_at =0.0 
        self .last_identity_reset_reason =''
        self .ad_display =False 
        self .zap_channel =''
        self .zap_time =0.0 
        self .zap_pending =''
        self .zap_generation =0 
        self .zap_times :dict [str ,float ]={}
        self .zap_pending_channels :set [str ]=set ()
        self .zap_generations :dict [str ,int ]={}
        self .last_device_wipe_at =0.0 
        self .device_wipe_day =''
        self .device_wipe_count =0 
    @property 
    def app_session (self ):
        return self .sessions .get (0 )or (list (self .sessions .values ())[0 ]if self .sessions else None )
    @app_session .setter 
    def app_session (self ,val ):
        if val is not None :
            self .sessions [0 ]=val 
        else :
            self .sessions .pop (0 ,None )
@dataclasses .dataclass 
class AppSession :
    profile :DeviceProfile 
    identity :Identity 
    client :HttpClient 
    session_key :str 
    cloud_guid :str 
    version :str 
    screen_param :str 
    cast_model :str 
    created_at :float 
    generation :int 
    last_heartbeat_at :float 
    heartbeat_count :int 
    last_heartbeat_result :str 
    last_heartbeat_error :str 
    linked_channels :set =dataclasses .field (default_factory =set )
class RefreshQueue :
    def __init__ (self ):
        self .cond =threading .Condition ()
        self .queued :collections .deque [str ]=collections .deque ()
        self .queued_channels :dict [str ,float ]={}
        self .running_channel =''
        self .running_started_at =0.0 
        self .enqueued_total =0 
        self .dropped_total =0 
        self .completed_total =0 
        self .failed_total =0 
        self .last_enqueued_at =0.0 
        self .last_finished_at =0.0 
        self .last_dropped_at =0.0 
        self .last_drop_reason =''
class HttpQueue :
    def __init__ (self ):
        self .cond =threading .Condition ()
        self .queued :collections .deque =collections .deque ()
        self .active_workers =0 
        self .enqueued_total =0 
        self .rejected_total =0 
        self .completed_total =0 
        self .panicked_total =0 
        self .last_enqueued_at =0.0 
        self .last_completed_at =0.0 
        self .last_rejected_at =0.0 
class Resolver :
    def __init__ (self ,args :argparse .Namespace ):
        self .args =args 
        self .generic_client =HttpClient (args .timeout ,args .insecure_tls )
        self .state =ResolverState ()
        self .state_lock =threading .Lock ()
        self .control_lock =threading .RLock ()
        self .playlist_locks_lock =threading .Lock ()
        self .playlist_locks :dict [str ,threading .Lock ]={}
        self .refresh_queue =RefreshQueue ()
        self .http_queue =HttpQueue ()
        self .state .cache =load_cache (args .meta_json )
        self.state.generation =max((entry.generation for entry in self.state.cache.values()), default=0)
        self.state.session_generation =max((entry.session_generation for entry in self.state.cache.values()), default=0)
        self.stop_event =threading.Event()
        self._threads =[]
        self._channel_flights ={}
        self._session_results ={}
        self._session_epoch =0
        self._playlist_raw ={}
        self._playlist_progress ={}
        self._playlist_channel_epoch ={}
        self._segment_failures ={}
        self._segment_retry_due ={}
        self._playlist_flights ={}
        self._playlist_failures ={}
        self._playlist_pool =ThreadPoolExecutor(max_workers=4, thread_name_prefix='playlist-refresh')
        self._foreground_pool =ThreadPoolExecutor(max_workers=4, thread_name_prefix='device-playlist')
        self._foreground_flights ={}
        self._last_control_mono =0.0
        self._last_business_mono =0.0
        self._failure_mono ={}
        self._worker_error =''
        self._meta_lock =threading.RLock()
        self._stats =collections.Counter()
    def start_heartbeat (self ):
        def loop ():
            while not self.stop_event.wait(max(self.args.heartbeat_interval, 1.0)):
                try :
                    self .send_heartbeat ()
                except Exception as error:
                    self._worker_error =f'heartbeat worker: {error}'
                    set_resolver_ready(False)
                    log(f'[心跳] 后台任务异常: {error}', min_interval=30.0)
        t =threading .Thread (target =loop ,daemon =True ,name ='heartbeat-keeper')
        self._threads.append(t)
        t .start ()
    def start_refresh_worker (self ):
        t =threading .Thread (target =self .refresh_worker_loop ,daemon =True ,name ='refresh-worker')
        self._threads.append(t)
        t .start ()
    def close(self):
        self.stop_event.set()
        with self.refresh_queue.cond:
            self.refresh_queue.cond.notify_all()
        # Queued wrappers must run to finish their shared Future with a shutdown
        # error; cancelling only the executor Future would strand HTTP waiters.
        self._playlist_pool.shutdown(wait=False, cancel_futures=False)
        self._foreground_pool.shutdown(wait=False, cancel_futures=True)
        for worker in self._threads:
            if worker is not threading.current_thread():
                worker.join(timeout=1.0)
    def enqueue_background_refresh (self ,channel :str ):
        now =now_f64 ()
        q =self .refresh_queue 
        with q .cond :
            if q .running_channel ==channel or channel in q .queued_channels :
                return ('already_active','')
            limit =int (self .args .background_refresh_queue_limit )
            if limit ==0 or len (q .queued )>=limit :
                q .dropped_total +=1 
                q .last_dropped_at =now 
                if limit ==0 :
                    q .last_drop_reason =f'background refresh queue disabled; channel={channel }'
                else :
                    q .last_drop_reason =f'background refresh queue full ({len (q .queued )}/{limit }); channel={channel }'
                return ('rejected',q .last_drop_reason )
            q .queued .append (channel )
            q .queued_channels [channel ]=now 
            q .enqueued_total +=1 
            q .last_enqueued_at =now 
            q .cond .notify ()
            return ('enqueued','')
    def refresh_worker_loop(self):
        q =self.refresh_queue
        while not self.stop_event.is_set():
            due =[]
            with self.state_lock:
                for channel, (deadline, generation) in list(self._segment_retry_due.items()):
                    if time.monotonic() >=deadline:
                        self._segment_retry_due.pop(channel, None)
                        current =self.state.cache.get(channel)
                        if current is not None and current.generation ==generation:
                            self.state.background_refreshing[channel] =now_f64()
                            due.append(channel)
            for channel in due:
                status, _reason =self.enqueue_background_refresh(channel)
                if status =='rejected':
                    with self.state_lock:
                        self.state.background_refreshing.pop(channel, None)
            with q.cond:
                if not q.queued and not self.stop_event.is_set():
                    q.cond.wait(timeout=1.0)
                if self.stop_event.is_set():
                    return
                if not q.queued:
                    continue
                channel =q.queued.popleft()
                q.queued_channels.pop(channel, None)
                q.running_channel =channel
                q.running_started_at =now_f64()
            ok =False
            try:
                ok =self.refresh_channel_background(channel)
            except Exception as error:
                self._worker_error =f'refresh worker: {error}'
                log(f'[{channel}] 后台刷新异常: {error}', min_interval=30.0)
            finally:
                with self.state_lock:
                    self.state.background_refreshing.pop(channel, None)
                with q.cond:
                    q.running_channel =''
                    q.running_started_at =0.0
                    q.last_finished_at =now_f64()
                    if ok:
                        q.completed_total +=1
                    else:
                        q.failed_total +=1
    @contextlib.contextmanager
    def control_request_slot(self, _label):
        # Telemetry also uses this path, so the slot itself owns serialization.
        with self.control_lock:
            interval =max(0.0, float(self.args.refresh_interval))
            wait =max(0.0, interval -(time.monotonic() -self._last_control_mono))
            if self.stop_event.wait(wait):
                raise YsptpError('resolver is shutting down')
            jitter =self.control_step_jitter_duration()
            if jitter is not None and self.stop_event.wait(jitter):
                raise YsptpError('resolver is shutting down')
            try:
                yield
            finally:
                with self.state_lock:
                    self._last_control_mono =time.monotonic()
                    self.state.last_control_request_at =now_f64()
    def control_step_jitter_duration (self ):
        min_ms =int (self .args .control_step_jitter_min_ms )
        max_ms =int (self .args .control_step_jitter_max_ms )
        if max_ms ==0 :
            return None 
        upper =max (max_ms ,min_ms )
        span =upper -min_ms 
        extra =secrets .randbelow (span +1 )if span else 0 
        return (min_ms +extra )/1000.0 
    def app_session_fresh (self ,sess :AppSession )->bool :
        return float (self .args .session_ttl )<=0.0 or now_f64 ()-sess .created_at <float (self .args .session_ttl )
    def app_session_ttl_remaining (self ,sess :AppSession ):
        if float (self .args .session_ttl )<=0.0 :
            return None 
        return float (self .args .session_ttl )-(now_f64 ()-sess .created_at )
    def slot_device_json_path (self ,slot :int )->str :
        base =self .args .device_json 
        if slot ==0 :
            return base 
        root ,ext =os .path .splitext (base )
        return f'{root }-slot{slot }{ext }'
    def evict_idle_links (self ,app_session ,idle_sec =15.0 ):
        now =now_f64 ()
        with self .state_lock :
            last =dict (self .state .channel_last_access )
        for ch_slug in list (app_session .linked_channels ):
            if now -last .get (ch_slug ,0.0 )>idle_sec :
                app_session .linked_channels .discard (ch_slug )
    def zap_debounced (self ,channel :str )->bool :
        if channel in TRUE_4K_CHANNELS :
            return False 
        try :
            debounce =float (getattr (self .args ,'zap_debounce',10.0 ))
        except (TypeError ,ValueError ):
            debounce =10.0 
        if debounce <=0.0 :
            return False 
        now =now_f64 ()
        with self .state_lock :
            entry =self .state .cache .get (channel )
            if entry is not None and entry .fresh (now )and not entry_missing_signed_playback_headers (entry ):
                return False 
            sess =self .state .sessions .get (0 )
            if sess is not None and channel in sess .linked_channels and entry is not None and (now -entry .expires_at <30.0 ):
                return False 
            self .state .zap_channel =channel 
            if channel in self .state .zap_pending_channels :
                return True 
            ch_zap_time =self .state .zap_times .get (channel ,0.0 )
            if ch_zap_time <=0.0 or (now -ch_zap_time >max (debounce *3.0 ,30.0 )):
                ch_zap_time =now 
                self .state .zap_times [channel ]=now 
                self .state .zap_time =now 
            if now -ch_zap_time <debounce :
                self .state .zap_pending =channel 
                self .state .zap_pending_channels .add (channel )
                self .state .zap_generation +=1 
                gen =self .state .zap_generations .get (channel ,0 )+1 
                self .state .zap_generations [channel ]=gen 
                delay =max (0.1 ,debounce -(now -ch_zap_time ))
                threading .Thread (target =self ._zap_resolve_worker ,args =(channel ,gen ,delay ),daemon =True ).start ()
                return True 
            return False 
    def _zap_resolve_worker(self, channel, gen, delay):
        try:
            if self.stop_event.wait(delay):
                return
            now =now_f64()
            with self.state_lock:
                if gen !=self.state.zap_generations.get(channel, 0):
                    return
                last_acc =self.state.channel_last_access.get(channel, 0.0)
                if (now -last_acc >max(delay +2.0, 12.0)) or (self.state.zap_channel !=channel and now -last_acc >5.0):
                    self.state.zap_times.pop(channel, None)
                    return
            self.ensure_channel(channel, force=True)
            log(f'[{channel}] 高码率后台预取完成, 继续停留将自动升级', min_interval=10.0)
        except Exception as error:
            log(f'[{channel}] 高码率后台预取失败: {error}, 继续 1080p', min_interval=10.0)
        finally:
            with self.state_lock:
                self.state.zap_pending_channels.discard(channel)
                if self.state.zap_pending ==channel:
                    self.state.zap_pending =''
    def rotate_device_on_400(self, reason):
        with self.control_lock:
            now =now_f64()
            with self.state_lock:
                if now -self.state.last_device_wipe_at <300.0:
                    return False
                day =time.strftime('%Y-%m-%d', time.localtime(now))
                if self.state.device_wipe_day !=day:
                    self.state.device_wipe_day =day
                    self.state.device_wipe_count =0
                if self.state.device_wipe_count >=5:
                    log('[设备] 今日自动换新身份已达 5 次，请检查网络或设备', min_interval=60.0)
                    return False
                self.state.last_device_wipe_at =now
                self.state.device_wipe_count +=1
                count =self.state.device_wipe_count
                self._session_epoch +=1
                self._session_results.clear()
                self.state.sessions.clear()
                self.state.cache.clear()
                self.state.playlist_cache.clear()
                self._playlist_raw.clear()
                self._playlist_progress.clear()
                self._playlist_channel_epoch.clear()
                self._segment_failures.clear()
                self._segment_retry_due.clear()
                self._playlist_failures.clear()
                self.state.channel_failures.clear()
                self._failure_mono.clear()
                self.state.channel_last_access.clear()
            set_resolver_ready(False)
            create_and_save_new_device(self.slot_device_json_path(0))
            log(f'[设备] 身份失效 ({reason})，已换新设备身份 (5 分钟内仅一次，今日第 {count} 次)')
            return True
    def get_slot_for_channel (self ,channel :str )->int :
        return 0 
    def ensure_slot_session(self, slot):
        # Acquire the protocol lock before joining a slot flight. Callers may
        # already hold this RLock, so a leader waiting for it cannot deadlock us.
        with self.control_lock:
            if self.stop_event.is_set():
                raise YsptpError('resolver is shutting down')
            with self.state_lock:
                sess =self.state.sessions.get(slot)
                if sess is not None and self.app_session_fresh(sess):
                    remaining =self.app_session_ttl_remaining(sess)
                    if remaining is None or remaining >300.0:
                        return sess
                previous =self._session_results.get(slot)
                if previous is not None and previous[0] ==self._session_epoch and time.monotonic() <previous[2]:
                    flight =previous[1]
                    leader =False
                else:
                    flight =Future()
                    epoch =self._session_epoch
                    self._session_results[slot] =(epoch, flight, float('inf'))
                    self.state.session_generation +=1
                    generation =self.state.session_generation
                    leader =True
            if not leader:
                self._stats['session_shared'] +=1
                return flight.result()
            try:
                self._stats['session_attempts'] +=1
                sess =self.bootstrap_session(generation, save_to_disk=True, fast=True, device_json=self.slot_device_json_path(slot))
                with self.state_lock:
                    if epoch !=self._session_epoch:
                        raise YsptpError('device identity changed during session creation')
                    self.state.sessions[slot] =sess
                    self._session_results[slot] =(epoch, flight, time.monotonic() +2.0)
                flight.set_result(sess)
                return sess
            except Exception as error:
                if not isinstance(error, YsptpError):
                    error =YsptpError(f'session creation failed: {error}')
                with self.state_lock:
                    self._session_results[slot] =(self._session_epoch, flight, time.monotonic() +2.0)
                flight.set_exception(error)
                raise error
    def record_recoverable_error(self, reason):
        if not is_identity_recoverable_error(reason):
            return False
        threshold =int(self.args.identity_reset_error_threshold)
        if threshold <=0:
            return False
        with self.state_lock:
            now =now_f64()
            if self.state.last_identity_reset_at >0.0 and now -self.state.last_identity_reset_at <float(self.args.identity_reset_cooldown):
                return False
            self.state.identity_reset_error_count =min(self.state.identity_reset_error_count +1, 2 **31 -1)
            should_reset =self.state.identity_reset_error_count >=threshold
        if not should_reset or not self.rotate_device_on_400('recoverable:'+reason[:80]):
            return False
        with self.state_lock:
            self.state.identity_reset_error_count =0
            self.state.identity_reset_count +=1
            self.state.last_identity_reset_at =now_f64()
            self.state.last_identity_reset_reason =reason
        self.write_meta()
        return True
    def clear_recoverable_error_count (self ):
        with self .state_lock :
            self .state .identity_reset_error_count =0 
    def is_channel_in_cooldown(self, channel):
        with self.state_lock:
            return self._channel_cooldown_locked(channel) is not None
    def _channel_cooldown_locked(self, channel):
        fail =self.state.channel_failures.get(channel)
        if fail is None:
            return None
        failed_at, error, count =fail
        cooldown =15.0 if count <=1 else (60.0 if count ==2 else 120.0)
        failed_mono =self._failure_mono.get(channel)
        elapsed =time.monotonic() -failed_mono if failed_mono is not None else now_f64() -failed_at
        if elapsed <cooldown:
            return YsptpError(f'channel {channel} in cooldown ({max(0, int(elapsed))}s/{int(cooldown)}s): {error}')
        return None
    def _channel_entry_valid_locked(self, entry):
        return (entry is not None and not entry_missing_signed_playback_headers(entry)
                and self._segment_failures.get(entry.channel, (None,))[0] !=entry.generation)
    def get_channel_failure_info (self ,channel :str ):
        with self .state_lock :
            return self .state .channel_failures .get (channel )
    def clear_channel_cooldown(self, channel):
        with self.state_lock:
            self.state.channel_failures.pop(channel, None)
            self._failure_mono.pop(channel, None)
    def record_segment_failure(self, channel, generation, status):
        if status not in (401, 403, 404):
            return False
        with self.state_lock:
            entry =self.state.cache.get(channel)
            if entry is None or entry.generation !=generation:
                return False
            if self._segment_failures.get(channel, (None,))[0] ==generation:
                return False
            wall, mono =now_f64(), time.monotonic()
            message =f'upstream segment HTTP {status} (source generation {generation})'
            self._segment_failures[channel] =(generation, status, mono)
            self._playlist_channel_epoch[channel] =self._playlist_channel_epoch.get(channel, 0) +1
            self._playlist_raw.pop(channel, None)
            self.state.playlist_cache.pop(channel, None)
            previous =self.state.channel_failures.get(channel)
            count =previous[2] +1 if previous else 1
            self.state.channel_failures[channel] =(wall, message, count)
            self._failure_mono[channel] =mono
            entry.expires_at =min(entry.expires_at, wall -1.0)
            entry.last_refresh_error =message
            entry.last_refresh_failed_at =wall
            self.state.last_error =message
            self.state.last_error_at =wall
            cooldown =15.0 if count <=1 else (60.0 if count ==2 else 120.0)
            self._segment_retry_due[channel] =(mono +cooldown +0.05, generation)
            self._stats['segment_source_invalidated'] +=1
        with self.refresh_queue.cond:
            self.refresh_queue.cond.notify_all()
        log(f'[{channel}] 分片授权/地址失效，暂时回退并在冷却后重建源', min_interval=15.0)
        return True
    def ensure_channel(self, channel, force=False, expected_generation=None):
        if self.stop_event.is_set():
            raise YsptpError('resolver is shutting down')
        schedule =False
        with self.state_lock:
            now =now_f64()
            entry =self.state.cache.get(channel)
            valid =self._channel_entry_valid_locked(entry)
            if force and expected_generation is not None and valid and entry.generation !=expected_generation:
                return entry
            if not force and valid:
                if entry.fresh(now):
                    return entry
                if entry.stale_usable(now, float(self.args.stale_while_refresh_ttl)):
                    retry_at =entry.last_refresh_failed_at +float(self.args.refresh_error_cooldown)
                    if now >=retry_at and channel not in self.state.background_refreshing and self._channel_cooldown_locked(channel) is None:
                        self.state.background_refreshing[channel] =now
                        schedule =True
                    stale =entry
                else:
                    stale =None
            else:
                stale =None
            if stale is None:
                flight =self._channel_flights.get(channel)
                if flight is not None:
                    leader =False
                else:
                    cooldown =self._channel_cooldown_locked(channel)
                    if cooldown is not None:
                        raise cooldown
                    flight =Future()
                    self._channel_flights[channel] =flight
                    baseline =entry.generation if entry is not None else None
                    leader =True
        if stale is not None:
            if schedule:
                status, reason =self.enqueue_background_refresh(channel)
                if status =='rejected':
                    with self.state_lock:
                        self.state.background_refreshing.pop(channel, None)
                        stale.last_refresh_error =reason
                        stale.last_refresh_failed_at =now_f64()
            return stale
        if not leader:
            self._stats['channel_shared'] +=1
            return flight.result()
        try:
            with self.control_lock:
                # Other channels can fail or rotate the device while this
                # request waits for protocol access. Recheck before doing I/O.
                with self.state_lock:
                    current =self.state.cache.get(channel)
                    valid =self._channel_entry_valid_locked(current)
                    if valid and ((not force and current.fresh(now_f64())) or (force and current.generation !=baseline)):
                        result =current
                    else:
                        cooldown =self._channel_cooldown_locked(channel)
                        if cooldown is not None:
                            raise cooldown
                        result =None
                if result is None:
                    try:
                        self._stats['channel_attempts'] +=1
                        result =self.refresh_channel_controlled(channel)
                    except Exception as error:
                        if not isinstance(error, YsptpError):
                            error =YsptpError(f'channel {channel} resolution failed: {error}')
                        err_text =str(error)
                        # A single bounded recovery for the known invalid-device
                        # response; all waiters still share this one operation.
                        if 'HTTP 400' in err_text and self.rotate_device_on_400(channel +':' +err_text[:60]):
                            try:
                                result =self.refresh_channel_controlled(channel)
                            except Exception as retry_error:
                                error =retry_error if isinstance(retry_error, YsptpError) else YsptpError(str(retry_error))
                                err_text =str(error)
                        if result is None:
                            with self.state_lock:
                                now =now_f64()
                                self.state.last_error =err_text
                                self.state.last_error_at =now
                                previous =self.state.channel_failures.get(channel)
                                count =previous[2] +1 if previous else 1
                                self.state.channel_failures[channel] =(now, err_text, count)
                                self._failure_mono[channel] =time.monotonic()
                                cached =self.state.cache.get(channel)
                                if cached is not None:
                                    cached.last_refresh_error =err_text
                                    cached.last_refresh_failed_at =now
                                if self._channel_entry_valid_locked(cached) and cached.stale_usable(now, float(self.args.stale_while_refresh_ttl)):
                                    result =cached
                                if is_session_invalidating_error(err_text):
                                    slot =self.get_slot_for_channel(channel)
                                    if self.state.sessions.pop(slot, None) is not None:
                                        self._session_results.pop(slot, None)
                            if self.record_recoverable_error(err_text):
                                result =None
                            if result is None:
                                raise error
                self.write_meta()
            flight.set_result(result)
            return result
        except Exception as error:
            self.write_meta()
            flight.set_exception(error)
            raise
        finally:
            with self.state_lock:
                if self._channel_flights.get(channel) is flight:
                    self._channel_flights.pop(channel, None)
    def refresh_channel_background(self, channel):
        try:
            with self.state_lock:
                current =self.state.cache.get(channel)
                if current is not None and current.fresh(now_f64()) and current.expires_at -now_f64() >180.0 and not entry_missing_signed_playback_headers(current):
                    return True
                generation =current.generation if current is not None else None
            result =self.ensure_channel(channel, force=True, expected_generation=generation)
            return not bool(result.last_refresh_error)
        except Exception as error:
            log(f'[{channel}] 后台拉源失败: {error}', min_interval=30.0)
            return False
        finally:
            with self.state_lock:
                self.state.background_refreshing.pop(channel, None)
    def refresh_channel_controlled(self, channel):
        wait =max(0.0, float(self.args.refresh_interval) -(time.monotonic() -self._last_business_mono))
        if self.stop_event.wait(wait):
            raise YsptpError('resolver is shutting down')
        with self.state_lock:
            self.state.refreshing_channel =channel
            self.state.generation +=1
            generation =self.state.generation
        log(f'[{channel}] 正在向央视频协议引擎请求直播源…', min_interval=10.0)
        try:
            slot =self.get_slot_for_channel(channel)
            limit =int(getattr(self.args, 'links_per_device', 6))
            session =self.ensure_slot_session(slot)
            if limit >0 and channel not in session.linked_channels and len(session.linked_channels) >=limit:
                self.evict_idle_links(session, LINK_IDLE_TIMEOUT)
                if len(session.linked_channels) >=limit:
                    raise YsptpError(f'device link quota reached ({limit}), fallback to 1080p')
            live_id =channel_by_name(channel)
            if live_id is None:
                raise YsptpError(f'unknown channel {channel}')
            entry =self.resolve_channel_once(session, channel, live_id, generation)
            session.linked_channels.add(channel)
            with self.state_lock:
                self.state.cache[channel] =entry
                self.state.playlist_cache.pop(channel, None)
                self._playlist_raw.pop(channel, None)
                self._playlist_failures ={key: value for key, value in self._playlist_failures.items() if key[0] !=channel}
                self.state.channel_failures.pop(channel, None)
                self._failure_mono.pop(channel, None)
                self._segment_retry_due.pop(channel, None)
                self.state.identity_reset_error_count =0
                self.state.last_error =''
            label =entry.rate_name or entry.rate or '高码率'
            log(f'[{channel}] 直播源获取成功 (协议档位: {label})', min_interval=10.0)
            return entry
        finally:
            with self.state_lock:
                self._last_business_mono =time.monotonic()
                self.state.last_business_end_at =now_f64()
                self.state.refreshing_channel =''
    def new_ytpaddr_client (self )->HttpClient :
        return HttpClient (float (self .args .timeout ),bool (self .args .insecure_tls ))
    def bootstrap_session (self ,generation :int ,device_state :DeviceState |None =None ,save_to_disk :bool =True ,fast :bool =False ,device_json :str ='' )->AppSession :
        target_json =device_json or self .args .device_json 
        if device_state is None :
            device_state ,existed =load_device_state (target_json )
            if (not existed or device_state .registered_at <=0.0 )and save_to_disk :
                device_state =default_device_state ()
                device_state .updated_at =now_f64 ()
                try :
                    save_device_state (target_json ,device_state )
                except OSError :
                    pass 
        profile =device_state .profile 
        app_channel ='dangbei'
        version ='1.4.1'
        identity =build_identity (profile ,app_channel ,version )
        device_state .x_uid =identity .x_uid 
        client =self .new_ytpaddr_client ()
        app_start =self .app_start_flow (client ,profile ,identity ,app_channel ,version )
        session_key =app_start .session_key 
        try :
            cloud_guid =self .cloud_registration_flow (identity ,identity .x_uid )
        except YsptpError as reg_err :
            raise YsptpError (f'cloud device registration failed: {reg_err }')
        if not cloud_guid and device_state .cloud_guid :
            cloud_guid =device_state .cloud_guid 
        if not cloud_guid :
            raise YsptpError ('cloud device registration failed: empty guid, fallback to 1080p')
        now =now_f64 ()
        device_state .x_uid =identity .x_uid 
        device_state .updated_at =now 
        if cloud_guid :
            device_state .cloud_guid =cloud_guid 
            if device_state .registered_at <=0.0 :
                device_state .registered_at =now 
        if save_to_disk :
            try :
                save_device_state (target_json ,device_state )
            except OSError :
                pass 
        hb =self .heartbeat_flow (profile ,identity ,app_channel ,version ,cloud_guid )
        if hb not in ('', '0', '200', 0, 200, None):
            raise YsptpError(f'heartbeat result {hb}')
        def _bg_telemetry ():
            try :
                self .collect_report (profile ,{'key':'app_start_d1','value':build_report_common_value (profile ,identity .x_uid ,app_channel ,version ,COLLECT_SDK_VERSION ,current_time_ms ())})
            except Exception :
                pass 
            try :
                self .dictionary_obtain (version )
            except Exception :
                pass 
            if cloud_guid :
                try :
                    self .device_info_report_flow (profile ,identity ,app_channel ,version ,cloud_guid )
                except Exception :
                    pass 
            try :
                self .index_flow (client ,identity ,app_channel )
            except Exception :
                pass 
            try :
                self .warmup_flow (client ,identity ,version )
            except Exception :
                pass 
        threading .Thread (target =_bg_telemetry ,daemon =True ,name ='telemetry-worker').start ()
        return AppSession (profile =profile ,identity =identity ,client =client ,session_key =session_key ,cloud_guid =cloud_guid ,version =version ,screen_param =device_state .screen_param ,cast_model =device_state .cast_model ,created_at =now_f64 (),generation =generation ,last_heartbeat_at =now_f64 (),heartbeat_count =1 ,last_heartbeat_result =hb ,last_heartbeat_error ='')
    def collect_report (self ,profile :DeviceProfile ,body :dict )->None :
        headers =build_collect_headers (profile )
        resp =self .generic_client .post_form (COLLECT_REPORT_URL ,headers ,[('info',json .dumps (body ,separators =(',',':'),ensure_ascii =False ,sort_keys =True ))])
        if not 200 <=resp .status <300 :
            raise YsptpError (f'collect report HTTP {http_status_text (resp .status ,resp .reason )}')
    def dictionary_obtain (self ,version :str )->None :
        with self .control_request_slot ('dictionary_obtain'):
            resp =self .generic_client .post_bytes (DICTIONARY_URL ,root_headers (version ),b'')
        if not 200 <=resp .status <300 :
            raise YsptpError (f'dictionary HTTP {http_status_text (resp .status ,resp .reason )}')
    def app_start_flow (self ,client :HttpClient ,profile :DeviceProfile ,identity :Identity ,app_channel :str ,version :str )->AppStartResult :
        last =''
        for attempt in range (1 ,3 ):
            if attempt >1 :
                time .sleep (float (attempt -1 ))
            with self .control_request_slot ('app_start'):
                token_time =current_time_ms ()
                xfp ,ts ,_day0 =compute_fingerprint (identity .x_uid ,token_time )
                identity .x_fingerprint =xfp 
                identity .fingerprint_timestamp_ms =ts 
                identity .headers ['X-Fingerprint']=xfp 
                body =build_app_start_body (profile ,identity .x_uid ,app_channel ,version ,current_time_ms ())
                payload =compact_json_bytes (body ,True )
                headers =fresh_headers (identity .headers ,'application/json','application/json',ts )
                headers ['UID']=''
                resp =client .post_bytes (APP_START_URL ,headers ,payload )
                status ,text ,value =response_json (resp )
                if 200 <=status <300 :
                    data =value .get ('data')if isinstance (value ,dict )else None 
                    encrypted =''
                    if isinstance (data ,dict ):
                        key_val =data .get ('key',data )
                        encrypted =key_val if isinstance (key_val ,str )else ''
                    elif isinstance (data ,str ):
                        encrypted =data 
                    if encrypted :
                        session_key =aes_gcm_decrypt_b64 (encrypted ,xfp [:32 ])
                        return AppStartResult (session_key =session_key )
                last =f'app/start HTTP {status }: {text [:300 ]}'
        raise YsptpError (last )
    def cloud_registration_flow (self ,identity :Identity ,cloud_device_id :str )->str :
        body ={'device_name':DEFAULT_DEVICE_NAME ,'device_id':rsa_encrypt_device_id (cloud_device_id )}
        with self .control_request_slot ('cloud_get'):
            resp =self .generic_client .post_json (CLOUD_GET_URL ,fresh_headers (identity .headers ,'application/json','application/json',None ),body )
        _ ,_ ,value =response_json (resp )
        result =parse_result_code (value )
        if result ==RESULT_OK :
            return extract_guid (value )
        if result !=RESULT_NEEDS_REGISTER and result !=RESULT_GET_MISSING_OR_INVALID :
            return ''
        last_result =None 
        guid =''
        for _ in range (2 ):
            with self .control_request_slot ('cloud_register'):
                resp =self .generic_client .post_json (CLOUD_REGISTER_URL ,fresh_headers (identity .headers ,'application/json','application/json',None ),body )
            _ ,_ ,value =response_json (resp )
            last_result =parse_result_code (value )
            guid =extract_guid (value )
            if guid or last_result !=RESULT_REGISTER_RETRY_LATER :
                break 
        if guid :
            return guid 
        if last_result in (RESULT_OK ,RESULT_REGISTERED_ELSEWHERE ,RESULT_GET_MISSING_OR_INVALID ):
            with self .control_request_slot ('cloud_get_after_register'):
                resp =self .generic_client .post_json (CLOUD_GET_URL ,fresh_headers (identity .headers ,'application/json','application/json',None ),body )
            _ ,_ ,value =response_json (resp )
            return extract_guid (value )
        return ''
    def device_info_report_flow (self ,profile :DeviceProfile ,identity :Identity ,app_channel :str ,version :str ,cloud_guid :str )->None :
        with self .control_request_slot ('device_info_report'):
            value =build_report_common_value (profile ,identity .x_uid ,app_channel ,version ,'',current_time_ms ())
            sdk_int =infer_sdk_int (profile )
            system_info =infer_os_version (profile )
            if sdk_int :
                system_info =sdk_int if not system_info else f'{system_info }/{sdk_int }'
            value ['version']=version 
            value ['network_status']='WiFi'
            value ['device_info']=f'{profile .brand }-{profile .model }'
            value ['manufacturer']=profile .manufacturer 
            value ['cpu_info']=''
            value ['chip_info']=profile .hardware 
            value ['ram_info']=''
            value ['memory_info']=''
            value ['system_info']=system_info 
            value ['guid']=cloud_guid 
            body ={'key':'app_device_info','value':value }
            resp =self .generic_client .post_json (REPORT_SINGLE_URL ,fresh_headers (identity .headers ,'application/json','application/json',None ),body )
            if not 200 <=resp .status <300 :
                raise YsptpError (f'device info HTTP {http_status_text (resp .status ,resp .reason )}')
    def heartbeat_flow (self ,profile :DeviceProfile ,identity :Identity ,app_channel :str ,version :str ,cloud_guid :str )->str :
        with self .control_request_slot ('heartbeat'):
            value =build_report_common_value (profile ,identity .x_uid ,app_channel ,version ,'',current_time_ms ())
            value ['network_type']='WiFi'
            value ['guid']=cloud_guid 
            value ['other']=''
            body ={'key':'app_heartbeat','value':value }
            resp =self .generic_client .post_json (REPORT_SINGLE_URL ,fresh_headers (identity .headers ,'application/json','application/json',None ),body )
            status ,_text ,value =response_json (resp )
            if not 200 <=status <300 :
                raise YsptpError (f'heartbeat HTTP {status }')
            code =parse_result_code (value )
            return ''if code is None else str (code )
    def index_flow (self ,client :HttpClient ,identity :Identity ,app_channel :str )->None :
        body ={'channel':app_channel ,'source':'application'}
        with self .control_request_slot ('index'):
            resp =client .post_json (INDEX_URL ,fresh_headers (identity .headers ,'application/json','application/json',None ),body )
            if not 200 <=resp .status <300 :
                raise YsptpError (f'index HTTP {http_status_text (resp .status ,resp .reason )}')
    def warmup_flow (self ,client :HttpClient ,identity :Identity ,version :str )->None :
        appcommon =build_vdn_appcommon (version )
        with self .control_request_slot ('drm_config'):
            resp =client .post_form (DRM_CONFIG_URL ,fresh_headers (identity .headers ,'application/x-www-form-urlencoded',None ,None ),[('appcommon',appcommon )])
            if not 200 <=resp .status <300 :
                raise YsptpError (f'drm config HTTP {http_status_text (resp .status ,resp .reason )}')
        url =f'{VERSION_CONFIG_URL }?appcommon={form_urlencode_value (appcommon )}'
        with self .control_request_slot ('version_config'):
            headers =fresh_headers (identity .headers ,'',None ,None )
            headers .pop ('Content-Type',None )
            resp =client .get (url ,headers )
            if not 200 <=resp .status <300 :
                raise YsptpError (f'version config HTTP {http_status_text (resp .status ,resp .reason )}')
    def resolve_channel_once (self ,sess :AppSession ,channel :str ,live_id :str ,generation :int )->ChannelEntry :
        live01 =self .live_v1_01_flow (sess ,live_id )
        app_secret =self .live_v1_02_flow (sess )
        vdn =self .vdn_getstream_flow (sess .identity ,sess .version ,live01 .live_url ,app_secret )
        now =now_f64 ()
        playback_headers =default_cctv_playback_headers (sess .profile .android_id )
        playback_headers ['APPRANDOMSTR']=vdn .app_random_str 
        playback_headers ['APPSIGN']=vdn .app_sign 
        sess .linked_channels .add (channel )
        display_rate_name =live01 .rate_name or '高码率'
        return ChannelEntry (channel =channel ,live_id =live_id ,final_url =vdn .final_url ,playback_headers =playback_headers ,android_id =sess .profile .android_id ,x_uid =sess .identity .x_uid ,rate =live01 .rate ,rate_name =display_rate_name ,raw_live_host =url_host (live01 .live_url ),final_host =url_host (vdn .final_url ),refreshed_at =now ,expires_at =now +float (self .args .cache_ttl ),generation =generation ,last_refresh_error ='',last_refresh_failed_at =0.0 ,session_generation =sess .generation )
    def live_v1_01_flow (self ,sess :AppSession ,live_id :str )->Live01Result :
        body ={'screenParam':sess .screen_param ,'rate':'','systemType':'ios','model':sess .cast_model ,'id':live_id ,'userId':DEFAULT_LIVE_USER_ID ,'clientSign':'cctvVideo','deviceId':{'serial':'','imei':'','android_id':''}}
        with self .control_request_slot ('live_v1_01'):
            resp =sess .client .post_json (LIVE_V1_01_URL ,fresh_headers (sess .identity .headers ,'application/json','application/json',None ),body )
        status ,text ,value =response_json (resp )
        if not 200 <=status <300 :
            raise YsptpError (f'live/v1/01 HTTP {status }: {text [:300 ]}')
        videos =None 
        if isinstance (value ,dict ):
            data =value .get ('data')
            if isinstance (data ,dict ):
                videos =data .get ('videoList')or data .get ('videos')
        if not isinstance (videos ,list ):
            raise YsptpError ('live/v1/01 missing videos')
        requested =getattr(self.args, 'device_rate', 'auto')
        preferred ='36p' if requested =='auto' else requested
        candidates = [item for item in videos if isinstance(item, dict) and isinstance(item.get('url'), str) and item['url']]
        available = {str(item.get('rate', '')) for item in candidates}
        selected = next((item for item in candidates if item.get('rate') == preferred), None)
        if requested != 'auto' and selected is None:
            raise YsptpError(f'live/v1/01 requested rate {requested} unavailable (available: {", ".join(sorted(available))}); fallback required')
        def declared_size(item):
            try:
                resolution = re.fullmatch(r'(\d+)[xX](\d+)', str(item.get('resolution', '')))
                width = int(item.get('width') or (resolution[1] if resolution else 0))
                height = int(item.get('height') or (resolution[2] if resolution else 0))
                return max(0, height), max(0, width)
            except (ValueError, TypeError, OverflowError):
                return 0, 0
        if requested == 'auto' and candidates and all(declared_size(item)[0] for item in candidates):
            # Use actual API declarations when all offered candidates are comparable.
            selected = max(candidates, key=declared_size)
        video = selected or next((item for item in candidates if item.get('rate') == '10p'), None) or (candidates[0] if candidates else None)
        if video is None :
            raise YsptpError ('live/v1/01 no usable URL')
        raw_url =video .get ('url','')
        if raw_url .startswith ('http://')or raw_url .startswith ('https://'):
            live_url =raw_url 
        else :
            live_url =aes_gcm_decrypt_b64 (raw_url ,sess .session_key )
        rate =video .get ('rate')
        rate_name =video .get ('rateName')
        return Live01Result (live_url =live_url ,rate =rate if isinstance (rate ,str )else '',rate_name =rate_name if isinstance (rate_name ,str )else '')
    def live_v1_02_flow (self ,sess :AppSession )->str :
        with self .control_request_slot ('live_v1_02'):
            encrypted_guid =aes_gcm_encrypt_b64 ('',sess .session_key )
            body ={'guid':encrypted_guid }
            resp =sess .client .post_json (LIVE_V1_02_URL ,fresh_headers (sess .identity .headers ,'application/json','application/json',None ),body )
        status ,text ,value =response_json (resp )
        if not 200 <=status <300 :
            raise YsptpError (f'live/v1/02 HTTP {status }: {text [:300 ]}')
        encrypted =None 
        if isinstance (value ,dict ):
            data =value .get ('data')
            if isinstance (data ,dict ):
                for key in ('appSecret','app_secret'):
                    v =data .get (key )
                    if isinstance (v ,str ):
                        encrypted =v 
                        break 
            if encrypted is None and isinstance (data ,str ):
                encrypted =data 
        if encrypted is None :
            raise YsptpError ('live/v1/02 missing appSecret')
        return aes_gcm_decrypt_b64 (encrypted ,sess .session_key )
    def vdn_getstream_flow (self ,identity :Identity ,version :str ,live_url :str ,app_secret :str )->VdnGetStreamResult :
        with self .control_request_slot ('vdn_getstream'):
            app_sign ,random_str =compute_vdn_code (app_secret ,None )
            headers =fresh_headers (identity .headers ,'application/x-www-form-urlencoded',None ,None )
            headers ['APPID']=AK 
            headers ['APPSIGN']=app_sign 
            headers ['APPRANDOMSTR']=random_str 
            appcommon =build_vdn_appcommon (version )
            resp =self .generic_client .post_form (VDN_GETSTREAM_URL ,headers ,[('appcommon',appcommon ),('url',live_url )])
        status ,text ,value =response_json (resp )
        if not 200 <=status <300 :
            raise YsptpError (f'VDN HTTP {status }: {text [:300 ]}')
        if isinstance (value ,dict ):
            succeed =value .get ('succeed')
            succeed_str =succeed .strip ('"')if isinstance (succeed ,str )else json .dumps (succeed ,separators =(',',':'),ensure_ascii =False ).strip ('"')if succeed is not None else ''
            if succeed_str =='1':
                url =value .get ('url')
                if isinstance (url ,str ):
                    return VdnGetStreamResult (final_url =url ,app_sign =app_sign ,app_random_str =random_str )
        raise YsptpError (f'VDN did not return final URL: {text [:400 ]}')
    def send_heartbeat(self):
        if not self.control_lock.acquire(blocking=False):
            self._stats['heartbeat_skipped_busy'] +=1
            with self.state_lock:
                sessions =list(self.state.sessions.values())
            guard =max(float(self.args.heartbeat_ttl_guard), float(self.args.heartbeat_interval) *2.0)
            if not any(self.app_session_fresh(s) and now_f64() -s.last_heartbeat_at <=guard for s in sessions):
                set_resolver_ready(False)
            return
        try:
            with self.state_lock:
                slots =list(self.state.sessions) or [0]
            healthy =False
            for slot in slots:
                if self.stop_event.is_set():
                    break
                try:
                    with self.state_lock:
                        session =self.state.sessions.get(slot)
                    if session is None or not self.app_session_fresh(session) or (self.app_session_ttl_remaining(session) is not None and self.app_session_ttl_remaining(session) <=300.0):
                        session =self.ensure_slot_session(slot)
                        healthy =True
                        continue
                    self.evict_idle_links(session, LINK_IDLE_TIMEOUT)
                    wait =max(0.0, float(self.args.refresh_interval) -(time.monotonic() -self._last_business_mono))
                    if self.stop_event.wait(wait):
                        break
                    code =self.heartbeat_flow(session.profile, session.identity, 'dangbei', session.version, session.cloud_guid)
                    # Some successful telemetry replies omit a result code.
                    if code not in ('', '0', '200', 0, 200, None):
                        raise YsptpError(f'heartbeat result {code}')
                    with self.state_lock:
                        session.last_heartbeat_at =now_f64()
                        session.heartbeat_count +=1
                        session.last_heartbeat_result =code
                        session.last_heartbeat_error =''
                    self._stats['heartbeat_success'] +=1
                    healthy =True
                except Exception as error:
                    text =str(error)
                    self._stats['heartbeat_failed'] +=1
                    with self.state_lock:
                        session =self.state.sessions.get(slot)
                        if session is not None:
                            session.last_heartbeat_error =text
                        self.state.last_error =f'heartbeat failed on slot {slot}: {text}'
                        self.state.last_error_at =now_f64()
                        if is_session_invalidating_error(text):
                            if self.state.sessions.pop(slot, None) is not None:
                                self._session_results.pop(slot, None)
                    log(f'[心跳] slot {slot}: {text}', min_interval=30.0)
                finally:
                    self._last_business_mono =time.monotonic()
                    with self.state_lock:
                        self.state.last_business_end_at =now_f64()
            set_resolver_ready(healthy and not self.stop_event.is_set())
        finally:
            self.control_lock.release()
    def proxy_playlist_ts_urls(self, playlist, proxy_origin, proxy_prefix=None, entry=None):
        origin =(proxy_prefix or proxy_origin).rstrip('/')
        headers =cctv_playback_headers_for_entry(entry) if entry is not None else None
        channel =entry.channel if entry is not None else ''
        generation =entry.generation if entry is not None else 0
        def proxy(url):
            if urllib.parse.urlsplit(url).scheme.lower() not in ('http', 'https'):
                return url
            token =register_resource(url, headers=headers, channel=channel, generation=generation)
            return f'{origin}/proxy?resource={urllib.parse.quote(token, safe="")}'
        out =[]
        for line in _rs_lines(playlist):
            stripped =line.strip()
            if stripped.startswith('#'):
                # Attribute names end in URI (including SERVER-URI), but quoted
                # commas inside values must not split the attribute list.
                line =re.sub(r'(?<![A-Za-z0-9_-])([A-Z0-9-]*URI)="([^"]*)"', lambda match: f'{match.group(1)}="{proxy(match.group(2))}"', line)
            elif stripped:
                line =proxy(stripped)
            out.append(line)
        return ''.join(line +'\n' for line in out)
    def _playlist_source_key(self, entry):
        return (entry.channel, entry.generation, entry.final_url, entry.android_id,
                entry.session_generation, tuple(sorted((str(key), str(value)) for key, value in cctv_playback_headers_for_entry(entry).items())), self._playlist_channel_epoch.get(entry.channel, 0), self._session_epoch)
    def _playlist_stale_seconds(self, text):
        duration =re.search(r'^#EXT-X-TARGETDURATION:(\d+(?:\.\d+)?)', text, re.MULTILINE)
        target =float(duration.group(1)) if duration else 6.0
        return min(20.0, max(3.0, target *3.0))
    def _run_playlist_fetch(self, entry, source_key, flight):
        try:
            if self.stop_event.is_set():
                raise YsptpError('resolver is shutting down')
            self._stats['playlist_upstream'] +=1
            status, content_type, text, effective_url =fetch_playlist_http1(entry.final_url, cctv_playback_headers_for_entry(entry))
            if not 200 <=status <300:
                raise YsptpError(f'upstream m3u8 HTTP {status}: {text[:300]}')
            if '#EXTM3U' not in text.lstrip()[:32]:
                raise YsptpError('upstream m3u8 invalid playlist')
            body =rewrite_playlist_urls(text, effective_url)
            now =time.monotonic()
            ttl =max(0.0, float(self.args.playlist_cache_ttl))
            raw =RawPlaylist(source_key, body, content_type, now, now +ttl, now +self._playlist_stale_seconds(body))
            with self.state_lock:
                current =self.state.cache.get(entry.channel)
                if source_key[-1] !=self._session_epoch or (current is not None and self._playlist_source_key(current) !=source_key):
                    raise YsptpError('channel source changed during playlist refresh')
                if '#EXTINF:' in body and '#EXT-X-ENDLIST' not in body:
                    media =[]
                    auth_parameters ={'sig', 'sign', 'signature', 'token', 'auth', 'auth_key', 'authkey', 'wssecret', 'wstime', 'txsecret', 'txtime', 'expires', 'expire', 'vkey'}
                    for line in body.splitlines():
                        if line.strip() and not line.lstrip().startswith('#'):
                            parsed =urllib.parse.urlsplit(line.strip())
                            query =tuple((key, value) for key, value in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True) if key.lower() not in auth_parameters)
                            media.append((parsed.path, query))
                    sequence =re.search(r'^#EXT-X-MEDIA-SEQUENCE:(\d+)', body, re.MULTILINE)
                    dates =re.findall(r'^#EXT-X-PROGRAM-DATE-TIME:(.+)', body, re.MULTILINE)
                    signature =(sequence.group(1) if sequence else '', tuple(media), dates[-1] if dates else '')
                    progress =self._playlist_progress.get(entry.channel)
                    if progress is None or progress['source_key'] !=source_key or progress['signature'] !=signature:
                        progress ={'source_key': source_key, 'signature': signature, 'progress_at': now}
                        self._playlist_progress[entry.channel] =progress
                    progress['fetched_at'] =now
                    duration =re.search(r'^#EXT-X-TARGETDURATION:(\d+(?:\.\d+)?)', body, re.MULTILINE)
                    threshold =max(18.0, (float(duration.group(1)) if duration else 6.0) *4.0)
                    progress['stalled'] =now -progress['progress_at'] >threshold
                    if progress['stalled']:
                        old =self._playlist_raw.get(entry.channel)
                        if old is not None and old.source_key ==source_key:
                            old.expires_at =now
                            old.stale_until =now
                        raise YsptpError('upstream m3u8 media stalled')
                if ttl >0.0:
                    self._playlist_raw[entry.channel] =raw
                    wall =now_f64()
                    self.state.playlist_cache[entry.channel] =PlaylistCacheEntry(body=body, content_type=content_type, cached_at=wall, expires_at=wall +ttl, final_url=entry.final_url, android_id=entry.android_id)
                self._playlist_failures.pop(source_key, None)
            self.clear_recoverable_error_count()
            flight.set_result(raw)
        except Exception as error:
            if not isinstance(error, YsptpError):
                error =YsptpError(f'upstream m3u8 failed: {error}')
            self._stats['playlist_failed'] +=1
            with self.state_lock:
                self._playlist_failures[source_key] =(time.monotonic() +2.0, error)
            flight.set_exception(error)
        finally:
            with self.state_lock:
                if self._playlist_flights.get(source_key) is flight:
                    self._playlist_flights.pop(source_key, None)
    def playback_headers_for_ts_url (self ,real_url :str )->dict :
        try :
            parsed =urllib .parse .urlsplit (real_url )
        except ValueError as e :
            raise YsptpError (f'invalid proxy ts URL: {e }')
        host =parsed .hostname 
        if not host :
            raise YsptpError ('proxy ts URL missing host')
        ts_path =parsed .path 
        same_host_headers =None 
        with self .state_lock :
            for entry in self .state .cache .values ():
                if entry_missing_signed_playback_headers (entry ):
                    continue 
                entry_host =entry .final_host or url_host (entry .final_url )
                if entry_host .lower ()!=host .lower ():
                    continue 
                headers =cctv_playback_headers_for_entry (entry )
                if ts_path_matches_final_url (ts_path ,entry .final_url ):
                    return headers 
                if same_host_headers is None :
                    same_host_headers =headers 
        if same_host_headers is not None :
            return same_host_headers 
        if live_playback_host_needs_signed_headers (host ):
            raise YsptpError (f'missing cached signed playback headers for {host }')
        uid =current_cctv_android_id (self )
        return default_cctv_playback_headers (uid )
    def fetch_playlist(self, entry, proxy_origin, proxy_prefix=None):
        key =self._playlist_source_key(entry)
        now =time.monotonic()
        with self.state_lock:
            cached =self._playlist_raw.get(entry.channel)
            if cached is not None and cached.source_key !=key:
                cached =None
            current =self.state.cache.get(entry.channel)
            if current is not None and self._playlist_source_key(current) !=key:
                raise YsptpError('channel source changed before playlist request')
            if cached is not None and now <cached.expires_at:
                self._stats['playlist_cache_hit'] +=1
                raw =cached
                probe =PlaylistCacheProbe(state='hit:raw', age_ms=int((now -cached.cached_at) *1000))
                flight =None
                leader =False
            else:
                failure =self._playlist_failures.get(key)
                stale =cached is not None and now <cached.stale_until
                if failure is not None and now <failure[0]:
                    if not stale:
                        raise failure[1]
                    raw =cached
                    flight =None
                    leader =False
                    probe =PlaylistCacheProbe(state='stale:error_backoff', age_ms=int((now -cached.cached_at) *1000))
                else:
                    flight =self._playlist_flights.get(key)
                    leader =flight is None
                    if leader:
                        # Bound both running tasks and the executor's queue.
                        if len(self._playlist_flights) >=64:
                            if not stale:
                                raise YsptpError('playlist refresh capacity exhausted')
                            flight =None
                            leader =False
                        else:
                            flight =Future()
                            self._playlist_flights[key] =flight
                    else:
                        self._stats['playlist_shared'] +=1
                    raw =cached if stale else None
                    probe =PlaylistCacheProbe(state='stale:refreshing' if stale else 'miss:raw', age_ms=int((now -cached.cached_at) *1000) if cached else None)
        if flight is not None:
            if leader:
                if raw is not None:
                    try:
                        self._playlist_pool.submit(self._run_playlist_fetch, entry, key, flight)
                    except RuntimeError as error:
                        with self.state_lock:
                            self._playlist_flights.pop(key, None)
                        flight.set_exception(YsptpError(f'playlist worker unavailable: {error}'))
                else:
                    self._run_playlist_fetch(entry, key, flight)
            if raw is None:
                raw =flight.result()
        return self.proxy_playlist_ts_urls(raw.body, proxy_origin, proxy_prefix, entry=entry), raw.content_type, probe
    def fetch_channel_playlist(self, channel, host_header, proto='http'):
        with self.state_lock:
            self.state.channel_last_access[channel] =now_f64()
        if self.zap_debounced(channel):
            log(f'[{channel}] 换台防抖: 先出 1080p, 停留后自动升码率', min_interval=10.0)
            return None
        host =host_header.strip() if host_header else f'localhost:{server_port}'
        scheme =proto if proto in ('http', 'https') else 'http'
        origin =f'{scheme}://{host}'
        entry =self.ensure_channel(channel)
        for attempt in range(2):
            try:
                body, _content_type, _probe =self.fetch_playlist(entry, origin)
                return body
            except YsptpError as error:
                text =str(error)
                # Only explicit authorization/expiry or an already replaced
                # generation justifies another expensive protocol resolution.
                expired =any(code in text for code in ('HTTP 403', 'HTTP 404', 'HTTP 401', 'channel source changed'))
                if expired and attempt ==0:
                    log(f'[{channel}] 高码率播放地址已过期，正在重取新地址…', min_interval=4.0)
                    entry =self.ensure_channel(channel, force=True, expected_generation=entry.generation)
                    continue
                raise
    def fetch_channel_playlist_bounded(self, channel, host_header, proto='http', timeout=None):
        from concurrent.futures import TimeoutError, CancelledError
        key =(channel, host_header, proto)
        with self.state_lock:
            flight =self._foreground_flights.get(key)
            if flight is None:
                if self.stop_event.is_set() or len(self._foreground_flights) >=64:
                    self._stats['foreground_rejected'] +=1
                    return None
                try:
                    flight =self._foreground_pool.submit(self.fetch_channel_playlist, channel, host_header, proto)
                except RuntimeError:
                    return None
                self._foreground_flights[key] =flight
                leader =True
            else:
                self._stats['foreground_shared'] +=1
                leader =False
        if leader:
            def finished(completed):
                with self.state_lock:
                    if self._foreground_flights.get(key) is completed:
                        self._foreground_flights.pop(key, None)
            flight.add_done_callback(finished)
        wait =float(getattr(self.args, 'foreground_wait', 2.0)) if timeout is None else float(timeout)
        try:
            return flight.result(timeout=max(0.0, wait))
        except TimeoutError:
            self._stats['foreground_timeout'] +=1
            return None
        except CancelledError:
            return None
    def status_json (self )->dict :
        with self .state_lock :
            state_snapshot ={'refreshing_channel':self .state .refreshing_channel ,'last_business_end_at':self .state .last_business_end_at ,'last_error':self .state .last_error ,'identity_reset_error_count':self .state .identity_reset_error_count ,'identity_reset_count':self .state .identity_reset_count ,'last_identity_reset_at':self .state .last_identity_reset_at ,'last_identity_reset_reason':self .state .last_identity_reset_reason ,'ad_display':self .state .ad_display ,'generation':self .state .generation ,'session_generation':self .state .session_generation ,'cache':dict (self .state .cache ),'playlist_cache':dict (self .state .playlist_cache ),'background_refreshing':dict (self .state .background_refreshing ),'app_session':self .state .app_session }
        now =now_f64 ()
        if os .path .exists (self .args .device_json ):
            loaded ,existed =load_device_state (self .args .device_json )
            device_state ={'exists':existed ,'android_id':loaded .profile .android_id ,'mac':loaded .profile .mac ,'brand':loaded .profile .brand ,'model':loaded .profile .model ,'screen_param':loaded .screen_param ,'x_uid':loaded .x_uid ,'cloud_guid_present':bool (loaded .cloud_guid ),'registered_at':loaded .registered_at ,'updated_at':loaded .updated_at }
        else :
            device_state ={'exists':False }
        cache ={}
        for k ,v in state_snapshot ['cache'].items ():
            cache [k ]={'live_id':v .live_id ,'fresh':v .fresh (now ),'age_seconds':rust_round ((now -v .refreshed_at )*1000.0 )/1000.0 ,'expires_in_seconds':rust_round ((v .expires_at -now )*1000.0 )/1000.0 ,'rate':v .rate ,'rate_name':v .rate_name ,'final_host':v .final_host ,'generation':v .generation ,'session_generation':v .session_generation ,'last_refresh_error':v .last_refresh_error }
        playlist_cache ={}
        for k ,v in state_snapshot ['playlist_cache'].items ():
            playlist_cache [k ]={'fresh':now <v .expires_at ,'age_seconds':rust_round ((now -v .cached_at )*1000.0 )/1000.0 ,'expires_in_seconds':rust_round ((v .expires_at -now )*1000.0 )/1000.0 ,'bytes':len (v .body .encode ('utf-8')),'content_type':v .content_type ,'proxy_origin':v .proxy_origin ,'proxy_prefix':v .proxy_prefix }
        sess =state_snapshot ['app_session']
        if sess is not None :
            expires_in =float (self .args .session_ttl )-(now -sess .created_at )if float (self .args .session_ttl )>0.0 else None 
            app_session ={'active':True ,'generation':sess .generation ,'age_seconds':rust_round ((now -sess .created_at )*1000.0 )/1000.0 ,'fresh':self .app_session_fresh (sess ),'expires_in_seconds':expires_in ,'android_id':sess .profile .android_id ,'mac':sess .profile .mac ,'brand':sess .profile .brand ,'model':sess .profile .model ,'screen_param':sess .screen_param ,'cast_model':sess .cast_model ,'x_uid':sess .identity .x_uid ,'cloud_guid_present':bool (sess .cloud_guid ),'fingerprint_timestamp_ms':sess .identity .fingerprint_timestamp_ms ,'heartbeat_count':sess .heartbeat_count ,'last_heartbeat_age_seconds':rust_round ((now -sess .last_heartbeat_at )*1000.0 )/1000.0 ,'last_heartbeat_result':sess .last_heartbeat_result ,'last_heartbeat_error':sess .last_heartbeat_error }
        else :
            app_session ={'active':False ,'generation':state_snapshot ['session_generation']}
        rq =self .refresh_queue 
        with rq .cond :
            refresh_queue ={'limit':int (self .args .background_refresh_queue_limit ),'queued_depth':len (rq .queued ),'queued_channels':list (rq .queued ),'running_channel':rq .running_channel ,'running_age_seconds':rust_round ((now -rq .running_started_at )*1000.0 )/1000.0 if rq .running_started_at >0.0 else None ,'enqueued_total':rq .enqueued_total ,'dropped_total':rq .dropped_total ,'completed_total':rq .completed_total ,'failed_total':rq .failed_total ,'last_enqueued_age_seconds':rust_round ((now -rq .last_enqueued_at )*1000.0 )/1000.0 if rq .last_enqueued_at >0.0 else None ,'last_finished_age_seconds':rust_round ((now -rq .last_finished_at )*1000.0 )/1000.0 if rq .last_finished_at >0.0 else None ,'last_dropped_age_seconds':rust_round ((now -rq .last_dropped_at )*1000.0 )/1000.0 if rq .last_dropped_at >0.0 else None ,'last_drop_reason':rq .last_drop_reason }
        hq =self .http_queue 
        with hq .cond :
            http_queue ={'workers':max (1 ,int (self .args .http_workers )),'limit':int (self .args .http_queue_limit ),'queued_depth':len (hq .queued ),'active_workers':hq .active_workers ,'enqueued_total':hq .enqueued_total ,'rejected_total':hq .rejected_total ,'completed_total':hq .completed_total ,'panicked_total':hq .panicked_total ,'last_enqueued_age_seconds':rust_round ((now -hq .last_enqueued_at )*1000.0 )/1000.0 if hq .last_enqueued_at >0.0 else None ,'last_completed_age_seconds':rust_round ((now -hq .last_completed_at )*1000.0 )/1000.0 if hq .last_completed_at >0.0 else None ,'last_rejected_age_seconds':rust_round ((now -hq .last_rejected_at )*1000.0 )/1000.0 if hq .last_rejected_at >0.0 else None }
        result ={'channels':[c for c ,_ in channels ()],'cache_ttl_seconds':float (self .args .cache_ttl ),'stale_while_refresh_ttl_seconds':float (self .args .stale_while_refresh_ttl ),'refresh_error_cooldown_seconds':float (self .args .refresh_error_cooldown ),'playlist_cache_ttl_seconds':float (self .args .playlist_cache_ttl ),'background_refresh_queue_limit':int (self .args .background_refresh_queue_limit ),'http_workers':max (1 ,int (self .args .http_workers )),'http_queue_limit':int (self .args .http_queue_limit ),'identity_reset_error_threshold':int (self .args .identity_reset_error_threshold ),'identity_reset_cooldown_seconds':float (self .args .identity_reset_cooldown ),'refresh_interval_seconds':float (self .args .refresh_interval ),'control_step_jitter_min_ms':int (self .args .control_step_jitter_min_ms ),'control_step_jitter_max_ms':int (self .args .control_step_jitter_max_ms ),'heartbeat_interval_seconds':float (self .args .heartbeat_interval ),'heartbeat_ttl_guard_seconds':float (self .args .heartbeat_ttl_guard ),'session_ttl_seconds':float (self .args .session_ttl ),'meta_json':self .args .meta_json ,'device_json':self .args .device_json ,'device_state':device_state ,'refreshing_channel':state_snapshot ['refreshing_channel'],'background_refreshing':list (state_snapshot ['background_refreshing'].keys ()),'background_refresh_queue':refresh_queue ,'http_queue':http_queue ,'generation':state_snapshot ['generation'],'app_session':app_session ,'last_business_end_at':state_snapshot ['last_business_end_at'],'last_error':state_snapshot ['last_error'],'identity_reset_error_count':state_snapshot ['identity_reset_error_count'],'identity_reset_count':state_snapshot ['identity_reset_count'],'last_identity_reset_at':state_snapshot ['last_identity_reset_at'],'last_identity_reset_reason':state_snapshot ['last_identity_reset_reason'],'ad_display':state_snapshot ['ad_display'],'device_profile_pool_size':len (DEVICE_PROFILE_POOL ),'cache':cache ,'playlist_cache':playlist_cache }
        with self.state_lock:
            result['resolver_runtime'] ={
                'channel_inflight': len(self._channel_flights),
                'playlist_inflight': len(self._playlist_flights),
                'foreground_inflight': len(self._foreground_flights),
                'stats': dict(self._stats),
                'worker_error': self._worker_error,
                'stopped': self.stop_event.is_set(),
                'workers': {worker.name: worker.is_alive() for worker in self._threads},
                'persistence_errors': persistence_status(),
                'media_progress': {
                    channel: {
                        'progress_age_seconds': round(max(0.0, time.monotonic() -value['progress_at']), 3),
                        'fetch_age_seconds': round(max(0.0, time.monotonic() -value['fetched_at']), 3),
                        'stalled': value.get('stalled', False),
                    } for channel, value in self._playlist_progress.items()
                },
            }
        return result
    def write_meta(self):
        # Take the snapshot after acquiring this lock, so a delayed old writer
        # cannot replace a newer snapshot from the same process.
        with self._meta_lock:
            try:
                payload =self.status_json()
                with self.state_lock:
                    payload['cache_detail'] ={key: dataclasses.asdict(value) for key, value in self.state.cache.items()}
                payload['session_detail_note'] ='Session secrets are intentionally not persisted for reuse; Python process keeps live session in memory only.'
                payload['device_state_note'] ='TV device identity is persisted after cloud registration succeeds.'
                atomic_json_write(self.args.meta_json, payload)
            except Exception as error:
                self._worker_error =f'metadata persistence: {error}'
                log(f'[持久化] 无法保存元数据 {self.args.meta_json}: {error}', min_interval=30.0)
def load_cache (path :str )->dict :
    try :
        with open (path ,encoding ='utf-8')as f :
            value =json .load (f )
    except (OSError ,ValueError ):
        return {}
    detail =value .get ('cache_detail')if isinstance (value ,dict )else None 
    if not isinstance (detail ,dict ):
        return {}
    try :
        return {k :ChannelEntry .from_dict (v )for k ,v in detail .items ()if isinstance (v ,dict )}
    except (ValueError ,TypeError ):
        return {}
def _playback_request_headers (playback_headers :dict ,extra :dict |None =None )->dict :
    headers ={}
    for key in ('UID','APPID','APPRANDOMSTR','Referer','User-Agent','APPSIGN'):
        value =playback_headers .get (key )
        if value is not None and str (value ).strip ():
            headers [key ]=header_value_clean (str (value ))
    headers ['Accept']='*/*'
    headers ['Accept-Encoding']='identity'
    headers ['Connection']='close'
    if extra :
        headers .update (extra )
    return headers 
def fetch_playlist_http1(final_url: str, playback_headers: dict):
    status, headers, body, effective_url = fetch_bytes(
        final_url, _playback_request_headers(playback_headers),
        policy=media_proxy.policy, timeout=20, max_bytes=2 * 1024 * 1024)
    return status, headers.get('content-type', 'application/vnd.apple.mpegurl'), body.decode('utf-8', errors='replace'), effective_url
def query_param (url :str ,name :str ):
    if '?'not in url :
        return None 
    _ ,query =url .split ('?',1 )
    for pair in query .split ('&'):
        key ,_ ,value =pair .partition ('=')
        if key ==name :
            return value 
    return None 
def proxy_ts_token (url :str ):
    if '?'not in url :
        return None 
    _ ,query =url .split ('?',1 )
    if query .startswith ('='):
        token =query [1 :]
        return token or None 
    token =query_param (url ,'ts')
    if token :
        return token 
    token =query_param (url ,'url')
    if token :
        return token 
    if query and '='not in query :
        return query 
    return None 
def decode_proxy_ts_url (token :str )->str :
    padded =token +'='*(-len (token )%4 )
    try :
        raw =base64 .urlsafe_b64decode (padded .encode ('ascii'))
    except (binascii .Error ,ValueError )as e :
        raise YsptpError (f'invalid proxy ts token: {e }')
    try :
        value =raw .decode ('utf-8')
    except UnicodeDecodeError as e :
        raise YsptpError (f'proxy ts token is not UTF-8: {e }')
    try :
        parsed =urllib .parse .urlsplit (value )
    except ValueError as e :
        raise YsptpError (f'proxy ts token is not a URL: {e }')
    if parsed .scheme not in ('http','https'):
        raise YsptpError (f'proxy ts currently requires http or https URL, got {parsed .scheme }')
    if not parsed .path .lower ().endswith ('.ts'):
        raise YsptpError ('proxy ts URL is not a .ts segment')
    return value 
def current_cctv_android_id (resolver :Resolver )->str :
    if os .path .exists (resolver .args .device_json ):
        loaded ,_ =load_device_state (resolver .args .device_json )
        if loaded .profile .android_id :
            return loaded .profile .android_id 
    with resolver .state_lock :
        sess =resolver .state .app_session 
        if sess is not None and sess .profile .android_id :
            return sess .profile .android_id 
        for entry in resolver .state .cache .values ():
            if entry .android_id :
                return entry .android_id 
    raise YsptpError ('missing cctv android_id')
def resolve_paths (args :argparse .Namespace )->None :
    d =binary_dir ()
    if not args .meta_json .strip ():
        args .meta_json =os .path .join (d ,'proxy-cache-state-rs.json')
    if not args .device_json .strip ():
        args .device_json =os .path .join (d ,'device-state-rs.json')
class W :
    def __init__ (self ):
        self .b =bytearray ()
    def head (self ,typ ,tag ):
        if tag <15 :
            self .b .append ((tag &15 )<<4 |typ &15 )
        else :
            self .b .append (240 |typ &15 )
            self .b .append (tag )
    def byte (self ,v ,tag ):
        v =int (v )
        if v ==0 :
            self .head (12 ,tag )
        else :
            self .head (0 ,tag )
            self .b +=struct .pack ('>b',v )
    def short (self ,v ,tag ):
        v =int (v )
        if -128 <=v <=127 :
            self .byte (v ,tag )
        else :
            self .head (1 ,tag )
            self .b +=struct .pack ('>h',v )
    def int (self ,v ,tag ):
        v =int (v )
        if -32768 <=v <=32767 :
            self .short (v ,tag )
        else :
            self .head (2 ,tag )
            self .b +=struct .pack ('>i',v )
    def long (self ,v ,tag ):
        v =int (v )
        if -2147483648 <=v <=2147483647 :
            self .int (v ,tag )
        else :
            self .head (3 ,tag )
            self .b +=struct .pack ('>q',v )
    def float (self ,v ,tag ):
        self .head (4 ,tag )
        self .b +=struct .pack ('>f',float (v ))
    def double (self ,v ,tag ):
        self .head (5 ,tag )
        self .b +=struct .pack ('>d',float (v ))
    def string (self ,s ,tag ):
        if s is None :
            return 
        data =str (s ).encode ('utf-8')
        if len (data )>255 :
            self .head (7 ,tag )
            self .b +=struct .pack ('>i',len (data ))
            self .b +=data 
        else :
            self .head (6 ,tag )
            self .b .append (len (data ))
            self .b +=data 
    def bytes (self ,data ,tag ):
        data =bytes (data )
        self .head (13 ,tag )
        self .head (0 ,0 )
        self .int (len (data ),0 )
        self .b +=data 
    def struct (self ,fn ,tag ):
        self .head (10 ,tag )
        fn (self )
        self .head (11 ,0 )
    def list (self ,items ,tag ,wf ):
        self .head (9 ,tag )
        self .int (len (items ),0 )
        if wf is not None :
            for item in items :
                wf (self ,item )
    def out (self ):
        return bytes (self .b )
class R :
    def __init__ (self ,data ):
        self .d =memoryview (data )
        self .p =0 
    def rem (self ):
        return len (self .d )-self .p 
    def get (self ,n ):
        if self .p +n >len (self .d ):
            raise EOFError 
        b =self .d [self .p :self .p +n ].tobytes ()
        self .p +=n 
        return b 
    def u8 (self ):
        return self .get (1 )[0 ]
    def head (self ):
        b =self .u8 ()
        typ =b &15 
        tag =(b &240 )>>4 
        if tag ==15 :
            tag =self .u8 ()
        return (typ ,tag )
    def value (self ,typ ):
        if typ ==0 :
            return struct .unpack ('>b',self .get (1 ))[0 ]
        if typ ==1 :
            return struct .unpack ('>h',self .get (2 ))[0 ]
        if typ ==2 :
            return struct .unpack ('>i',self .get (4 ))[0 ]
        if typ ==3 :
            return struct .unpack ('>q',self .get (8 ))[0 ]
        if typ ==4 :
            return struct .unpack ('>f',self .get (4 ))[0 ]
        if typ ==5 :
            return struct .unpack ('>d',self .get (8 ))[0 ]
        if typ ==6 :
            n =self .u8 ()
            return self .get (n ).decode ('utf-8','replace')
        if typ ==7 :
            n =struct .unpack ('>i',self .get (4 ))[0 ]
            return self .get (n ).decode ('utf-8','replace')
        if typ ==8 :
            n =self ._int ()
            return {self ._fv ():self ._fv ()for _ in range (n )}
        if typ ==9 :
            n =self ._int ()
            return [self ._fv ()for _ in range (n )]
        if typ ==10 :
            return self .struct ()
        if typ ==11 :
            return None 
        if typ ==12 :
            return 0 
        if typ ==13 :
            t ,_ =self .head ()
            n =self ._int ()
            return self .get (n )
        raise ValueError ('type %d'%typ )
    def _fv (self ):
        t ,_ =self .head ()
        return self .value (t )
    def _int (self ):
        t ,_ =self .head ()
        return int (self .value (t ))
    def struct (self ):
        m ={}
        while self .rem ()>0 :
            t ,tag =self .head ()
            if t ==11 :
                break 
            m [tag ]=self .value (t )
        return m 
VER_NAME ,VER_CODE =('3.2.7.26212','302070')
APP_ID ,QMF_APP_ID ,QMF_PLATFORM ,BIZ_ID =('1200013',10012 ,1 ,0 )
CHAN_ID ='10070'
GUID =''.join ((random .choice ('0123456789abcdef')for _ in range (32 )))
def _qua (w ):
    w .string (VER_NAME ,0 )
    w .string (VER_CODE ,1 )
    w .int (1080 ,2 )
    w .int (2400 ,3 )
    w .int (3 ,4 )
    w .string ('12',5 )
    w .int (1 ,6 )
    w .int (1 ,7 )
    w .int (420 ,8 )
    w .string (CHAN_ID ,9 )
    for i in range (10 ,15 ):
        w .string ('',i )
    w .struct (lambda ww :(ww .int (0 ,0 ),ww .byte (0 ,1 ),ww .string ('',2 )),15 )
    w .string ('',16 )
    w .string ('',17 )
    w .string ('',18 )
    w .struct (lambda ww :(ww .int (0 ,0 ),ww .float (0 ,1 ),ww .float (0 ,2 ),ww .double (0 ,3 )),19 )
    w .string (GUID [:16 ],20 )
    w .string ('Pixel 6',21 )
    w .int (1 ,22 )
    for i in range (23 ,27 ):
        w .int (0 ,i )
    w .string ('',27 )
    w .string ('',28 )
    w .string (GUID ,29 )
def _head (w ,cmd ,reqid ):
    w .int (reqid ,0 )
    w .int (cmd ,1 )
    w .struct (lambda ww :_qua (ww ),2 )
    w .string (APP_ID ,3 )
    w .string (GUID ,4 )
    w .list ([],5 ,None )
    w .struct (lambda ww :None ,6 )
    w .list ([],7 ,None )
    w .int (0 ,8 )
    w .int (0 ,9 )
    w .int (0 ,10 )
def _wrap (cmd ,body ,reqid ):
    w =W ()
    w .struct (lambda ww :_head (ww ,cmd ,reqid ),0 )
    w .bytes (body ,1 )
    reqcmd =w .out ()
    inner =bytearray ([38 ])+struct .pack ('>i',len (reqcmd )+17 )+bytes ([1 ])+b'\x00'*10 +reqcmd +bytes ([40 ])
    comp =gzip .compress (bytes (inner ))
    out =bytearray ([19 ])+struct .pack ('>i',0 )+struct .pack ('>H',2 )+struct .pack ('>H',65281 )
    out +=struct .pack ('>H',cmd )+struct .pack ('>H',0 )+struct .pack ('>q',reqid )
    out +=struct .pack ('>i',531 )+struct .pack ('>i',QMF_APP_ID )+struct .pack ('>q',BIZ_ID )
    g =GUID .encode ()[:32 ]
    out +=g +b'\x00'*(32 -len (g ))
    out +=struct .pack ('>b',QMF_PLATFORM )+struct .pack ('>i',int (VER_CODE ))+b'\x00'*6 
    out +=bytes ([0 ])+struct .pack ('>H',0 )+struct .pack ('>H',0 )
    out +=struct .pack ('>i',len (inner ))+comp +bytes ([3 ])
    struct .pack_into ('>i',out ,1 ,len (out ))
    return bytes (out )
def _unwrap (data ):
    if data [:1 ]!=b'\x13'or len (data )<90 :
        return None 
    flags =struct .unpack ('>i',data [21 :25 ])[0 ]
    payload =data [89 :-1 ]
    if flags &2 :
        payload =gzip .decompress (payload )
    if payload [:1 ]!=b'&'or payload [-1 :]!=b'(':
        return None 
    rc =R (payload [16 :-1 ]).struct ()
    return rc .get (1 )or b''
class DeadHostError (RuntimeError ):
    pass 
def jce_timeshift_url (pid ,sid ,start ,end ,stream ='fhd'):
    if stream in ('auto', 'best'):
        stream = 'fhd'  # Automatic selection is a playlist policy, not an API stream ID.
    w =W ()
    w .string (pid ,0 )
    w .string (sid ,1 )
    w .long (start ,2 )
    w .long (end ,3 )
    w .string (stream ,4 )
    body =w .out ()
    CMD =25312 
    reqid =int (time .time ()*1000 )&2147483647 
    packet =_wrap (CMD ,body ,reqid )
    req =urllib .request .Request ('https://jacc.ysp.cctv.cn',data =packet ,method ='POST')
    req .add_header ('Content-Type','application/octet-stream')
    with urllib .request .urlopen (req ,timeout =15 )as resp :
        raw =resp .read ()
    resp_body =_unwrap (raw )
    if not resp_body :
        raise RuntimeError ('bad response')
    m =R (resp_body ).struct ()
    err =m .get (0 ,0 )
    if err !=0 :
        raise RuntimeError (m .get (1 ,'errCode=%s'%err ))
    url =m .get (2 ,'')
    if not url :
        raise RuntimeError ('empty m3u8')
    if 'liverecord.video.cloud.cctv.com'in url :
        raise DeadHostError ('dead cdn host')
    return url 
_CK_PLATFORM =4330403 
_CK_APPVER ='V8.22.1035.3031'
_CK_TEA =bytes .fromhex ('59b2f7cf725ef43c34fdd7c123411ed3')
_CK_GTEA =bytes .fromhex ('110DBEC10C23E7D2E56A1CAD6914EF1B')
_CK_XOR =bytes ([132 ,46 ,237 ,8 ,240 ,102 ,230 ,234 ,72 ,180 ,202 ,169 ,145 ,237 ,111 ,243 ])
_CK_GXOR =bytes ([179 ,201 ,83 ,160 ,105 ,19 ,173 ,77 ])
def _u32 (v ):
    return v &4294967295 
def _tea_blk (blk ,key ):
    y ,z =struct .unpack ('>2I',blk )
    k =struct .unpack ('>4I',key )
    s =0 
    for _ in range (16 ):
        s =_u32 (s +2654435769 )
        y =_u32 (y +_u32 (_u32 (_u32 (z <<4 )+k [0 ])^_u32 (z +s )^_u32 ((z >>5 )+k [1 ])))
        z =_u32 (z +_u32 (_u32 (_u32 (y <<4 )+k [2 ])^_u32 (y +s )^_u32 ((y >>5 )+k [3 ])))
    return struct .pack ('>2I',y ,z )
def _cksum (buf ):
    v =0 
    for b in buf :
        v =131 *v +b &2147483647 
    return v 
def _tea_pkt (data ,key ):
    pad =(8 -(len (data )+10 )%8 )%8 
    plain =bytes ([os .urandom (1 )[0 ]&248 |pad ])+os .urandom (pad )+os .urandom (2 )+data +bytes (7 )
    out ,pp ,pc =(b'',bytes (8 ),bytes (8 ))
    for off in range (0 ,len (plain ),8 ):
        mixed =bytes ((a ^b for a ,b in zip (plain [off :off +8 ],pc )))
        enc =_tea_blk (mixed ,key )
        cipher =bytes ((a ^b for a ,b in zip (enc ,pp )))
        out +=cipher 
        pp ,pc =(mixed ,cipher )
    return out 
def _lp (s ):
    d =s .encode ()if isinstance (s ,str )else s 
    return struct .pack ('>H',len (d ))+d 
def _ck_guard (ts ,guid ):
    def tail (v ):
        t =str (v )
        return t [-5 :]if len (t )>=5 else ''
    body =struct .pack ('>I',ts )+_lp (tail (guid ))+_lp (tail ('null'))+_lp (tail ('null'))+_lp ('-1')
    plain =_lp (body )
    enc =_tea_pkt (plain ,_CK_GTEA )+struct .pack ('>I',_cksum (plain ))
    enc =bytes ((a ^_CK_GXOR [i &7 ]for i ,a in enumerate (enc )))
    return enc .hex ().upper ()
def _ckey (channel_id ):
    ts =int (time .time ())
    guid =os .urandom (16 ).hex ()
    guard =_ck_guard (ts ,guid )
    uid =os .urandom (4 ).hex ().upper ()
    body =bytes .fromhex ('0000004200000004000004d2')+struct .pack ('>I',_CK_PLATFORM )+struct .pack ('>I',0 )+struct .pack ('>I',ts )+_lp ('dcgh')+_lp ('_zj1A5Gh6QYcxWjIUGos2w==')+_lp (_CK_APPVER )+_lp (str (channel_id ))+_lp (guid )+struct .pack ('>I',1 )+struct .pack ('>I',1 )+_lp (uid )+_lp ('nil')+_lp ('57eab0c4-2c58-44c6-8ae9-dd2757525dc5')+_lp ('nil')+_lp ('v0.1.000')+_lp ('com.cctv.yangshipin.app.iphone')+_lp (str (_CK_PLATFORM ))+_lp ('ex_json_bus')+_lp ('ex_json_vs')+_lp (guard )
    pkt =bytearray (struct .pack ('>H',len (body ))+body )
    pkt [18 :22 ]=struct .pack ('>I',_cksum (bytes (pkt )))
    pkt =bytes (pkt )
    enc =_tea_pkt (pkt ,_CK_TEA )+struct .pack ('>I',_cksum (pkt ))
    enc =bytes ((a ^_CK_XOR [i &15 ]for i ,a in enumerate (enc )))
    b64 =base64 .b64encode (enc ).decode ().replace ('+','_').replace ('/','-').rstrip ('=')
    return {'cKey':'--01'+b64 ,'guid':guid ,'ts':ts ,'flowId':'%s_%d'%(uuid .uuid4 ().hex .upper (),_CK_PLATFORM )}
_BK_H264 =base64 .b64encode (b'H(30:1080,60:1080|30:1080,60:1080)').decode ()
def bk_playurls (channel_id ,live_pid ,defn ='fhd'):
    if defn in ('auto', 'best'):
        defn = 'fhd'
    t =_ckey (channel_id )
    q =urllib .parse .urlencode ({'atime':'120','livepid':live_pid ,'cnlid':channel_id ,'appVer':_CK_APPVER ,'app_version':'300090','caplv':'1','cmd':'2','defn':defn ,'device':'iPhone','encryptVer':'4.2','getpreviewinfo':'0','hevclv':'0','lang':'zh-Hans_CN','livequeue':'0','logintype':'1','nettype':'1','newnettype':'1','newplatform':str (_CK_PLATFORM ),'platform':str (_CK_PLATFORM ),'sdtfrom':'v3021','spacode':'23','spaudio':'1','spdemuxer':'6','spdrm':'2','spdynamicrange':'1','spflv':'1','spflvaudio':'1','sphdrfps':'60','sphttps':'1','spvcode':_BK_H264 ,'spvideo':'4','stream':'1','system':'1','sysver':'ios18.2.1','uhd_flag':'0','cKey':t ['cKey'],'guid':t ['guid'],'fntick':str (t ['ts']),'flowid':t ['flowId'],'playbacktime':'0'})
    req =urllib .request .Request ('https://bkliveinfo.ysp.cctv.cn/?'+q ,headers ={'User-Agent':'qqlive','Accept':'application/json'})
    with urllib .request .urlopen (req ,timeout =5 )as r :
        p =json .loads (r .read ().decode ())
    if int (p .get ('iretcode',-1 ))!=0 :
        raise RuntimeError ('iretcode=%s %s'%(p .get ('iretcode'),p .get ('errinfo','')))
    urls =[]
    if p .get ('playurl'):
        urls .append (p ['playurl'])
    bu =p .get ('backurl_list')or p .get ('backurlList')or p .get ('backurl')
    if isinstance (bu ,list ):
        for it in bu :
            urls .append (it if isinstance (it ,str )else it .get ('url')or it .get ('playurl')or '')
    elif isinstance (bu ,str ):
        urls +=[x for x in re .split ('[;,]',bu )if x .strip ()]
    urls =[u for u in dict .fromkeys (urls )if u and '.cctv.'in u ]
    if not urls :
        raise RuntimeError ('no playurl')
    urls .sort (key =lambda u :(0 if 'bklive-'in u else 1 ,u ))
    return urls 
def fetch_abs_playlist(url, depth=0, quality='fhd', *, policy=None, _deadline=None, _profile_out=None):
    deadline = _deadline if _deadline is not None else time.monotonic() + 10
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ProxyError(504, 'playlist chain deadline exceeded')
    policy = policy or URLPolicy(engine_port=engine_port)
    headers = {'User-Agent': 'qqlive', 'Referer': 'https://live.cctv.cn/',
               'Accept': 'application/vnd.apple.mpegurl,application/json,*/*'}
    status, _, data, final = fetch_bytes(url, headers, policy=policy, timeout=remaining,
                                        deadline=deadline, max_bytes=2 * 1024 * 1024)
    if status != 200:
        raise ProxyError(status, 'playlist HTTP ' + str(status), category='upstream_status')
    text = data.decode('utf-8-sig', 'strict')
    analysis = validate_source_playlist(text)
    variant = select_variant(text, quality)
    if variant:
        if depth >= 4:
            raise UnsafePlaylist('too many nested HLS master playlists')
        selected = next(v for v in analysis.variants if v.uri == variant)
        child_metadata = {}
        result = fetch_abs_playlist(urllib.parse.urljoin(final, variant), depth + 1, quality,
                                    policy=policy, _deadline=deadline, _profile_out=child_metadata)
        child_profile = child_metadata.get('profile', StreamProfile())
        effective = StreamProfile(child_profile.width or selected.profile.width,
            child_profile.height or selected.profile.height, child_profile.bandwidth or selected.profile.bandwidth,
            child_profile.codecs or selected.profile.codecs, child_profile.audio_group or selected.profile.audio_group)
        remember_playlist_profile(result, effective)
        if _profile_out is not None:
            _profile_out['profile'] = effective
        return result
    filtered = filter_master_quality(text, quality)
    current_variants = analyze_playlist(filtered).variants
    if current_variants and _profile_out is not None:
        _profile_out['profile'] = max(current_variants, key=lambda v: (v.profile.height, v.profile.width, v.profile.bandwidth)).profile
    return rewrite_playlist_urls(filtered, final)
DEFAULT_CHANNELS =[
('cctv1','CCTV-1 综合','2024078201','600001859','fhd'),
('cctv2','CCTV-2 财经','2024075401','600001800','fhd'),
('cctv3','CCTV-3 综艺','2024068501','600001801','fhd'),
('cctv4','CCTV-4 中文国际','2029797101','600001814','fhd'),
('cctv5','CCTV-5 体育','2024078401','600001818','fhd'),
('cctv5p','CCTV-5+ 体育赛事','2024078001','600001817','fhd'),
('cctv6','CCTV-6 电影','2013693901','600108442','fhd'),
('cctv7','CCTV-7 国防军事','2024072001','600004092','fhd'),
('cctv8','CCTV-8 电视剧','2029793001','600001803','fhd'),
('cctv9','CCTV-9 纪录','2024078601','600004078','fhd'),
('cctv10','CCTV-10 科教','2024078701','600001805','fhd'),
('cctv11','CCTV-11 戏曲','2027248701','600001806','fhd'),
('cctv12','CCTV-12 社会与法','2027248801','600001807','fhd'),
('cctv13','CCTV-13 新闻','2029797201','600001811','fhd'),
('cctv14','CCTV-14 少儿','2027248901','600001809','fhd'),
('cctv15','CCTV-15 音乐','2027249001','600001815','fhd'),
('cctv16','CCTV-16 奥林匹克','2027249101','600098637','fhd'),
('cctv164k','CCTV-16 4K','2027249301','600099502','fhd'),
('cctv17','CCTV-17 农业农村','2027249401','600001810','fhd'),
('cctv4k','CCTV-4K 超高清','2029810301','600002264','fhd'),
('cctv8k','CCTV-8K 超高清','2026774101','600156816','fhd'),
('cgtn','CGTN','2024181701','600014550','fhd'),
('cgtnfr','CGTN 法语','2024181801','600084704','fhd'),
('cgtnru','CGTN 俄语','2024181901','600084758','fhd'),
('cgtnar','CGTN 阿拉伯语','2024182001','600084782','fhd'),
('cgtnes','CGTN 西班牙语','2024182101','600084744','fhd'),
('cgtndoc','CGTN 纪录','2024182301','600084781','fhd'),
('cctvfyjc','CCTV 风云剧场','2025637102','600099658','shd'),
('cctvdyjc','CCTV 第一剧场','2026874202','600099655','shd'),
('cctvhjjc','CCTV 怀旧剧场','2026874302','600099620','shd'),
('bjws','北京卫视','2024052703','600002309','fhd'),
('jsws','江苏卫视','2024171103','600002521','fhd'),
('dfws','东方卫视','2024054503','600002483','fhd'),
('zjws','浙江卫视','2024054703','600002520','fhd'),
('hnws','湖南卫视','2024054803','600002475','fhd'),
('hbws','湖北卫视','2024171203','600002508','fhd'),
('gdws','广东卫视','2024060903','600002485','fhd'),
('gxws','广西卫视','2024060703','600002509','fhd'),
('hljws','黑龙江卫视','2029797003','600002498','fhd'),
('hainanws','海南卫视','2024055603','600002506','fhd'),
('cqws','重庆卫视','2024061103','600002531','fhd'),
('szws','深圳卫视','2024061303','600002481','fhd'),
('scws','四川卫视','2024061403','600002516','fhd'),
('henanws','河南卫视','2029797303','600002525','fhd'),
('dnws','东南卫视','2024061503','600002484','fhd'),
('gzws','贵州卫视','2024061603','600002490','fhd'),
('jxws','江西卫视','2024061703','600002503','fhd'),
('lnws','辽宁卫视','2024171303','600002505','fhd'),
('ahws','安徽卫视','2024171403','600002532','fhd'),
('hebws','河北卫视','2024171503','600002493','fhd'),
('sdws','山东卫视','2029787903','600002513','fhd'),
('tjws','天津卫视','2019927003','600152137','fhd'),
('jlws','吉林卫视','2025561503','600190405','fhd'),
('saxws','陕西卫视','2029795103','600190400','fhd'),
('nxws','宁夏卫视','2025608503','600190737','fhd'),
('nmgws','内蒙古卫视','2025561203','600190401','fhd'),
('ynws','云南卫视','2025561303','600190402','fhd'),
('shanxiws','山西卫视','2025560803','600190407','fhd'),
('gsws','甘肃卫视','2025561703','600190408','fhd'),
('qhws','青海卫视','2025559103','600190406','fhd'),
('xizangws','西藏卫视','2025558003','600190403','fhd'),
('xjws','新疆卫视','2019927403','600152138','fhd'),
('cetv1','CETV-1','2022823801','600171827','fhd'),
('guoxue','国学频道','2029360403','600213139','fhd')
]
ALIAS_MAP ={
'anhuiws':'ahws','beijingws':'bjws','cctv16hd':'cctv16','cctv5plus':'cctv5p',
'cctvdiyijuchang':'cctvdyjc','cctvfengyunjuchang':'cctvfyjc','cctvhuaijiujuchang':'cctvhjjc',
'cgtnalaboyu':'cgtnar','cgtneyu':'cgtnru','cgtnfayu':'cgtnfr','cgtnwaiyujilu':'cgtndoc',
'cgtnxibanyayu':'cgtnes','chongqingws':'cqws','dongfangws':'dfws','fujiandongnanws':'dnws',
'guangdongws':'gdws','guangxiws':'gxws','guizhouws':'gzws','hebeiws':'hebws',
'heilongjiangws':'hljws','hubeiws':'hbws','hunanws':'hnws','jiangsuws':'jsws',
'jiangxiws':'jxws','jilinws':'jlws','liaoningws':'lnws','neimengguws':'nmgws',
'ningxiaws':'nxws','qinghaiws':'qhws','shandongws':'sdws','shannxiws':'saxws',
'shenzhenws':'szws','sichuanws':'scws','tianjinws':'tjws','xinjiangws':'xjws',
'yunnanws':'ynws','zhejiangws':'zjws'
}
TVG_IDS ={
'cctv1':'CCTV1','cctv2':'CCTV2','cctv3':'CCTV3','cctv4':'CCTV4',
'cctv5':'CCTV5','cctv5p':'CCTV5+','cctv6':'CCTV6','cctv7':'CCTV7',
'cctv8':'CCTV8','cctv9':'CCTV9','cctv10':'CCTV10','cctv11':'CCTV11',
'cctv12':'CCTV12','cctv13':'CCTV13','cctv14':'CCTV14','cctv15':'CCTV15',
'cctv16':'CCTV16','cctv164k':'CCTV16','cctv17':'CCTV17','cctv4k':'CCTV4K',
'cctv8k':'CCTV-8K','cgtn':'CGTN英语','cgtnfr':'CGTN法语','cgtnru':'CGTN俄语',
'cgtnar':'CGTN阿语','cgtnes':'CGTN西语','cgtndoc':'CGTN纪录',
'cctvdyjc':'CCTV第一剧场','cctvfyjc':'CCTV风云剧场','cctvhjjc':'CCTV怀旧剧场',
'cetv1':'CETV1','bjws':'北京卫视','jsws':'江苏卫视','dfws':'东方卫视',
'zjws':'浙江卫视','hnws':'湖南卫视','hbws':'湖北卫视','gdws':'广东卫视',
'gxws':'广西卫视','hljws':'黑龙江卫视','hainanws':'海南卫视','cqws':'重庆卫视',
'szws':'深圳卫视','scws':'四川卫视','henanws':'河南卫视','dnws':'东南卫视',
'gzws':'贵州卫视','jxws':'江西卫视','lnws':'辽宁卫视','ahws':'安徽卫视',
'hebws':'河北卫视','sdws':'山东卫视','tjws':'天津卫视','jlws':'吉林卫视',
'saxws':'陕西卫视','nxws':'宁夏卫视','nmgws':'内蒙古卫视','ynws':'云南卫视',
'shanxiws':'山西卫视','qhws':'青海卫视','xizangws':'西藏卫视','xjws':'新疆卫视',
'gsws':'甘肃卫视','guoxue':'国学'
}
LOGO_BASE ='https://garysclub.sharewithyou.dpdns.org/logos/ysp-live-logos'
UA ='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
REFRESH_INTERVAL =10 
IDLE_TIMEOUT =120 
LINK_IDLE_TIMEOUT =15.0 
WINDOW =300 
MAX_SEGS =120 
BK_URL_TTL =300 
BACKEND_CHANNELS ={
'cctv1','cctv2','cctv3','cctv4','cctv5','cctv5p','cctv7','cctv8',
'cctv9','cctv10','cctv11','cctv12','cctv13','cctv14','cctv15',
'cctv16','cctv17','cctv4k','cctv8k','cctv164k','cgtn','cgtnfr',
'cgtnru','cgtnar','cgtnes','cgtndoc'
}
TRUE_4K_CHANNELS ={'cctv4k','cctv8k','cctv164k'}
active_backend_channels =set (BACKEND_CHANNELS )
TIMESHIFT_SUPPORTED ={
"cctv1","cctv2","cctv3","cctv4","cctv5","cctv5p","cctv6","cctv7","cctv8","cctv9","cctv10","cctv13","cctv8k",
"cgtn","cgtnfr","cgtnru","cgtnar","cgtnes","cgtndoc","cetv1","guoxue",
"bjws","jsws","dfws","zjws","hnws","hbws","gdws","gxws",
"hljws","hainanws","cqws","szws","scws","henanws","dnws",
"gzws","jxws","lnws","ahws","hebws","sdws","tjws","jlws",
"saxws","nxws","nmgws","ynws","shanxiws","qhws","xizangws","xjws","gsws"
}
def get_channel_group (slug :str )->str :
    s =ALIAS_MAP .get (slug .lower (),slug .lower ())
    if s .startswith ("cctv")or s .startswith ("cgtn"):
        return "央视"
    return "卫视"
class CatchupError(ValueError):
    """The client requested catchup, but the supplied time range is invalid."""


def parse_catchup_time_val(val_str):
    if val_str is None:
        return None
    val = val_str.strip()
    if not val:
        raise CatchupError('回看时间不能为空')
    cst = datetime.timezone(datetime.timedelta(hours=8))
    try:
        if re.fullmatch(r'\d{10}', val):
            return int(val)
        if re.fullmatch(r'\d{13}', val):
            return int(val) // 1000
        if re.fullmatch(r'(?:\d{12}|\d{14})Z?', val, re.IGNORECASE):
            digits = val.rstrip('Zz')
            fmt = '%Y%m%d%H%M%S' if len(digits) == 14 else '%Y%m%d%H%M'
            zone = datetime.timezone.utc if val.upper().endswith('Z') else cst
            return int(datetime.datetime.strptime(digits, fmt).replace(tzinfo=zone).timestamp())
        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:[Zz]|[+-]\d{2}:?\d{2})?', val):
            raise ValueError('unsupported timestamp format')
        iso = val[:-1] + '+00:00' if val.upper().endswith('Z') else val
        dt = datetime.datetime.fromisoformat(iso)
        return int(dt.replace(tzinfo=cst).timestamp() if dt.tzinfo is None else dt.timestamp())
    except (ValueError, OverflowError, OSError) as exc:
        raise CatchupError('无效回看时间: ' + val) from exc


def parse_catchup_query(query_str):
    qs = urllib.parse.parse_qs(query_str, keep_blank_values=True)
    names = {'playseek', 'start', 'end', 'utc', 'lutc', 'starttime', 'endtime'}
    present = names.intersection(qs)
    if not present:
        return None
    if any(len(qs[name]) != 1 for name in present):
        raise CatchupError('回看参数不能重复')
    if 'playseek' in present and len(present) > 1:
        raise CatchupError('playseek 不能与其他回看时间参数混用')
    starts = present.intersection({'start', 'utc', 'starttime'})
    ends = present.intersection({'end', 'lutc', 'endtime'})
    if len(starts) > 1 or len(ends) > 1:
        raise CatchupError('请只提供一组回看开始和结束时间')
    start_ts = end_ts = None
    if 'playseek' in present:
        value = qs['playseek'][0]
        # Test the full value first; ISO dates contain their own '-' separators.
        try:
            start_ts = parse_catchup_time_val(value)
        except CatchupError:
            candidates = []
            for index, char in enumerate(value):
                if char != '-':
                    continue
                try:
                    candidates.append((parse_catchup_time_val(value[:index]), parse_catchup_time_val(value[index + 1:])))
                except CatchupError:
                    continue
            if len(candidates) != 1:
                raise CatchupError('无效 playseek 范围；ISO 时间建议使用 start/end 参数')
            start_ts, end_ts = candidates[0]
    else:
        if starts:
            start_ts = parse_catchup_time_val(qs[next(iter(starts))][0])
        if ends:
            end_ts = parse_catchup_time_val(qs[next(iter(ends))][0])
    if start_ts is None:
        raise CatchupError('回看需要开始时间')
    now = int(time.time())
    if start_ts > now:
        raise CatchupError('回看开始时间不能晚于当前时间')
    if start_ts < now - 7 * 86400:
        raise CatchupError('回看开始时间超出 7 天范围')
    if end_ts is None:
        end_ts = min(start_ts + 7200, now)
    if end_ts <= start_ts:
        raise CatchupError('回看结束时间必须晚于开始时间')
    if end_ts > now + 30:
        raise CatchupError('回看结束时间不能晚于当前时间')
    if end_ts - start_ts > 86400:
        raise CatchupError('单次回看范围不能超过 24 小时')
    return start_ts, end_ts


class _RefreshTask:
    def __init__(self):
        self.event = threading.Event()
        self.result = None
        self.error = None


_inflight_refresh = {}
_inflight_lock = threading.Lock()
_refresh_slots = threading.BoundedSemaphore(8)


def coalesce_refresh(slug, refresh_fn, timeout=None):
    """Join one channel refresh; timed-out waiters never cancel or replace it."""
    with _inflight_lock:
        task = _inflight_refresh.get(slug)
        if task is None:
            # Admission is bounded before creating a thread, avoiding an unbounded queue.
            if not _refresh_slots.acquire(blocking=False):
                return False
            task = _RefreshTask()
            _inflight_refresh[slug] = task
            owner = True
        else:
            owner = False
    if owner:
        def run():
            try:
                task.result = refresh_fn()
            except BaseException as exc:
                task.error = exc
            finally:
                # Publish completion while still registered so no waiter can start a duplicate.
                task.event.set()
                with _inflight_lock:
                    if _inflight_refresh.get(slug) is task:
                        _inflight_refresh.pop(slug, None)
                _refresh_slots.release()
        try:
            threading.Thread(target=run, daemon=True, name='refresh-' + slug).start()
        except BaseException:
            with _inflight_lock:
                _inflight_refresh.pop(slug, None)
            _refresh_slots.release()
            raise
    if not task.event.wait(timeout):
        return None
    if task.error is not None:
        raise task.error
    return task.result

class ApiFlowLimiter :
    def __init__ (self ,min_interval_ms :int =700 ,jitter_ms :int =250 ):
        self .min_interval =min_interval_ms /1000.0 
        self .jitter =jitter_ms /1000.0 
        self .lock =threading .Lock ()
        self .last_call =0.0 
    def wait_slot (self ):
        with self .lock :
            now =time .monotonic ()
            target_delay =self .min_interval +random .uniform (0.0 ,self .jitter )
            diff =now -self .last_call 
            if diff <target_delay :
                time .sleep (target_delay -diff )
            self .last_call =time .monotonic ()
global_flow_limiter =ApiFlowLimiter ()
class TsSegmentCache :
    def __init__ (self ,max_mb :int =100 ,max_age_sec :int =180 ):
        self .max_bytes =max_mb *1024 *1024 
        self .max_age =max_age_sec 
        self .lock =threading .Lock ()
        self .cache :dict [str ,tuple [bytes ,dict ,float ]]={}
        self .order =collections .deque ()
        self .curr_bytes =0 
        self .hits =0 
        self .misses =0 
    def get (self ,key :str )->tuple [bytes ,dict ]|None :
        with self .lock :
            item =self .cache .get (key )
            if not item :
                self .misses +=1 
                return None 
            data ,headers ,expire_at =item 
            if time .time ()>expire_at :
                self .cache .pop (key ,None )
                try :
                    self .order .remove (key )
                except ValueError :
                    pass 
                self .curr_bytes -=len (data )
                self .misses +=1 
                return None 
            self .hits +=1 
            return data ,headers 
    def set (self ,key :str ,data :bytes ,headers :dict ):
        with self .lock :
            if len (data )>self .max_bytes :
                return 
            if key in self .cache :
                old =self .cache .pop (key )
                self .curr_bytes -=len (old [0 ])
                try :
                    self .order .remove (key )
                except ValueError :
                    pass 
            now =time .time ()
            while (self .curr_bytes +len (data )>self .max_bytes )and self .order :
                old_key =self .order .popleft ()
                old_val =self .cache .pop (old_key ,None )
                if old_val :
                    self .curr_bytes -=len (old_val [0 ])
            self .cache [key ]=(data ,headers ,now +self .max_age )
            self .order .append (key )
            self .curr_bytes +=len (data )
    def stats (self )->dict :
        with self .lock :
            total =max (1 ,self .hits +self .misses )
            return {
            'count':len (self .cache ),
            'size_mb':round (self .curr_bytes /(1024 *1024 ),2 ),
            'hits':self .hits ,
            'misses':self .misses ,
            'hit_rate':f"{round (self .hits /total *100 ,1 )}%"
            }
global_ts_cache =TsSegmentCache (max_mb =200 )
media_proxy = SharedMediaProxy()
shutdown_event = threading.Event()
active_server = None
engine_enabled = True
class ChannelDirectory :
    def __init__ (self ):
        self .lock =threading .Lock ()
        self .channels_meta :dict [str ,dict ]={}
        self .canonical_slugs :list [str ]=[]
        self .load_defaults ()
    def load_defaults (self ):
        self .canonical_slugs .clear ()
        for slug ,name ,sid ,pid ,defn in DEFAULT_CHANNELS :
            grp =get_channel_group (slug )
            tid =TVG_IDS .get (slug ,slug .upper ())
            logo =f"{LOGO_BASE }/{slug }.png"
            self .channels_meta [slug ]={
            'slug':slug ,'name':name ,'sid':sid ,'pid':pid ,'defn':defn ,
            'logo':logo ,'group':grp ,'tvg_id':tid 
            }
            self .canonical_slugs .append (slug )
    def get_meta (self ,slug :str )->dict |None :
        slug =ALIAS_MAP .get (slug .lower (),slug .lower ())
        with self .lock :
            return self .channels_meta .get (slug )
    def all_channels (self )->list [dict ]:
        return self .unique_channels ()
    def unique_channels (self )->list [dict ]:
        with self .lock :
            return [self .channels_meta [s ]for s in self .canonical_slugs if s in self .channels_meta ]
global_channel_dir =ChannelDirectory ()
class FrozenPlaylistError(RuntimeError):
    pass


class Channel:
    def __init__(self, slug, name, sid, pid, defn):
        self.slug, self.name, self.sid, self.pid, self.defn = slug, name, sid, pid, defn
        self.lock = threading.RLock()
        self.publication_lock = threading.RLock()
        self.segments = {}
        self.segment_models = {}
        self.order = deque()
        self.seen_keys = deque(maxlen=MAX_SEGS * 2)
        self.seq = 0
        self.last_access = 0.0
        self.thread = None
        self.last_error = ''
        self.last_ok = 0.0
        self.last_fetch_success_at = 0.0
        self.last_media_advance_at = 0.0
        self._last_media_advance_mono = 0.0
        self._media_fingerprint = None
        self._media_progress = {}
        self.media_stalled = False
        self.media_target_duration = 6.0
        self.mode = 'jce'
        self.last_pdt = ''
        self.bk_urls = []
        self.bk_urls_time = 0.0
        self.bk_playlist = ''
        self._starting = False
        self.last_built_playlist = ''
        self.last_built_time = 0.0
        self._jce_media = None
        self._jce_passthrough = ''
        self._jce_disc_base = 0
        self._refresh_failures = 0
        self._next_jce_probe = 0.0
        self._publication = None
        self.source_epoch = 0
        self.source_restart_required = False


def seg_key(url, pdt):
    stamp = pdt_seconds(pdt)
    if stamp is not None:
        return 'pdt:' + format(stamp, '.6f')
    return stable_uri(url)


class _FetchedSegments(list):
    def __init__(self, playlist):
        self.playlist = playlist
        self.media = parse_media(playlist)
        super().__init__((s.duration, s.pdt, s.uri) for s in (self.media.segments if self.media else []))


def jce_fetch(ch):
    global_flow_limiter.wait_slot()
    now = int(time.time())
    url = jce_timeshift_url(ch.pid, ch.sid, now - WINDOW, now, ch.defn)
    playlist = fetch_abs_playlist(url, quality=ch.defn)
    result = _FetchedSegments(playlist)
    if not result and result.media is not None:
        raise RuntimeError('empty media playlist')
    return result


def defn_label(defn):
    return {'best': '最高可用档位', 'fhd': '1080p', 'shd': '720p', 'stable': '720p', 'auto': '自适应'}.get((defn or '').lower(), defn or '1080p')


def _record_media_progress(ch, fingerprint, target=6.0, source='jce'):
    """HTTP success is independent from actual media progress."""
    now, mono = time.time(), time.monotonic()
    ch.last_fetch_success_at = now
    ch.media_target_duration = target
    if fingerprint is None:
        # A retained master has no observable media edge; don't claim a freeze.
        return
    progress = ch._media_progress.get(source)
    if progress is None or fingerprint != progress[0]:
        progress = (fingerprint, now, mono)
        ch._media_progress[source] = progress
    if fingerprint != ch._media_fingerprint:
        ch._media_fingerprint = fingerprint
    ch.last_media_advance_at = progress[1]
    ch._last_media_advance_mono = progress[2]
    ch.media_stalled = False
    age = mono - progress[2]
    if age > max(3 * target, 3 * REFRESH_INTERVAL):
        ch.media_stalled = True
        raise FrozenPlaylistError('媒体列表超过 %.0f 秒没有前进' % age)


def jce_refresh(ch):
    fetched = jce_fetch(ch)
    media = getattr(fetched, 'media', None)
    playlist = getattr(fetched, 'playlist', '')
    with ch.lock:
        if media is None and playlist:
            ch._jce_passthrough = playlist
            ch._jce_media = None
            _record_media_progress(ch, None)
            return True
        if media is not None and media.unsafe:
            fingerprint, target = media_signature(playlist)
            _record_media_progress(ch, fingerprint, target)
            ch._jce_passthrough = playlist
            ch._jce_media = None
            ch.source_restart_required = True
            return True
        if media is None:
            # Compatibility for callers/tests supplying the old tuple list.
            lines = ['#EXTM3U', '#EXT-X-TARGETDURATION:6', '#EXT-X-MEDIA-SEQUENCE:0']
            for duration, pdt, uri in fetched:
                if pdt:
                    lines.append('#EXT-X-PROGRAM-DATE-TIME:' + pdt)
                lines.extend(('#EXTINF:%s,' % duration, uri))
            media = parse_media('\n'.join(lines))
        if not media or not media.segments:
            raise RuntimeError('empty media playlist')
        is_init, added = not ch.order, 0
        if is_init:
            keep = media.segments[-25:]
            ch._jce_disc_base = media.discontinuity_sequence + sum(s.discontinuity for s in media.segments[:-len(keep)])
        else:
            keep = media.segments
        latest_stamp = pdt_seconds(ch.last_pdt)
        for segment in keep:
            key = repr(segment.identity)
            # Re-signing an existing segment must happen before any PDT age check.
            if key in ch.segments:
                output_seq = ch.segments[key][0]
                ch.segments[key] = [output_seq, segment.duration, segment.pdt, segment.uri]
                ch.segment_models[key] = segment
                continue
            stamp = pdt_seconds(segment.pdt)
            if not is_init and stamp is not None and latest_stamp is not None and stamp <= latest_stamp:
                continue
            if key in ch.seen_keys:
                continue
            ch.seen_keys.append(key)
            ch.seq += 1
            ch.segments[key] = [ch.seq, segment.duration, segment.pdt, segment.uri]
            ch.segment_models[key] = segment
            ch.order.append(key)
            added += 1
            if stamp is not None and (latest_stamp is None or stamp > latest_stamp):
                ch.last_pdt, latest_stamp = segment.pdt, stamp
        while len(ch.order) > MAX_SEGS:
            old = ch.order.popleft()
            old_model = ch.segment_models.pop(old, None)
            if old_model:
                ch._jce_disc_base += old_model.discontinuity
            ch.segments.pop(old, None)
        ch._jce_media = media
        ch._jce_passthrough = ''
        fingerprint = repr((ch.seq, ch.order[-1] if ch.order else None))
        _record_media_progress(ch, fingerprint, media.target)
        ch.last_error = ''
    if is_init and added:
        log('[%s] %s 备用流缓冲就绪 (%s 片)' % (ch.slug, defn_label(ch.defn), len(ch.segments)))
    return True


def bk_refresh(ch):
    global_flow_limiter.wait_slot()
    now = time.monotonic()
    if now - ch.bk_urls_time > BK_URL_TTL or not ch.bk_urls:
        ch.bk_urls = bk_playurls(ch.sid, ch.pid, ch.defn)
        ch.bk_urls_time = now
    last_error = ''
    for attempt in range(2):
        for url in list(ch.bk_urls):
            try:
                playlist = fetch_abs_playlist(url, quality=ch.defn)
                fingerprint, target = media_signature(playlist)
                with ch.lock:
                    _record_media_progress(ch, fingerprint, target, source='bk')
                    ch.bk_playlist = playlist
                    ch.last_error = ''
                return True
            except Exception as exc:
                last_error = '%s: %s' % (type(exc).__name__, exc)
        if attempt == 0:
            try:
                ch.bk_urls = bk_playurls(ch.sid, ch.pid, ch.defn)
                ch.bk_urls_time = time.monotonic()
            except Exception:
                pass
    ch.bk_urls, ch.bk_urls_time = [], 0
    raise RuntimeError(last_error[:120] or 'bk playlist failed')


def refresh_once(ch):
    try:
        if ch.mode == 'bk':
            # Probe a recovered primary infrequently; forced-BK channels stay on BK.
            if ch.slug not in FORCE_BK and time.monotonic() >= ch._next_jce_probe:
                ch._next_jce_probe = time.monotonic() + 120
                try:
                    if jce_refresh(ch):
                        ch.mode = 'jce'
                        ch._refresh_failures = 0
                        ch.last_ok = time.time()
                        return True
                except Exception:
                    pass
            ok = bk_refresh(ch)
        else:
            try:
                ok = jce_refresh(ch)
            except Exception as exc:
                ch._refresh_failures += 1
                if not isinstance(exc, (DeadHostError, FrozenPlaylistError)) and ch._refresh_failures < 3:
                    raise
                ch.mode = 'bk'
                ch._next_jce_probe = time.monotonic() + 120
                log('[%s] JCE 不可用，切换备用通道' % ch.slug, min_interval=10.0)
                ok = bk_refresh(ch)
        if ok:
            ch.last_ok = time.time()
            ch._refresh_failures = 0
        return ok
    except Exception as exc:
        ch.last_error = ('%s: %s' % (type(exc).__name__, exc))[:120]
        log('[%s] 刷新异常: %s' % (ch.slug, ch.last_error), min_interval=15.0)
        return False


def _refresh_and_build(ch):
    ok = refresh_once(ch)
    if ok:
        build_playlist(ch, holdback=True)
    return ok


def refresh_loop(ch):
    failures = 0
    stop = globals().get('shutdown_event')
    while time.time() - ch.last_access < IDLE_TIMEOUT and not (stop and stop.is_set()):
        with ch.lock:
            recent = time.time() - ch.last_fetch_success_at < min(REFRESH_INTERVAL, ch.media_target_duration)
        if not recent:
            ok = coalesce_refresh(ch.slug, lambda: _refresh_and_build(ch))
            failures = 0 if ok else failures + 1
        interval = min(REFRESH_INTERVAL, max(2.0, ch.media_target_duration))
        delay = interval if failures < 3 else 30
        if stop:
            stop.wait(delay)
        else:
            time.sleep(delay)


def ensure_channel(ch):
    ch.last_access = time.time()
    with ch.lock:
        needs_fetch = not (ch.segments or ch.bk_playlist or ch._jce_passthrough)
    if needs_fetch:
        # All entry points, including the background loop, join this same task.
        coalesce_refresh(ch.slug, lambda: _refresh_and_build(ch), timeout=5.0)
    with ch.lock:
        if ch.thread is None or not ch.thread.is_alive():
            ch.thread = threading.Thread(target=refresh_loop, args=(ch,), daemon=True, name='channel-' + ch.slug)
            ch.thread.start()


def build_playlist(ch, holdback=True):
    with ch.lock:
        if ch.mode == 'bk':
            result = ch.bk_playlist or None
        elif ch._jce_passthrough:
            result = ch._jce_passthrough
        else:
            keys = list(ch.order)[-15:]
            if holdback and len(keys) >= 4:
                keys = keys[:-1]
            models = [ch.segment_models[k] for k in keys if k in ch.segment_models]
            sequences = [ch.segments[k][0] for k in keys if k in ch.segment_models]
            if not models or ch._jce_media is None:
                return None
            all_models = [ch.segment_models[k] for k in ch.order if k in ch.segment_models]
            media = dataclasses.replace(ch._jce_media, segments=all_models, trailing=[])
            try:
                result = render_media(media, models, sequences, live=True, discontinuity_base=ch._jce_disc_base)
            except UnsafePlaylist:
                # A complex format must keep its original sequence and full state.
                result = getattr(ch._jce_media, 'original_text', '') or None
                ch.source_restart_required = True
                if not result:
                    ch.last_error = '此 HLS 格式不能安全重建，等待原始列表'
                    return None
        if result:
            # Keep SWR refresh time unchanged when only authorization URLs changed.
            previous_signature, _ = media_signature(ch.last_built_playlist) if ch.last_built_playlist else (None, 6)
            signature, _ = media_signature(result)
            ch.last_built_playlist = result
            ch.last_built_source = 'backup:' + ch.mode
            if not ch.last_built_time or signature != previous_signature:
                ch.last_built_time = time.time()
        return result


def trigger_background_refresh(ch):
    coalesce_refresh(ch.slug, lambda: _refresh_and_build(ch), timeout=0)


def publish_channel_playlist(ch, playlist, source, head_only=False):
    """Publish a shared sliding timeline. HEAD never consumes a source transition.

    Discontinuity boundaries stay with their segment until it leaves the window.
    Incompatible/LL-HLS lists preserve upstream semantics and require player reopen.
    """
    if source == 'backup':
        source = 'backup:' + ch.mode
    with ch.publication_lock:
        state = ch._publication
        if head_only:
            return state['snapshot'] if state else playlist
        media = parse_media(playlist)
        fingerprint, target = None, 6.0
        if state and state['source'] == source and media and media.segments:
            last_sequence = state['mapping'].get(media.segments[-1].identity)
            if last_sequence is not None and last_sequence < state.get('published_edge', last_sequence):
                with ch.lock:
                    _record_media_progress(ch, state['signature'], state['target'], source='published-' + source)
                return state['snapshot']
        if media is not None and media.segments and (source in ('device', 'engine') or source.startswith('backup:')):
            fingerprint, target = media_signature(playlist)
            with ch.lock:
                _record_media_progress(ch, fingerprint, target, source='published-' + source)
        if state and state['source'] == source and state.get('input_body') == playlist:
            return state['snapshot']
        if media is None or media.unsafe or not media.segments:
            changed = state is not None and state['source'] != source
            ch.source_restart_required = bool(changed or (media is not None and media.unsafe))
            ch.source_epoch += int(changed)
            ch._publication = {'source': source, 'snapshot': playlist, 'mapping': {}, 'next': state['next'] if state else 0, 'boundary': None, 'disc': 0, 'source_disc': 0, 'input_body': playlist}
            return playlist
        identities = [segment.identity for segment in media.segments]
        if len(set(identities)) != len(identities):
            ch.source_restart_required = True
            return playlist
        changed = state is not None and state['source'] != source
        if state is None or changed:
            previous = state
            aligned = False
            ch.source_epoch += int(changed)
            state = {'source': source, 'snapshot': '', 'mapping': {}, 'next': previous['next'] if previous else media.sequence, 'boundary': None, 'disc': previous.get('end_disc', previous['disc']) if previous else media.discontinuity_sequence, 'source_disc': media.discontinuity_sequence}
            if changed:
                # Avoid replaying the old window when both sources expose absolute PDT.
                previous_edge = previous.get('edge_pdt')
                if previous_edge is not None:
                    candidates = [i for i, segment in enumerate(media.segments) if pdt_seconds(segment.pdt) is not None and pdt_seconds(segment.pdt) > previous_edge]
                    if candidates:
                        aligned = True
                        first = candidates[0]
                        state['source_disc'] += sum(s.discontinuity for s in media.segments[:first])
                        media = dataclasses.replace(media, segments=media.segments[first:])
                        identities = identities[first:]
                if not aligned and len(media.segments) > 3:
                    first = len(media.segments) - 3
                    state['source_disc'] += sum(s.discontinuity for s in media.segments[:first])
                    media = dataclasses.replace(media, segments=media.segments[first:])
                    identities = identities[first:]
                state['floor_identity'] = identities[0]
                state['floor_pdt'] = pdt_seconds(media.segments[0].pdt)
                state['boundary'] = state['next']
            ch.source_restart_required = changed and not aligned
        elif state.get('floor_identity'):
            # Keep the chosen switch entry point across every client's reload.
            # Otherwise older, previously trimmed segments would be appended as new media.
            floor = state['floor_identity']
            first = identities.index(floor) if floor in identities else 0
            floor_time = state.get('floor_pdt')
            if floor not in identities and floor_time is not None:
                first = next((i for i, segment in enumerate(media.segments) if pdt_seconds(segment.pdt) is not None and pdt_seconds(segment.pdt) >= floor_time), len(identities))
            if first == len(identities):
                return state['snapshot']
            if first:
                media = dataclasses.replace(media, segments=media.segments[first:])
                identities = identities[first:]
        mapping = state['mapping']
        render_segments = media.segments
        if not changed and mapping:
            overlap = next((i for i, identity in enumerate(identities) if identity in mapping), 0)
            if overlap:
                identities, render_segments = identities[overlap:], render_segments[overlap:]
        for identity in identities:
            if identity not in mapping:
                mapping[identity] = state['next']
                state['next'] += 1
        sequences = [mapping[identity] for identity in identities]
        floor = state.get('published_start', sequences[0])
        trim = next((i for i, sequence in enumerate(sequences) if sequence >= floor), len(sequences))
        if trim == len(sequences):
            return state['snapshot']
        if trim:
            sequences, render_segments = sequences[trim:], render_segments[trim:]
        boundary = state['boundary']
        if boundary is not None and boundary < sequences[0]:
            state['disc'] += 1
            state['boundary'] = boundary = None
        try:
            result = render_media(media, segments=render_segments, sequences=sequences, boundary=boundary, discontinuity_base=state['disc'] + max(0, media.discontinuity_sequence - state['source_disc']))
        except UnsafePlaylist:
            result = playlist
            ch.source_restart_required = True
        state['snapshot'], state['input_body'] = result, playlist
        state['signature'], state['target'] = fingerprint, target
        state['published_start'], state['published_edge'] = sequences[0], sequences[-1]
        state['end_disc'] = state['disc'] + max(0, media.discontinuity_sequence - state['source_disc']) + result.splitlines().count('#EXT-X-DISCONTINUITY')
        state['edge_pdt'] = pdt_seconds(media.segments[-1].pdt)
        # A bounded index retains several complete windows of overlap.
        if len(mapping) > MAX_SEGS * 4:
            state['mapping'] = {identity: seq for identity, seq in mapping.items() if seq >= state['next'] - MAX_SEGS * 3}
        ch._publication = state
        return result

CHANNEL_MAP :dict [str ,Channel ]={c [0 ]:Channel (*c )for c in DEFAULT_CHANNELS }
FORCE_BK ={'cctv11','cctv12','cctv14','cctv15','cctv16','cctv17','cctvfyjc','cctvdyjc','cctvhjjc'}
for _s in FORCE_BK :
    if _s in CHANNEL_MAP :
        CHANNEL_MAP [_s ].mode ='bk'
server_port :int =8767 
server_start_time =time .time ()
resolver :Resolver |None =None 
_resolver_ready :bool =False 
_resolver_lock =threading .Lock ()
def resolver_ready ()->bool :
    with _resolver_lock :
        return _resolver_ready 
def set_resolver_ready (ready :bool )->None :
    global _resolver_ready 
    with _resolver_lock :
        _resolver_ready =ready 
_last_channel_request :dict [str ,float ]={}
_last_channel_request_lock =threading .Lock ()
def get_channel_instance (slug :str )->Channel |None :
    slug =normalize_channel (slug )
    canonical =ALIAS_MAP .get (slug ,slug )
    if canonical in CHANNEL_MAP :
        return CHANNEL_MAP [canonical ]
    meta =global_channel_dir .get_meta (canonical )
    if meta :
        ch =Channel (meta ['slug'],meta ['name'],meta ['sid'],meta ['pid'],meta ['defn'])
        if canonical in FORCE_BK :
            ch .mode ='bk'
        return CHANNEL_MAP.setdefault(canonical, ch)
    return None 
engine_port =8787 
ALLOWED_ENGINE_PROXY_SUFFIXES =('.cctv.cn','.cctv.com','.cctvpic.com','.citvc.com','.yangshipin.cn','.cntv.cn','.cntv.com','.myqcloud.com','.qqlive.com','.gtimg.cn','.smtcdns.net','.smtcdns.com','.tcdnlive.com','.alicdn.com','.alikunlun.com','.wscdns.com','.chinanetcenter.com','.bdydns.com','.ksyungslb.com','.ks-cdn.com')
def _is_safe_engine_proxy_url (target :str ,_depth :int =0 )->bool :
    if _depth >2 :
        return False 
    try :
        parsed =urllib .parse .urlsplit (target )
    except ValueError :
        return False 
    if parsed .scheme not in ('http','https'):
        return False 
    host =(parsed .hostname or '').lower ()
    if not host :
        return False 
    if host in ('127.0.0.1','localhost'):
        if parsed .port !=engine_port or not parsed .path .startswith ('/segment'):
            return False 
        qs =urllib .parse .parse_qs (parsed .query )
        inner =qs .get ('url',[None ])[0 ]
        return bool (inner )and _is_safe_engine_proxy_url (inner ,_depth +1 )
    return any ((host ==s [1 :]or host .endswith (s )for s in ALLOWED_ENGINE_PROXY_SUFFIXES ))
def inject_hls_discontinuity (pl :str )->str :
    if '#EXT-X-DISCONTINUITY' in (line.strip() for line in pl.splitlines()):
        return pl 
    lines =pl .splitlines ()
    out =[]
    inserted =False 
    for line in lines :
        s =line .strip ()
        if not inserted and (s .startswith ('#EXT-X-PROGRAM-DATE-TIME:')or s .startswith ('#EXTINF:')or (s and not s .startswith ('#'))):
            out .append ('#EXT-X-DISCONTINUITY')
            inserted =True 
        out .append (line )
    if not inserted :
        return pl 
    return '\n'.join (out )+('\n'if pl .endswith ('\n')else '')
def fetch_upstream_engine_playlist(canonical: str, host: str, proto: str = 'http') -> str | None:
    if not engine_enabled:
        return None
    for endpoint in (f'/live/{canonical}.m3u8', f'/{canonical}.m3u8'):
        target = f'http://127.0.0.1:{engine_port}{endpoint}'
        try:
            # This is the configured local companion, never a URL supplied by the client.
            req = urllib.request.Request(target, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=2.0) as response:
                data = response.read(2 * 1024 * 1024 + 1)
                if len(data) > 2 * 1024 * 1024:
                    continue
                text = data.decode('utf-8')
                if response.status == 200 and text.lstrip().startswith('#EXTM3U'):
                    return render_media_playlist(text, response.geturl(), {'User-Agent': UA})
        except Exception:
            continue
    return None
# Operational features remain in this file so deployment needs only ysp-live.py.
import html
import io
import xml.etree.ElementTree as ET


def redact_diagnostic(value, secrets_to_hide=()):
    text = str(value)
    for secret in secrets_to_hide:
        if secret:
            text = text.replace(secret, '[hidden]')
    # Strip URLs completely: signed values and device IDs can also live in paths.
    text = re.sub(r'https?://[^\s<>\"\']+', '[url hidden]', text, flags=re.I)
    text = re.sub(r'(?i)\b(bearer)\s+\S+', r'\1 [hidden]', text)
    text = re.sub(r'''(?ix)(["']?\b(?:access_token|token|resource|authorization|cookie|uid|guid|android_id|androidid|device_id|deviceid|appid|apprandomstr|appsign|signature)["']?\s*[:=]\s*) (?:"[^"\n]*"|'[^'\n]*'|[^\s,;}]+)''', r'\1[hidden]', text)
    return text[:2000]


def validate_source_playlist(text, analysis=None):
    analysis = analysis or analyze_playlist(text)
    if analysis.validation_error:
        raise UnsafePlaylist(analysis.validation_error)
    return analysis


class SourceAttemptSuperseded(RuntimeError):
    """An in-flight attempt no longer belongs to the accepted source state."""


class SourceSelector:
    """Retain a working high-quality source; latency alone never causes a downgrade."""
    priority = ('device', 'backup', 'engine')

    def __init__(self, hold=30.0, clock=time.monotonic, policy='quality', validate_recovery=False):
        self.lock = threading.RLock()
        self.clock, self.hold = clock, hold
        self.policy, self.validate_recovery = policy, validate_recovery
        self.selected, self.since = '', 0.0
        self.states = {}

    def _state(self, source):
        return self.states.setdefault(source, dict(failures=0, successes=0, retry_at=0.0,
            latency_ms=None, last_ok=0.0, error='', signature=None, progress_at=0.0,
            recovery_samples=0, probe_at=0.0, probing=False, resolution=None,
            profile=StreamProfile(), profile_at=0.0, generation=0, validation_epoch=0,
            source_context='', discarded_attempts=0,
            content_probe_at=0.0, content_probing=False, content_result=None, content_verified_at=0.0))

    def _profile(self, source):
        state = self._state(source)
        return state['profile']

    def _profile_fresh(self, source):
        state = self._state(source)
        return bool(state['profile'].height and self.clock() - state['profile_at'] <= 60)

    def attempt_token(self, source):
        with self.lock:
            return self._state(source)['validation_epoch']

    @staticmethod
    def _clear_content(state):
        state['content_result'], state['content_verified_at'], state['content_probe_at'] = None, 0.0, 0.0
        state.pop('content_signature', None)
        state.pop('content_progress_at', None)

    def _better(self, candidate, current):
        a, b = self._profile(candidate), self._profile(current)
        if self.policy != 'stable' and a.height and b.height:
            if (a.height, a.width) != (b.height, b.width):
                preferred = (a.height, a.width) > (b.height, b.width) if self.policy == 'quality' else (a.height, a.width) < (b.height, b.width)
                return preferred and self._profile_fresh(candidate)
            if a.codecs and a.codecs == b.codecs and a.bandwidth and b.bandwidth and a.bandwidth != b.bandwidth:
                preferred = a.bandwidth > b.bandwidth if self.policy == 'quality' else a.bandwidth < b.bandwidth
                return preferred and self._profile_fresh(candidate)
        # Without comparable manifest evidence, retain the known service priority.
        return self.priority.index(candidate) < self.priority.index(current)

    def _recovered(self, source):
        state = self._state(source)
        if state['recovery_samples'] < 2:
            return False
        return not self.validate_recovery or (state['content_result'] and state['content_result'].get('ok') is True
                                             and self.clock() - state['content_verified_at'] <= 60)

    def order(self, available):
        with self.lock:
            now = self.clock()
            order = [s for s in self.priority if s in available and self._state(s)['retry_at'] <= now]
            current = self.selected
            if current in order:
                promoted = [s for s in order if s != current and self._better(s, current)
                            and self._recovered(s) and now - self.since >= self.hold]
                if len(promoted) > 1 and self._better(promoted[1], promoted[0]):
                    promoted.reverse()
                order = promoted + [current] + [s for s in order if s != current and s not in promoted]
            return order

    def success(self, source, playlist, elapsed, probe=False, expected_epoch=None, context=None):
        analysis = validate_source_playlist(playlist)
        signature, target, profile = analysis.signature, analysis.target, analysis.profile
        generation = 0
        uri = analysis.media.segments[-1].uri if analysis.media and analysis.media.segments else (analysis.variants[0].uri if analysis.variants else '')
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(uri).query)
        if urllib.parse.urlsplit(uri).path in ('/proxy', '/proxy.ts', '/engine_proxy') and query.get('resource'):
            try:
                generation = resolve_resource(query['resource'][0]).generation
            except ProxyError:
                pass
        now = self.clock()
        with self.lock:
            state = self._state(source)
            source_context = context if context is not None else (state['source_context'] or source)
            same_source = generation == state['generation'] and source_context == state['source_context']
            compatible_profile = not profile.height or not state['profile'].height or profile == state['profile']
            if expected_epoch is not None and expected_epoch != state['validation_epoch'] and (state['failures'] or not same_source or not compatible_profile):
                state['discarded_attempts'] += 1
                raise SourceAttemptSuperseded('source state changed while the playlist was loading')
            if generation and state['generation'] > generation:
                state['discarded_attempts'] += 1
                raise SourceAttemptSuperseded('older source generation completed after a newer generation')
            if not same_source:
                state['generation'], state['source_context'] = generation, source_context
                state['validation_epoch'] += 1
                self._clear_content(state)
                state['recovery_samples'], state['signature'], state['progress_at'] = 0, None, 0.0
                state['profile'], state['profile_at'], state['resolution'] = StreamProfile(), 0.0, None
            if profile.height and state['profile'].height and profile != state['profile']:
                state['validation_epoch'] += 1
                self._clear_content(state)
                state['recovery_samples'] = 0
            if state.get('latest_digest') != analysis.body_digest:
                state['latest_media'] = {segment.identity: segment.uri for segment in analysis.media.segments[-32:]} if analysis.media else {}
                state['latest_digest'] = analysis.body_digest
            if signature is not None:
                if signature != state['signature']:
                    state['progress_at'] = now
                    state['recovery_samples'] += 1
                elif now - state['progress_at'] > max(3 * target, 30):
                    raise FrozenPlaylistError('source probe: media stopped advancing')
            else:
                if not state.get('content_signature'):
                    state['recovery_samples'] = 0
            state['signature'] = signature
            state['successes'] += 1
            if state['failures']:
                state['validation_epoch'] += 1
                self._clear_content(state)
            state['failures'], state['retry_at'], state['error'] = 0, 0.0, ''
            state['last_ok'] = time.time()
            value = max(0, elapsed * 1000)
            state['latency_ms'] = value if state['latency_ms'] is None else .7 * state['latency_ms'] + .3 * value
            if profile.height or profile.bandwidth or profile.codecs:
                state['profile'], state['profile_at'] = profile, now
                state['resolution'] = profile.resolution
            return state['validation_epoch']

    def failure(self, source, error, expected_epoch=None):
        with self.lock:
            state = self._state(source)
            if expected_epoch is not None and expected_epoch != state['validation_epoch']:
                state['discarded_attempts'] += 1
                return False
            state['failures'] += 1
            self._clear_content(state)
            state['recovery_samples'], state['validation_epoch'] = 0, state['validation_epoch'] + 1
            state['retry_at'] = self.clock() + min(120, 5 * 2 ** min(state['failures'] - 1, 5))
            state['error'] = redact_diagnostic(error)
            return True

    def commit(self, source):
        with self.lock:
            if source != self.selected:
                self.selected, self.since = source, self.clock()
                for name, state in self.states.items():
                    if name != source:
                        state['recovery_samples'] = 0

    def reserve_probe(self, available):
        with self.lock:
            now = self.clock()
            if not self.selected or now - self.since < self.hold:
                return None
            candidates = [s for s in self.priority if s in available and s != self.selected
                          and (self.policy != 'stable' or self._better(s, self.selected))]
            candidates.sort(key=lambda source: (self._state(source)['probe_at'], self.priority.index(source)))
            for source in candidates:
                state = self._state(source)
                if not state['probing'] and now >= max(state['probe_at'], state['retry_at']):
                    state['probing'], state['probe_at'] = True, now + 30
                    return source
            return None

    def snapshot(self):
        with self.lock:
            now = self.clock()
            return {'selected': self.selected or None, 'policy': self.policy,
                    'stable_seconds': round(max(0, now - self.since)) if self.selected else 0,
                    'sources': {name: {'failures': s['failures'], 'successes': s['successes'],
                        'retry_in': round(max(0, s['retry_at'] - now), 1),
                        'latency_ms': round(s['latency_ms'], 1) if s['latency_ms'] is not None else None,
                        'last_success': s['last_ok'] or None, 'error': s['error'],
                        'recovery_samples': s['recovery_samples'], 'probing': s['probing'],
                        'playlist_resolution': self._profile(name).resolution,
                        'profile_fresh': self._profile_fresh(name),
                        'profile_age_seconds': round(max(0, now - s['profile_at'])) if self._profile(name).height else None,
                        'context': s['source_context'] or None, 'discarded_attempts': s['discarded_attempts'],
                        'declared_codecs': self._profile(name).codecs or None,
                        'declared_bandwidth': self._profile(name).bandwidth or None,
                        'segment_content': s['content_result'], 'content_probing': s['content_probing']}
                        for name, s in self.states.items()}}


feature_pool = ThreadPoolExecutor(max_workers=2, max_queue=8, thread_name_prefix='source-probe')
diagnostic_pool = ThreadPoolExecutor(max_workers=1, max_queue=4, thread_name_prefix='diagnose')
diagnostic_lock = threading.Lock()
diagnostic_jobs = {}
epg_manager = None
media_probe_manager = None
playback_policy = 'quality'


def channel_selector(ch):
    with ch.lock:
        if not hasattr(ch, 'selector'):
            ch.selector = SourceSelector(policy=playback_policy, validate_recovery=media_probe_manager is not None)
            ch.selector.channel = ch.slug
        return ch.selector


def source_loaders(ch, origin, head_only=False):
    parsed = urllib.parse.urlsplit(origin)
    loaders = {}
    if ch.slug in active_backend_channels and resolver_ready() and resolver:
        def device():
            if resolver.is_channel_in_cooldown(ch.slug):
                raise RuntimeError('device source is cooling down')
            method = getattr(resolver, 'fetch_channel_playlist_bounded', resolver.fetch_channel_playlist)
            return method(ch.slug, parsed.netloc, parsed.scheme), 'device', {}
        loaders['device'] = device

    def load_backup(probe=False):
        now = time.time()
        with ch.lock:
            cached, age = ch.last_built_playlist, now - ch.last_built_time
            source = getattr(ch, 'last_built_source', 'backup:' + ch.mode)
        if cached and age < 15 and '#EXTM3U' in cached:
            if age > 6 and not head_only and not probe:
                trigger_background_refresh(ch)
            return cached, source, {'X-SWR': 'HIT'}
        if not head_only:
            if probe:
                coalesce_refresh(ch.slug, lambda: _refresh_and_build(ch), timeout=5.0)
            else:
                ensure_channel(ch)
        playlist = build_playlist(ch, holdback=True)
        return playlist, getattr(ch, 'last_built_source', 'backup:' + ch.mode), {}
    def backup():
        return load_backup()
    backup.probe = lambda: load_backup(True)
    loaders['backup'] = backup
    if engine_enabled:
        loaders['engine'] = lambda: (fetch_upstream_engine_playlist(ch.slug, parsed.netloc, parsed.scheme), 'engine', {})
    def quality_loader(load):
        def wrapped():
            playlist, label, extra = load()
            return filter_master_quality(playlist, ch.defn) if playlist else playlist, label, extra
        return wrapped
    for name, load in list(loaders.items()):
        wrapped = quality_loader(load)
        wrapped.probe = quality_loader(getattr(load, 'probe', load))
        loaders[name] = wrapped
    return loaders


def playback_resource(uri, base='', headers=None):
    """Resolve gateway capabilities locally; never request our own public HTTP endpoint."""
    absolute = urllib.parse.urljoin(base, uri)
    parsed = urllib.parse.urlsplit(absolute)
    query = urllib.parse.parse_qs(parsed.query)
    if parsed.path in ('/proxy', '/proxy.ts', '/engine_proxy') and query.get('resource'):
        return resolve_resource(query['resource'][0])
    safe_headers = dict(headers or {})
    if base and urllib.parse.urlsplit(base).netloc != parsed.netloc:
        safe_headers = {k: v for k, v in safe_headers.items() if k.lower() not in SENSITIVE}
    return Resource(absolute, safe_headers)


def content_request_headers(headers):
    result = dict(headers)
    existing = {key.lower() for key in result}
    if 'user-agent' not in existing:
        result['User-Agent'] = 'qqlive'
    if 'referer' not in existing:
        result['Referer'] = 'https://live.cctv.cn/'
    return result


def classify_media_prefix(body, encrypted=False):
    prefix = body.lstrip(b'\xef\xbb\xbf \r\n\t')
    if not body:
        return False, 'empty'
    lower = prefix[:128].lower()
    if lower.startswith((b'<!doctype html', b'<html', b'<head', b'<body', b'<?xml', b'<error')):
        return False, 'error_document'
    if lower.startswith((b'{', b'[')) and re.search(rb'"(?:error|message|code|status)"\s*:', lower):
        return False, 'error_json'
    if encrypted:
        return True, 'encrypted_nonempty'
    for offset in range(min(188, max(0, len(body) - 376))):
        if body[offset] == body[offset + 188] == body[offset + 376] == 0x47:
            return True, 'mpegts_prefix'
    if len(body) >= 8 and body[4:8] in (b'ftyp', b'styp', b'moof', b'mdat', b'sidx', b'free'):
        size = int.from_bytes(body[:4], 'big')
        if size == 0 or size == 1 or size >= 8:
            return True, 'isobmff_prefix'
    if body.startswith(b'ID3') or (len(body) > 2 and body[0] == 255 and body[1] & 0xF6 == 0xF0):
        return True, 'audio_prefix'
    return None, 'opaque_unverified'


def probe_playlist_content(playlist, origin='', policy=None, proxy=None, max_bytes=65536, timeout=3):
    """Read a bounded prefix, not a full segment or decoded frame. No unbounded GET fallback."""
    max_bytes = max(564, min(65536, int(max_bytes)))
    policy = policy or URLPolicy(engine_port=engine_port)
    started, deadline = time.monotonic(), time.monotonic() + timeout
    text, base, headers = playlist, origin, {}
    analysis = analyze_playlist(text)
    sampled_profile = analysis.profile
    for _ in range(3):
        if analysis.media is not None:
            break
        if not analysis.variants:
            return {'ok': None, 'kind': 'master_unverified', 'sampled_bytes': 0, 'decode_verified': False}
        variant = max(analysis.variants, key=lambda v: (v.profile.height, v.profile.width, v.profile.bandwidth))
        sampled_profile = variant.profile
        resource = playback_resource(variant.uri, base, headers)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProxyError(504, 'content probe deadline exceeded')
        status, _, body, effective = fetch_bytes(resource.url, content_request_headers(resource.headers), policy=policy,
                                                timeout=remaining, max_bytes=256 * 1024, deadline=deadline)
        if status != 200:
            raise ProxyError(status, 'probe media playlist HTTP ' + str(status), category='upstream_status')
        text, base, headers = body.decode('utf-8', 'strict'), effective, resource.headers
        analysis = analyze_playlist(text)
    if analysis.media is None or not analysis.media.segments:
        return {'ok': None, 'kind': 'no_media_segment', 'sampled_bytes': 0, 'decode_verified': False}
    segment = analysis.media.segments[-2] if len(analysis.media.segments) >= 3 else analysis.media.segments[-1]
    resource = playback_resource(segment.uri, base, headers)
    offset, length = 0, max_bytes
    if segment.byte_range:
        match = re.fullmatch(r'(\d+)@(\d+)', segment.byte_range)
        if not match:
            return {'ok': None, 'kind': 'unknown_byte_range', 'sampled_bytes': 0, 'decode_verified': False}
        length, offset = min(max_bytes, int(match[1])), int(match[2])
        if length <= 0:
            raise ProxyError(502, 'invalid segment byte range')
    encrypted = bool(segment.key and attributes(segment.key).get('METHOD', 'NONE') != 'NONE')
    cached = proxy.cached_prefix(resource.url, resource.headers, offset, length) if proxy else None
    remote = None
    from_cache = cached is not None
    try:
        if cached is not None:
            body = cached
            if segment.byte_range and len(body) < length:
                raise ProxyError(502, 'truncated cached byte range')
        else:
            request_headers = content_request_headers(resource.headers)
            request_headers['Range'] = f'bytes={offset}-{offset + length - 1}'
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProxyError(504, 'content probe deadline exceeded')
            remote = open_remote(resource.url, request_headers, method='GET', policy=policy,
                                 timeout=remaining, deadline=deadline)
            if remote.status in (403, 405, 416) and not offset:
                # Some live CDNs reject Range but serve ordinary GET. The read cap remains unchanged.
                _safe_close(remote)
                remote = None
                request_headers.pop('Range', None)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ProxyError(504, 'content probe deadline exceeded')
                remote = open_remote(resource.url, request_headers, method='GET', policy=policy,
                                     timeout=remaining, deadline=deadline)
            if remote.status not in (200, 206):
                raise ProxyError(remote.status, 'segment content HTTP ' + str(remote.status), category='upstream_status')
            if remote.headers.get('content-encoding', 'identity').lower() not in ('', 'identity'):
                return {'ok': None, 'kind': 'unexpected_content_encoding', 'sampled_bytes': 0, 'decode_verified': False}
            if remote.status == 206:
                content_range = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+|\*)', remote.headers.get('content-range', ''))
                if not content_range or int(content_range[1]) != offset or not offset <= int(content_range[2]) <= offset + length - 1:
                    raise ProxyError(502, 'invalid probe content range')
            elif offset:
                return {'ok': None, 'kind': 'byte_range_ignored', 'sampled_bytes': 0, 'decode_verified': False}
            chunks, total, eof = [], 0, False
            while total < length:
                if time.monotonic() >= deadline:
                    raise ProxyError(504, 'content probe deadline exceeded')
                chunk = remote.read(length - total)
                if not chunk:
                    eof = True
                    break
                chunks.append(chunk)
                total += len(chunk)
            body = b''.join(chunks)
            expected = remote.headers.get('content-length')
            if expected is not None:
                try:
                    expected = int(expected)
                except ValueError:
                    raise ProxyError(502, 'invalid probe content length')
                if remote.status == 206 and expected != int(content_range[2]) - offset + 1:
                    raise ProxyError(502, 'inconsistent probe byte range length')
                if expected < 0 or total > expected or (eof and total != expected):
                    raise ProxyError(502, 'truncated probe response')
            if remote.status == 206 and len(body) < min(length, int(content_range[2]) - offset + 1):
                raise ProxyError(502, 'truncated probe byte range')
        ok, kind = classify_media_prefix(body, encrypted)
        return {'ok': ok, 'kind': kind, 'sampled_bytes': len(body), 'from_cache': from_cache,
                'elapsed_ms': round((time.monotonic() - started) * 1000), 'decode_verified': False,
                'media_signature': analysis.signature, 'target_duration': analysis.target,
                'master': analyze_playlist(playlist).media is None,
                'declared_profile': dataclasses.asdict(sampled_profile)}
    finally:
        _safe_close(remote)


class MediaProbeManager:
    """Bounded content work with epoch-safe commit and cancellation cleanup."""
    def __init__(self, interval=30, proxy=None):
        self.interval, self.proxy = max(10, interval), proxy
        self.pool = ThreadPoolExecutor(max_workers=2, max_queue=8, thread_name_prefix='media-probe')
        self.lock = threading.Lock()
        self.closed, self.pending = False, {}
        self.scheduled = self.completed = self.failed = self.cached = self.dropped = self.sampled_bytes = 0
        self.cancelled = self.ignored = self.inconclusive = 0

    def stats(self):
        with self.lock:
            return {'enabled': not self.closed, 'scheduled': self.scheduled, 'completed': self.completed,
                    'failed': self.failed, 'cached': self.cached, 'dropped': self.dropped,
                    'cancelled': self.cancelled, 'ignored': self.ignored, 'inconclusive': self.inconclusive,
                    'pending': len(self.pending), 'sampled_bytes': self.sampled_bytes,
                    'interval_seconds': self.interval, 'max_sample_bytes': 65536}

    def schedule(self, selector, source, playlist, origin):
        token = object()
        with selector.lock:
            state = selector._state(source)
            now = selector.clock()
            if state['content_probing'] or now < state['content_probe_at']:
                return
            with self.lock:
                if self.closed:
                    return
                self.pending[token] = None
                self.scheduled += 1
            epoch = state['validation_epoch']
            state['content_probing'], state['content_probe_at'], state['content_job_token'] = True, now + self.interval, token

        def cleanup(future=None):
            with selector.lock:
                state = selector._state(source)
                if state.get('content_job_token') is token:
                    state['content_probing'] = False
                    state.pop('content_job_token', None)
            with self.lock:
                self.pending.pop(token, None)
                if future is not None and future.cancelled():
                    self.cancelled += 1

        analysis = analyze_playlist(playlist)
        sampled = None
        if analysis.media and analysis.media.segments:
            segment = analysis.media.segments[-2] if len(analysis.media.segments) >= 3 else analysis.media.segments[-1]
            sampled = segment.identity, segment.uri

        def run():
            with self.lock:
                if self.closed:
                    self.completed += 1
                    self.ignored += 1
                    return
            hard_error, feedback = None, None
            try:
                result = probe_playlist_content(playlist, origin,
                    policy=self.proxy.policy if self.proxy else None, proxy=self.proxy)
                if result['ok'] is False:
                    hard_error = 'segment content: ' + result['kind']
            except Exception as exc:
                status, category = getattr(exc, 'status', None), getattr(exc, 'category', '')
                dns_failure = isinstance(getattr(exc, '__cause__', None), DNSLookupError)
                definite = status in (401, 403, 404, 410, 502) and not dns_failure and category != 'target_policy'
                hard_error = str(exc) if definite else None
                result = {'ok': False if hard_error else None, 'kind': 'probe_failed' if hard_error else 'probe_inconclusive',
                          'error': redact_diagnostic(type(exc).__name__ + ': ' + str(exc)),
                          'sampled_bytes': 0, 'decode_verified': False, 'status': status, 'category': category}
            result['checked_at'] = time.time()
            # No socket operations happen under either lock. Closing and publishing a
            # result use the same ordering, so close cannot be followed by a stale commit.
            with selector.lock:
                state = selector._state(source)
                with self.lock:
                    self.completed += 1
                    self.cached += bool(result.get('from_cache'))
                    self.sampled_bytes += result.get('sampled_bytes', 0)
                    superseded_segment = hard_error and sampled is not None and 'latest_media' in state and state['latest_media'].get(sampled[0]) != sampled[1]
                    if self.closed or state['validation_epoch'] != epoch or superseded_segment:
                        self.ignored += 1
                        return
                    if result.get('declared_profile'):
                        profile = StreamProfile(**result['declared_profile'])
                        if profile.height or profile.bandwidth or profile.codecs:
                            state['profile'], state['profile_at'] = profile, selector.clock()
                    if result.get('master') and result['ok'] is True and result.get('media_signature'):
                        signature = result['media_signature']
                        if signature != state.get('content_signature'):
                            state['recovery_samples'] += 1
                            state['content_signature'], state['content_progress_at'] = signature, selector.clock()
                        elif selector.clock() - state.get('content_progress_at', selector.clock()) > max(30, result['target_duration'] * 3):
                            hard_error = 'master media stopped advancing'
                            result['ok'], result['kind'] = False, 'media_frozen'
                    if hard_error:
                        if source == 'device' and result.get('category') == 'upstream_status' and result.get('status') in (401, 403, 404) and getattr(selector, 'channel', None):
                            feedback = selector.channel, state['generation'], result['status']
                        selector.failure(source, hard_error)
                    state['content_result'] = result
                    if result['ok'] is True:
                        state['content_verified_at'] = selector.clock()
                    self.failed += bool(hard_error)
                    self.inconclusive += result['ok'] is None
            if feedback and resolver and not shutdown_event.is_set():
                resolver.record_segment_failure(*feedback)

        try:
            future = self.pool.submit(run)
            with self.lock:
                if token in self.pending:
                    self.pending[token] = future
            future.add_done_callback(cleanup)
        except RuntimeError:
            cleanup()
            with self.lock:
                self.dropped += 1
                self.scheduled -= 1

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)


def schedule_source_probe(selector, loaders, origin=''):
    if shutdown_event.is_set():
        return
    source = selector.reserve_probe(loaders)
    if source is None:
        return
    epoch = selector.attempt_token(source)
    def cleanup(_=None):
        with selector.lock:
            selector._state(source)['probing'] = False
    def probe():
        started, accepted_epoch = time.monotonic(), epoch
        try:
            loader = loaders[source]
            playlist, label, _ = getattr(loader, 'probe', loader)()
            if not playlist:
                raise RuntimeError('empty source playlist')
            accepted_epoch = selector.success(source, playlist, time.monotonic() - started,
                probe=True, expected_epoch=epoch, context=label)
            if media_probe_manager:
                media_probe_manager.schedule(selector, source, playlist, origin)
        except SourceAttemptSuperseded:
            pass
        except Exception as exc:
            selector.failure(source, type(exc).__name__ + ': ' + str(exc), expected_epoch=accepted_epoch)
    try:
        future = feature_pool.submit(probe)
        future.add_done_callback(cleanup)
    except RuntimeError:
        cleanup()


def channel_status():
    now = time.time()
    result = []
    for meta in global_channel_dir.unique_channels():
        ch = CHANNEL_MAP.get(meta['slug'])
        row = {'slug': meta['slug'], 'name': meta['name'], 'group': meta['group'],
               'catchup_supported': meta['slug'] in TIMESHIFT_SUPPORTED,
               'catchup_limit_days': 7, 'catchup_verified': False,
               'source': None, 'state': 'unobserved', 'last_success': None,
               'last_progress': None, 'error': '', 'selection': {'sources': {}}}
        if ch:
            with ch.lock:
                publication = ch._publication
                row.update(source=publication['source'] if publication else None,
                    last_success=ch.last_fetch_success_at or None,
                    last_progress=ch.last_media_advance_at or None,
                    error=redact_diagnostic(ch.last_error), source_epoch=ch.source_epoch,
                    restart_required=ch.source_restart_required)
                published_progress = ch._media_progress.get('published-' + publication['source']) if publication else None
                if publication:
                    row['last_progress'] = published_progress[1] if published_progress else None
                if row['last_progress']:
                    row['state'] = 'ready' if now - row['last_progress'] < 60 else 'stale'
                elif row['last_success']:
                    row['state'] = 'playlist_only'
                selector = getattr(ch, 'selector', None)
            if selector is not None:
                row['selection'] = selector.snapshot()
                selected = row['selection']['selected']
                selected_state = row['selection']['sources'].get(selected, {})
                row['last_success'] = selected_state.get('last_success') or row['last_success']
                if row['state'] == 'unobserved' and row['last_success']:
                    row['state'] = 'playlist_only'
                if selected_state.get('failures'):
                    row['state'] = 'degraded'
        result.append(row)
    return result


def diagnostics_snapshot(secret=''):
    with _log_lock:
        logs = [redact_diagnostic(re.sub(r'\033\[[0-9;]*m', '', line), (secret,))
                for line in list(global_log_ring)[-30:]]
    data = {'version': __version__, 'uptime_seconds': int(time.time() - server_start_time),
            'device_ready': resolver_ready(), 'media': media_proxy.stats(),
            'channels': channel_status(), 'analysis_cache': playlist_analysis_cache.stats(), 'playback_policy': playback_policy,
            'media_probe': media_probe_manager.stats() if media_probe_manager else {'enabled': False}, 'epg': epg_manager.stats() if epg_manager else {'enabled': False},
            'logs': logs}
    # Also scrub errors nested in per-channel/source snapshots.
    return json.loads(redact_json(data, secret))


def redact_json(value, secret=''):
    def scrub(item):
        if isinstance(item, dict):
            return {k: scrub(v) for k, v in item.items()}
        if isinstance(item, (list, tuple)):
            return [scrub(v) for v in item]
        return redact_diagnostic(item, (secret,)) if isinstance(item, str) else item
    return json.dumps(scrub(value), ensure_ascii=False)


def start_channel_diagnostic(ch, origin):
    """Explicit user-triggered probe; reports each layer without publishing a timeline."""
    now = time.monotonic()
    with diagnostic_lock:
        existing = diagnostic_jobs.get(ch.slug)
        if existing and (existing['running'] or now - existing['_created'] < 30):
            return {k: list(v) if k == 'steps' else v for k, v in existing.items() if not k.startswith('_')}
        job = {'channel': ch.slug, 'running': True, 'started': time.time(), 'steps': [], '_created': now}
        diagnostic_jobs[ch.slug] = job
    def append_step(**step):
        with diagnostic_lock:
            job['steps'].append(step)
    def run():
        try:
            for source, load in source_loaders(ch, origin).items():
                if shutdown_event.is_set():
                    break
                started = time.monotonic()
                try:
                    playlist, _, _ = getattr(load, 'probe', load)()
                    if not playlist or '#EXTM3U' not in playlist:
                        raise RuntimeError('no HLS playlist')
                    media = parse_media(playlist)
                    append_step(source=source, layer='playlist', ok=True,
                                elapsed_ms=round((time.monotonic() - started) * 1000),
                                segments=len(media.segments) if media else 0)
                    if not media or not media.segments:
                        result = probe_playlist_content(playlist, origin, policy=media_proxy.policy, proxy=media_proxy)
                        append_step(source=source, layer='segment_content', **result)
                        continue
                    target = media.segments[-1].uri
                    resource = playback_resource(target, origin)
                    media_proxy.policy.resolve(resource.url)
                    append_step(source=source, layer='dns_policy', ok=True)
                    result = probe_playlist_content(playlist, origin, policy=media_proxy.policy, proxy=media_proxy)
                    append_step(source=source, layer='segment_content', **result)
                except Exception as exc:
                    append_step(source=source, layer='probe', ok=False,
                                error=redact_diagnostic(type(exc).__name__ + ': ' + str(exc)))
        finally:
            with diagnostic_lock:
                job['running'], job['finished'] = False, time.time()
    try:
        diagnostic_pool.submit(run)
    except RuntimeError:
        with diagnostic_lock:
            job['running'] = False
            job['steps'].append({'layer': 'queue', 'ok': False, 'error': 'diagnostic queue is full'})
    with diagnostic_lock:
        return {k: list(v) if k == 'steps' else v for k, v in job.items() if not k.startswith('_')}


def epg_timestamp(value):
    match = re.fullmatch(r'(\d{14})(?:\s*([+-]\d{4}|Z))?', value.strip())
    if not match:
        raise ValueError('invalid XMLTV time')
    zone = match[2] or '+0000'
    if zone == 'Z':
        zone = '+0000'
    return int(datetime.datetime.strptime(match[1] + ' ' + zone, '%Y%m%d%H%M%S %z').timestamp())


class EPGCache:
    max_download, max_xml, max_items = 8 * 2**20, 32 * 2**20, 60000

    def __init__(self, urls=(), path='', ttl=3600, fetcher=None):
        self.urls, self.path, self.ttl = tuple(urls), path, ttl
        self.fetcher = fetcher or self._fetch
        self.lock = threading.RLock()
        self.programmes, self.updated, self.error = (), 0.0, ''
        self._xml_bytes = None
        self.loading, self.retry_at, self.closed = False, 0.0, False
        self.pool = ThreadPoolExecutor(max_workers=1, max_queue=1, thread_name_prefix='epg-refresh')
        if self.path and self.urls:
            try:
                if os.path.getsize(self.path) <= self.max_xml:
                    with open(self.path, encoding='utf-8') as stream:
                        cached = json.load(stream)
                    programmes = self._validate(cached['programmes'])
                    updated = float(cached['updated'])
                    if math.isfinite(updated) and 0 < updated <= time.time():
                        self.programmes, self.updated = programmes, updated
            except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
                pass

    def _validate(self, programmes):
        if not isinstance(programmes, list) or len(programmes) > self.max_items:
            raise ValueError('EPG programme limit exceeded')
        known = {m['slug'] for m in global_channel_dir.unique_channels()}
        now = time.time()
        result = []
        for item in programmes:
            if not isinstance(item, dict):
                raise ValueError('invalid cached programme')
            start, stop = int(item['start']), int(item['stop'])
            if item['channel'] in known and now - 7 * 86400 <= start <= now + 2 * 86400 and start < stop <= start + 86400:
                result.append({'channel': item['channel'], 'start': start, 'stop': stop,
                               'title': str(item['title'])[:512], 'description': str(item.get('description', ''))[:2048]})
        return tuple(sorted(result, key=lambda p: (p['channel'], p['start'])))

    def _fetch(self, url):
        parsed = urllib.parse.urlsplit(url)
        policy = URLPolicy(allowed_suffixes=(parsed.hostname,))
        status, _, body, _ = fetch_bytes(url, policy=policy, timeout=10, max_bytes=self.max_download)
        if status != 200:
            raise ValueError('EPG HTTP ' + str(status))
        return body

    def parse(self, body):
        if len(body) > self.max_download:
            raise ValueError('EPG download too large')
        if body.startswith(b'\x1f\x8b'):
            with gzip.GzipFile(fileobj=io.BytesIO(body)) as stream:
                body = stream.read(self.max_xml + 1)
        if len(body) > self.max_xml:
            raise ValueError('EPG XML too large')
        if b'<!DOCTYPE' in body.upper() or b'<!ENTITY' in body.upper():
            raise ValueError('EPG DTD/entities are not supported')
        # XMLTV is UTF-8; rejecting NUL also prevents UTF-16 from bypassing the declaration check.
        if b'\x00' in body:
            raise ValueError('EPG must use UTF-8 XML')
        aliases = {}
        for meta in global_channel_dir.unique_channels():
            for alias in (meta['slug'], meta['name'], meta['tvg_id']):
                aliases[re.sub(r'[\s_-]', '', alias).casefold()] = meta['slug']
        def match(value):
            return aliases.get(re.sub(r'[\s_-]', '', value).casefold())
        ids, programmes = {}, []
        count, text_bytes = 0, 0
        root = None
        for event, element in ET.iterparse(io.BytesIO(body), events=('start', 'end')):
            if root is None:
                root = element
                if element.tag != 'tv':
                    raise ValueError('not an XMLTV document')
            if event != 'end':
                continue
            count += 1
            if count > 500000:
                raise ValueError('EPG element limit exceeded')
            if element.tag == 'channel':
                identifier = element.get('id', '')
                slug = match(identifier)
                for display in element.findall('display-name'):
                    slug = slug or match(display.text or '')
                if slug:
                    ids[identifier] = slug
                element.clear()
                root.clear()
            elif element.tag == 'programme':
                slug = ids.get(element.get('channel', '')) or match(element.get('channel', ''))
                if slug:
                    try:
                        start = epg_timestamp(element.get('start', ''))
                        stop = epg_timestamp(element.get('stop', ''))
                        now = time.time()
                        if now - 7 * 86400 <= start <= now + 2 * 86400 and start < stop <= start + 86400:
                            title = (element.findtext('title') or '未命名节目')[:512]
                            description = (element.findtext('desc') or '')[:2048]
                            text_bytes += len((title + description).encode('utf-8'))
                            if len(programmes) >= self.max_items or text_bytes > 12 * 2**20:
                                raise OverflowError('EPG programme/text budget exceeded')
                            programmes.append(dict(channel=slug, start=start, stop=stop, title=title, description=description))
                    except ValueError:
                        pass
                element.clear()
                root.clear()
        if not programmes:
            raise ValueError('EPG contains no matching programmes in the supported time window')
        unique = {(p['channel'], p['start'], p['stop']): p for p in programmes}
        return tuple(sorted(unique.values(), key=lambda p: (p['channel'], p['start'])))

    def request_refresh(self):
        with self.lock:
            now = time.time()
            if self.closed or not self.urls or self.loading or now < self.retry_at or (self.updated and now - self.updated < self.ttl):
                return
            self.loading = True
        def refresh():
            try:
                last_error = ''
                for url in self.urls:
                    try:
                        programmes = self.parse(self.fetcher(url))
                        updated = time.time()
                        with self.lock:
                            if self.closed:
                                return
                            self.programmes, self.updated, self.error = programmes, updated, ''
                            self._xml_bytes = None
                        if self.path:
                            try:
                                atomic_json_write(self.path, {'updated': updated, 'programmes': programmes})
                            except Exception as exc:
                                with self.lock:
                                    self.error = 'EPG cache persistence: ' + redact_diagnostic(type(exc).__name__ + ': ' + str(exc))
                        return
                    except Exception as exc:
                        last_error = redact_diagnostic(type(exc).__name__ + ': ' + str(exc))
                with self.lock:
                    self.error, self.retry_at = last_error, time.time() + 60
            finally:
                with self.lock:
                    self.loading = False
        try:
            self.pool.submit(refresh)
        except RuntimeError:
            with self.lock:
                self.loading = False
                self.retry_at, self.error = time.time() + 60, 'EPG worker unavailable'

    def stats(self):
        with self.lock:
            return {'enabled': bool(self.urls), 'loading': self.loading, 'updated': self.updated or None,
                    'stale': bool(self.updated and time.time() - self.updated >= self.ttl),
                    'programmes': len(self.programmes), 'error': self.error}

    def read(self, slug):
        with self.lock:
            now = time.time()
            return [dict(p) for p in self.programmes if p['channel'] == slug and p['stop'] >= now - 7 * 86400][-500:]

    def xml(self):
        with self.lock:
            if self._xml_bytes is not None:
                return self._xml_bytes
            programmes, updated = self.programmes, self.updated
        root = ET.Element('tv', {'generator-info-name': 'ysp-live'})
        metas = {m['slug']: m for m in global_channel_dir.unique_channels()}
        for slug in sorted({p['channel'] for p in programmes}):
            channel = ET.SubElement(root, 'channel', {'id': metas[slug]['tvg_id']})
            ET.SubElement(channel, 'display-name').text = metas[slug]['name']
        for item in programmes:
            if item['channel'] not in metas:
                continue
            attrs = {'channel': metas[item['channel']]['tvg_id']}
            for name, key in (('start', 'start'), ('stop', 'stop')):
                attrs[name] = datetime.datetime.fromtimestamp(item[key], datetime.timezone.utc).strftime('%Y%m%d%H%M%S +0000')
            programme = ET.SubElement(root, 'programme', attrs)
            ET.SubElement(programme, 'title').text = item['title']
            if item['description']:
                ET.SubElement(programme, 'desc').text = item['description']
        body = ET.tostring(root, encoding='utf-8', xml_declaration=True)
        with self.lock:
            if self.updated == updated:
                self._xml_bytes = body
        return body

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)


def catchup_link(slug, start, stop, origin, token=''):
    if slug not in TIMESHIFT_SUPPORTED:
        return None
    now = int(time.time())
    stop = min(stop, now)
    if not now - 7 * 86400 <= start < stop or stop - start > 86400:
        return None
    params = {'start': str(start), 'end': str(stop)}
    if token:
        params['access_token'] = token
    return origin + '/' + slug + '.m3u8?' + urllib.parse.urlencode(params)


STATUS_PAGE = r'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YSP 频道状态</title>
<style nonce="__NONCE__">body{font:15px system-ui,sans-serif;background:#f4f6fa;color:#17233a;max-width:1200px;margin:24px auto;padding:0 16px}h1{font-size:25px}section{background:white;padding:18px;margin:16px 0;border-radius:12px}input,select,button,a.action{font:inherit;padding:7px;margin:4px;border:1px solid #b9c7df;border-radius:6px}button,a{cursor:pointer;color:#2154ad}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:10px;border-bottom:1px solid #edf0f5}.scroll{overflow:auto}small,.muted{color:#596a83}#notice{white-space:pre-wrap}pre{white-space:pre-wrap;overflow-wrap:anywhere}.ready{color:#16733e}.stale,.degraded{color:#ac4b13}#token{max-width:190px}a{overflow-wrap:anywhere}</style>
<h1>YSP 频道状态</h1><p class="muted">状态来自播放观测；分辨率仅显示主列表声明，不代表实际解码画质。回看入口是否可播需由上游确认。</p>
<section><input id="token" type="password" autocomplete="off" placeholder="访问令牌（如已启用）"><button id="connect">连接 / 刷新</button><button id="export">下载脱敏诊断</button><a id="subscribe">频道订阅</a><p id="summary">正在读取状态…</p><div id="notice" role="status"></div></section>
<section><input id="search" placeholder="搜索频道"><div class="scroll"><table><thead><tr><th>频道</th><th>状态</th><th>当前来源</th><th>列表声明 / 请求耗时</th><th>内容检测</th><th>最近推进</th><th>操作</th></tr></thead><tbody id="channels"></tbody></table></div></section>
<section><h2 id="epgtitle">节目单与回看</h2><p id="epgstate">选择一个频道查看节目。</p><div class="scroll"><table><tbody id="programmes"></tbody></table></div><p>手动回看（按浏览器本地时区）：</p><select id="channel"></select><input id="start" type="datetime-local"><input id="end" type="datetime-local"><button id="catchup">生成回看链接</button><div id="catchuplink"></div></section>
<section><h2>主动诊断</h2><p class="muted">点击频道的“诊断”会请求播放源并限量读取分片内容（最多64 KiB），不验证实际解码。</p><pre id="diagnosis">尚未执行。</pre></section>
<script nonce="__NONCE__">'use strict';
const $=id=>document.getElementById(id),q=new URLSearchParams(location.search);let stored='';try{stored=sessionStorage.getItem('ysp-token')||''}catch(e){}let token=q.get('access_token')||stored,selected='',pollTimer=null,refreshing=false;
$('token').value=token;if(q.has('access_token'))history.replaceState(null,'',location.pathname);
const states={ready:'正常推进',stale:'已过期 / 停滞',unobserved:'未观测',playlist_only:'仅确认列表',degraded:'正在降级'};
function link(path){const u=new URL(path,location.origin);if(token)u.searchParams.set('access_token',token);return u.href}
async function api(path){const r=await fetch(path,{headers:token?{Authorization:'Bearer '+token}:{},cache:'no-store'});if(!r.ok)throw Error(r.status===401?'需要有效访问令牌':await r.text());return r.json()}
function cell(tr,value){const td=document.createElement('td');td.textContent=value;tr.append(td);return td}
function action(td,label,callback){const b=document.createElement('button');b.textContent=label;b.onclick=callback;td.append(b)}
function anchor(td,label,url){const a=document.createElement('a');a.textContent=label;a.href=url;td.append(a)}
function ago(t){return t?Math.max(0,Math.round(Date.now()/1000-t))+' 秒前':'未观测'}
async function refresh(){if(refreshing)return;refreshing=true;try{const data=await api('/api/channels');$('notice').textContent='';$('summary').textContent=`${data.channels.length} 个频道 · ${{quality:'画质优先',stable:'稳定优先',bandwidth:'节省流量'}[data.playback_policy]||'画质优先'} · 正常推进 ${data.channels.filter(c=>c.state==='ready').length} 个 · EPG ${data.epg.enabled?(data.epg.loading?'更新中':data.epg.programmes+' 个节目'):'未启用'}`;$('subscribe').href=link('/all.m3u');const filter=$('search').value.toLowerCase(),old=$('channel').value;$('channels').replaceChildren();$('channel').replaceChildren();for(const ch of data.channels){if(ch.catchup_supported){const o=document.createElement('option');o.value=ch.slug;o.textContent=ch.name;$('channel').append(o)}if(!(ch.name+' '+ch.slug).toLowerCase().includes(filter))continue;const tr=document.createElement('tr');cell(tr,ch.name);cell(tr,states[ch.state]||ch.state).className=ch.state;cell(tr,ch.source||'未选择');const s=ch.selection.sources[ch.selection.selected]||{};cell(tr,(s.playlist_resolution?(s.playlist_resolution+(s.profile_fresh===false?'（旧声明）':'')):'未观测')+' / '+(s.latency_ms==null?'—':s.latency_ms+' ms'));const check=s.segment_content;cell(tr,s.content_probing?'检测中':!check?'未检测':check.ok===true?'内容前缀可用':check.ok===false?'内容异常':'未确认');cell(tr,ago(ch.last_progress));const td=cell(tr,'');action(td,'节目',()=>showEPG(ch.slug,ch.name));action(td,'诊断',()=>diagnose(ch.slug));anchor(td,'直播',link('/'+ch.slug+'.m3u8'));$('channels').append(tr)}if(old)$('channel').value=old;if(selected)await showEPG(selected)}catch(e){$('notice').textContent=e.message}finally{refreshing=false}}
async function showEPG(slug,name){selected=slug;if(name)$('epgtitle').textContent=name+' · 节目单与回看';try{const data=await api('/api/epg?channel='+encodeURIComponent(slug));$('epgstate').textContent=!data.enabled?'EPG 未启用':data.loading?'节目单正在后台更新，请稍后刷新':data.error?'更新失败，保留旧缓存：'+data.error:data.programmes.length?'显示缓存节目；回看范围是本地校验上限，不代表上游保证。':'暂无匹配节目';if(data.current)$('epgstate').textContent+=' · 正在播：'+data.current.title;if(data.next)$('epgstate').textContent+=' · 接下来：'+data.next.title;$('programmes').replaceChildren();for(const p of data.programmes){const tr=document.createElement('tr');cell(tr,new Date(p.start*1000).toLocaleString()+' — '+new Date(p.stop*1000).toLocaleTimeString());cell(tr,p.title);const td=cell(tr,'');if(p.catchup_url)anchor(td,'从头回看',p.catchup_url);$('programmes').append(tr)}}catch(e){$('epgstate').textContent=e.message}}
async function diagnose(slug){clearTimeout(pollTimer);try{const d=await api('/api/diagnose?channel='+encodeURIComponent(slug));$('diagnosis').textContent=JSON.stringify(d,null,2);if(d.running)pollTimer=setTimeout(()=>diagnose(slug),1500)}catch(e){$('diagnosis').textContent=e.message}}
$('connect').onclick=()=>{token=$('token').value.trim();try{sessionStorage.setItem('ysp-token',token)}catch(e){}refresh()};$('search').oninput=refresh;
$('export').onclick=async()=>{try{const data=await api('/api/diagnostics'),blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='ysp-diagnostics.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}catch(e){$('notice').textContent=e.message}};
$('catchup').onclick=async()=>{try{const start=Date.parse($('start').value),end=Date.parse($('end').value);if(!Number.isFinite(start)||!Number.isFinite(end))throw Error('请选择开始和结束时间');const d=await api('/api/catchup?channel='+encodeURIComponent($('channel').value)+'&start='+Math.floor(start/1000)+'&end='+Math.floor(end/1000));$('catchuplink').replaceChildren();anchor($('catchuplink'),'打开回看',d.url)}catch(e){$('catchuplink').textContent=e.message}};
refresh();setInterval(()=>{if(!document.hidden)refresh()},15000);
</script></html>'''


class Handler(BaseHTTPRequestHandler):
    server_version = 'ysp-live/' + __version__

    def send_response(self, code, message=None):
        self._response_started = True
        super().send_response(code, message)

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype='text/plain; charset=utf-8', head_only=False, extra_headers=None):
        data = body.encode('utf-8') if isinstance(body, str) else body
        try:
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            if code not in (204, 304):
                self.send_header('Content-Length', str(len(data)))
            self.send_header('Access-Control-Allow-Origin', '*')
            if 'Cache-Control' not in (extra_headers or {}):
                self.send_header('Cache-Control', 'no-cache, no-store, max-age=0')
            for key, value in (extra_headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if not head_only:
                self.wfile.write(data)
        except (OSError, TimeoutError):
            self.close_connection = True

    def _origin(self):
        configured = getattr(self.server, 'public_base_url', '')
        if configured:
            return configured.rstrip('/')
        host = self.headers.get('Host', f'localhost:{server_port}')
        parsed = urllib.parse.urlsplit('http://' + host)
        if not parsed.hostname or parsed.path or parsed.query or parsed.fragment or parsed.username:
            raise ValueError('invalid Host header')
        scheme = 'http'
        if getattr(self.server, 'trust_proxy', False):
            candidate = self.headers.get('X-Forwarded-Proto', 'http').split(',')[0].strip().lower()
            if candidate in ('http', 'https'):
                scheme = candidate
        return scheme + '://' + host

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        self._response_started = False
        try:
            self._dispatch(head_only)
        except ProxyError as exc:
            if self._response_started:
                self.close_connection = True
                return
            self._send(exc.status, str(exc) + '\n', head_only=head_only,
                       extra_headers={'Retry-After': '2'} if exc.status == 503 else None)
        except ValueError as exc:
            if self._response_started:
                self.close_connection = True
                return
            self._send(400, str(exc) + '\n', head_only=head_only)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        except Exception as exc:
            log(f'[HTTP] {type(exc).__name__}: {str(exc)[:160]}', min_interval=5)
            if self._response_started:
                self.close_connection = True
                return
            self._send(500, 'internal server error\n', head_only=head_only)

    def _prepare_playlist(self, ch, playlist, source, head_only, extra=None):
        try:
            with ch.publication_lock:
                if head_only and ch._publication:
                    source = ch._publication['source']
                validate_source_playlist(playlist)
                playlist = publish_channel_playlist(ch, playlist, source, head_only=head_only)
                if not head_only and ch._publication:
                    ch._publication['prepared_at'] = time.monotonic()
                headers = dict(extra or {})
                headers['X-Source'] = source
                headers['X-Source-Epoch'] = str(ch.source_epoch)
                if ch.source_restart_required:
                    headers['X-Stream-Restart'] = 'required'
                return playlist, headers
        except (FrozenPlaylistError, UnsafePlaylist) as exc:
            log(f'[{ch.slug}] 媒体停滞/格式受限: {type(exc).__name__}', min_interval=10)
            return None

    def _playlist(self, ch, playlist, source, head_only, extra=None,
                  selector=None, source_key=None, expected_epoch=None):
        guard = selector.lock if selector is not None and not head_only else contextlib.nullcontext()
        with guard:
            if selector is not None and not head_only:
                state = selector._state(source_key)
                if state['validation_epoch'] != expected_epoch or state['failures']:
                    state['discarded_attempts'] += 1
                    raise SourceAttemptSuperseded('source failed before playlist publication')
            prepared = self._prepare_playlist(ch, playlist, source, head_only, extra)
            if prepared is None:
                return False
            if selector is not None and not head_only:
                selector.commit(source_key)
        # A slow socket must never hold the channel's selection/publication locks.
        playlist, headers = prepared
        self._send(200, playlist, 'application/vnd.apple.mpegurl', head_only, headers)
        return True

    def _current_playlist(self, ch, selector, head_only=False):
        with selector.lock:
            selected = selector.selected
            if not selected or selector._state(selected)['failures']:
                return False
            with ch.publication_lock:
                state = ch._publication
                if not state or state['source'].split(':', 1)[0] != selected or time.monotonic() - state.get('prepared_at', 0) > 15:
                    return False
                playlist = state['snapshot']
                headers = {'X-Source': state['source'], 'X-Source-Epoch': str(ch.source_epoch), 'X-SWR': 'CURRENT'}
                if ch.source_restart_required:
                    headers['X-Stream-Restart'] = 'required'
        self._send(200, playlist, 'application/vnd.apple.mpegurl', head_only, headers)
        return True

    def _dispatch(self, head_only):
        parts = urllib.parse.urlsplit(self.path)
        path = parts.path
        qs = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
        # A resource capability grants access only to a previously registered URL.
        resource_route = path in ('/proxy', '/proxy.ts', '/engine_proxy')
        access_token = getattr(self.server, 'access_token', '')
        if access_token and not resource_route and path not in ('/livez', '/status'):
            provided = qs.get('access_token', [''])[0]
            authorization = self.headers.get('Authorization', '')
            if authorization.startswith('Bearer '):
                provided = authorization[7:]
            if not _hmac.compare_digest(provided.encode(), access_token.encode()):
                self._send(401, 'access token required\n', head_only=head_only)
                return
        if resource_route:
            token = qs.get('resource', qs.get('token', ['']))[0]
            if not token:
                # Old query aliases remain recognized, but arbitrary encoded URLs are not capabilities.
                token = proxy_ts_token(self.path) or ''
            resource = resolve_resource(token)
            status = media_proxy.serve(self, resource.url, resource.headers, head_only=head_only)
            if status in (401, 403, 404) and resource.channel and resolver:
                invalidated = resolver.record_segment_failure(resource.channel, resource.generation, status)
                ch = CHANNEL_MAP.get(resource.channel)
                if invalidated and ch and hasattr(ch, 'selector'):
                    ch.selector.failure('device', 'segment HTTP ' + str(status))
            return
        if path == '/status':
            nonce = secrets.token_urlsafe(18)
            self._send(200, STATUS_PAGE.replace('__NONCE__', nonce), 'text/html; charset=utf-8', head_only,
                {'Content-Security-Policy': "default-src 'none'; script-src 'nonce-" + nonce + "'; style-src 'nonce-" + nonce + "'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
                 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff'})
            return
        if path == '/api/channels':
            data = {'channels': channel_status(), 'playback_policy': playback_policy, 'epg': epg_manager.stats() if epg_manager else {'enabled': False}}
            self._send(200, redact_json(data, access_token), 'application/json; charset=utf-8', head_only)
            return
        if path == '/api/diagnostics':
            self._send(200, json.dumps(diagnostics_snapshot(access_token), ensure_ascii=False, indent=2),
                       'application/json; charset=utf-8', head_only)
            return
        if path in ('/api/diagnose', '/api/catchup', '/api/epg'):
            slug = qs.get('channel', [''])[0]
            meta = global_channel_dir.get_meta(slug)
            if not meta:
                self._send(404, 'unknown channel\n', head_only=head_only)
                return
            slug = meta['slug']
            if path == '/api/diagnose':
                if head_only:
                    self._send(405, 'use GET to request an active diagnostic\n', head_only=True)
                    return
                data = start_channel_diagnostic(get_channel_instance(slug), self._origin())
                self._send(200, redact_json(data, access_token), 'application/json; charset=utf-8')
                return
            if path == '/api/catchup':
                if slug not in TIMESHIFT_SUPPORTED:
                    self._send(422, '此频道不支持回看\n', head_only=head_only)
                    return
                times = parse_catchup_query(parts.query)
                if not times:
                    raise ValueError('回看需要开始和结束时间')
                url = catchup_link(slug, times[0], times[1], self._origin(), access_token)
                if not url:
                    raise ValueError('invalid catchup range')
                self._send(200, json.dumps({'url': url, 'verified': False, 'limit_days': 7}, ensure_ascii=False),
                           'application/json; charset=utf-8', head_only)
                return
            if epg_manager and not head_only:
                epg_manager.request_refresh()
            data = epg_manager.stats() if epg_manager else {'enabled': False}
            programmes = epg_manager.read(slug) if epg_manager else []
            now = int(time.time())
            for programme in programmes:
                programme['catchup_url'] = catchup_link(slug, programme['start'], programme['stop'], self._origin(), access_token)
            current = next((p for p in programmes if p['start'] <= now < p['stop']), None)
            upcoming = next((p for p in programmes if p['start'] > now), None)
            data.update(channel=slug, programmes=programmes, current=current, next=upcoming)
            self._send(200, json.dumps(data, ensure_ascii=False), 'application/json; charset=utf-8', head_only)
            return
        if path == '/epg.xml':
            if not epg_manager or not epg_manager.urls:
                self._send(404, 'EPG disabled\n', head_only=head_only)
                return
            if not head_only:
                epg_manager.request_refresh()
            state = epg_manager.stats()
            if not state['programmes']:
                self._send(503, 'EPG warming or unavailable; retry later\n', head_only=head_only,
                           extra_headers={'Retry-After': '10'})
                return
            etag = '"epg-' + str(state['updated']) + '"'
            if self.headers.get('If-None-Match') == etag:
                self._send(304, b'', head_only=True, extra_headers={'ETag': etag})
                return
            self._send(200, epg_manager.xml(), 'application/xml; charset=utf-8', head_only,
                       {'ETag': etag, 'X-EPG-Stale': str(state['stale']).lower(), 'Cache-Control': 'private, max-age=60'})
            return
        if path == '/livez':
            self._send(200, json.dumps({'ok': True, 'version': __version__}),
                       'application/json; charset=utf-8', head_only)
            return
        if path in ('/health', '/readyz'):
            now = time.time()
            ready_channels = []
            for slug, ch in list(CHANNEL_MAP.items()):
                with ch.lock:
                    progress = getattr(ch, 'last_media_advance_at', ch.last_ok)
                    if progress and now - progress < 60:
                        ready_channels.append(slug)
            device_ready = bool(resolver and resolver_ready())
            ready = device_ready or bool(ready_channels)
            health = {'ok': ready, 'ready': ready, 'live': True, 'version': __version__,
                      'uptime_sec': int(now - server_start_time),
                      'state': 'ready' if ready else 'warming_or_unavailable',
                      'engine': {'ready': device_ready}, 'ready_channels': ready_channels,
                      'channels': len(global_channel_dir.unique_channels()),
                      'ts_cache': media_proxy.stats(),
                      'http': {'active': getattr(self.server, 'active', 0),
                               'rejected': getattr(self.server, 'rejected', 0)}}
            self._send(200 if ready else 503, json.dumps(health, ensure_ascii=False, indent=2),
                       'application/json; charset=utf-8', head_only)
            return
        if path in ('/', '/index.html'):
            origin = self._origin()
            self._send(200, f'ysp-live {__version__}\n全频道订阅: {origin}/all.m3u\n'
                       f'频道状态: {origin}/status\n存活检查: {origin}/livez\n播放就绪: {origin}/readyz\n诊断: {origin}/diag\n'
                       + AUTHOR_NOTICE + '\n', head_only=head_only)
            return
        if path == '/favicon.ico':
            self._send(204, b'', head_only=head_only)
            return
        if path == '/all.m3u':
            origin = self._origin()
            target_group = qs.get('group', [''])[0]
            only_4k = qs.get('k4', ['0'])[0].lower() in ('1', 'true', 'yes')
            lines = ['#EXTM3U']
            suffix = '?access_token=' + urllib.parse.quote(access_token, safe='') if access_token else ''
            if epg_manager and epg_manager.urls:
                lines[0] += ' url-tvg="' + origin + '/epg.xml' + suffix + '"'
            for meta in global_channel_dir.unique_channels():
                slug = meta['slug']
                if target_group and target_group not in meta['group']:
                    continue
                if only_4k and slug not in TRUE_4K_CHANNELS:
                    continue
                attrs = f' tvg-id="{meta["tvg_id"]}" tvg-name="{meta["name"]}" tvg-logo="{meta["logo"]}" group-title="{meta["group"]}"'
                if slug in TIMESHIFT_SUPPORTED:
                    separator = '&' if access_token else '?'
                    attrs += ' catchup="append" catchup-days="7" catchup-source="' + separator + 'playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"'
                lines.extend([f'#EXTINF:-1{attrs},{meta["name"]}', f'{origin}/{slug}.m3u8{suffix}'])
            self._send(200, '\n'.join(lines) + '\n', 'application/vnd.apple.mpegurl', head_only)
            return
        if path == '/diag':
            self._send(200, json.dumps(diagnostics_snapshot(access_token), ensure_ascii=False, indent=2) + '\n',
                       'text/plain; charset=utf-8', head_only)
            return
        match = re.fullmatch(r'/([\w-]+)\.m3u8', path)
        if not match:
            self._send(404, 'not found\n', head_only=head_only)
            return
        canonical = ALIAS_MAP.get(normalize_channel(match.group(1)), normalize_channel(match.group(1)))
        ch = get_channel_instance(canonical)
        if ch is None:
            self._send(404, '未知频道\n', head_only=head_only)
            return
        catchup_names = {'playseek', 'start', 'end', 'utc', 'lutc', 'starttime', 'endtime'}
        if catchup_names.intersection(qs):
            times = parse_catchup_query(parts.query)
            if not times:
                raise ValueError('invalid catchup time range')
            if canonical not in TIMESHIFT_SUPPORTED:
                self._send(422, '此频道不支持回看\n', head_only=head_only)
                return
            try:
                start_ts, end_ts = times
                url = jce_timeshift_url(ch.pid, ch.sid, start_ts, end_ts, ch.defn)
                playlist = fetch_abs_playlist(url, quality=ch.defn)
                self._send(200, playlist, 'application/vnd.apple.mpegurl', head_only)
                return
            except Exception as exc:
                if qs.get('fallback', [''])[0] != 'live':
                    self._send(502, '回看源暂不可用，请稍后重试\n', head_only=head_only)
                    return
                log(f'[{canonical}] 回看失败，按请求回落直播: {type(exc).__name__}', min_interval=10)
        origin = self._origin()
        selector = channel_selector(ch)
        loaders = source_loaders(ch, origin, head_only)
        if not head_only:
            ch.last_access = time.time()
            schedule_source_probe(selector, loaders, origin)
        for source in selector.order(loaders):
            started = time.monotonic()
            attempt_epoch = selector.attempt_token(source)
            accepted_epoch = attempt_epoch
            try:
                playlist, published_source, extra = loaders[source]()
                if not playlist or '#EXTM3U' not in playlist:
                    raise RuntimeError('empty source playlist')
                if not head_only:
                    accepted_epoch = selector.success(source, playlist, time.monotonic() - started,
                        expected_epoch=attempt_epoch, context=published_source)
                if self._playlist(ch, playlist, published_source, head_only, extra,
                                  selector, source, accepted_epoch):
                    if not head_only:
                        if media_probe_manager:
                            media_probe_manager.schedule(selector, source, playlist, origin)
                    return
                raise FrozenPlaylistError('published source is stale or unsupported')
            except SourceAttemptSuperseded:
                if self._current_playlist(ch, selector, head_only):
                    return
                continue
            except Exception as exc:
                if not head_only:
                    selector.failure(source, type(exc).__name__ + ': ' + str(exc), expected_epoch=accepted_epoch)
                log(f'[{canonical}] {source}源降级: {type(exc).__name__}', min_interval=10)
        self._send(503, f'频道 {ch.name} 暂无数据，请稍后重试\n', head_only=head_only,
                   extra_headers={'Retry-After': '2'})
def init_resolver ():
    if resolver is None :
        return 
    log ('[系统] 正在初始化设备协议并发池…')
    retry_count =0 
    while not shutdown_event.is_set():
        try :
            resolver .ensure_slot_session (0 )
            set_resolver_ready (True )
            log (f'[系统] 设备身份就绪，高码率并发池已激活 (全部 {len (active_backend_channels )} 路按需解析)')
            break 
        except Exception as e :
            retry_count +=1 
            log (f'[系统] 设备协议初始化第 {retry_count } 次重试中: {e }，4K/高码率频道暂走 1080p 回退',min_interval =10.0 )
            set_resolver_ready (False )
            if 'HTTP 400'in str (e ):
                resolver .rotate_device_on_400 ('init:'+str (e )[:60 ])
            backoff =min (15.0 * (1.5 ** min (retry_count - 1 ,4 )),60.0 )
            shutdown_event.wait(backoff)
companion_proc =None 
def is_port_listening (port :int ,host :str ='127.0.0.1')->bool :
    try :
        with socket .socket (socket .AF_INET ,socket .SOCK_STREAM )as s :
            s .settimeout (0.5 )
            return s .connect_ex ((host ,port ))==0 
    except Exception :
        return False 
_engine_process_lock = threading.RLock()
_engine_restarts = collections.deque()


def _companion_identity(port):
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            response = opener.open(f'http://127.0.0.1:{port}/health', timeout=0.6)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            detail = json.loads(response.read(4096))
            return detail.get('engine') == 'ysp-engine'
    except Exception:
        return False


def start_companion_engine(script_dir: str, port: int = 8787):
    global companion_proc, engine_enabled
    with _engine_process_lock:
        if shutdown_event.is_set():
            return False
        if is_port_listening(port):
            matched = _companion_identity(port)
            log('[引擎] 已有伴生引擎' if matched else '[引擎] 端口被其他服务占用，禁用引擎回退')
            return matched
        engine_file = os.path.join(script_dir, 'ysp-engine.js')
        node_bin = shutil.which('node')
        if not os.path.isfile(engine_file) or not os.path.isfile(os.path.join(script_dir, 'ysp-engine-runtime.js')) or not node_bin:
            log('[引擎] 缺少Node或引擎文件，继续使用其他播放源')
            return False
        subp = __import__('subprocess')
        child_env = os.environ.copy()
        child_env['YSP_ENGINE_HOST'] = '127.0.0.1'
        child_env['YSP_ENGINE_PORT'] = str(port)
        child_env['YSP_ENGINE_SHUTDOWN_MS'] = '2000'
        try:
            child = subp.Popen([node_bin, engine_file, str(port)], env=child_env,
                               stdout=subp.PIPE, stderr=subp.STDOUT, text=True,
                               encoding='utf-8', errors='replace')
        except OSError as exc:
            log(f'[引擎] 启动失败: {type(exc).__name__}')
            return False
        companion_proc = child

    def drain():
        try:
            for line in child.stdout:
                if line.strip():
                    log('[引擎] ' + line.strip()[:240], min_interval=0.1)
        except (OSError, ValueError):
            pass
        finally:
            if child.stdout:
                child.stdout.close()

    def supervise():
        global companion_proc, engine_enabled
        child.wait()
        with _engine_process_lock:
            if companion_proc is not child:
                return
            companion_proc = None
            engine_enabled = False
            now = time.monotonic()
            while _engine_restarts and now - _engine_restarts[0] > 3600:
                _engine_restarts.popleft()
            if shutdown_event.is_set() or len(_engine_restarts) >= 3:
                return
            _engine_restarts.append(now)
        log('[引擎] 意外退出，稍后受限重启')
        if not shutdown_event.wait(2):
            engine_enabled = start_companion_engine(script_dir, port)

    threading.Thread(target=drain, daemon=True, name='engine-log').start()
    threading.Thread(target=supervise, daemon=True, name='engine-supervisor').start()
    for _ in range(50):
        if child.poll() is not None or shutdown_event.is_set():
            return False
        if _companion_identity(port):
            log('[引擎] 伴生引擎已启动（仅监听本机）')
            return True
        shutdown_event.wait(0.1)
    log('[引擎] 等待就绪超时')
    stop_companion_engine()
    return False


def stop_companion_engine():
    global companion_proc
    with _engine_process_lock:
        child, companion_proc = companion_proc, None
    if child is not None:
        try:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=4)
                except __import__('subprocess').TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
        except OSError:
            pass
atexit .register (stop_companion_engine )
def _handle_sigterm(signum, frame):
    shutdown_event.set()
    if active_server is not None:
        threading.Thread(target=active_server.shutdown, daemon=True).start()
def main():
    global resolver, server_port, engine_port, media_proxy, active_server, engine_enabled
    global global_ts_cache, active_backend_channels, epg_manager, media_probe_manager, playback_policy
    ap = argparse.ArgumentParser(description=f'央视频直播代理 v{__version__}（本地优化版）')
    ap.add_argument('port', nargs='?', type=int, default=8767)
    ap.add_argument('--bind', default='0.0.0.0')
    ap.add_argument('--data-dir', default=os.environ.get('YSP_DATA_DIR', ''))
    ap.add_argument('--cache-mb', type=int, default=200, help='已完成分片RAM缓存MiB，0关闭')
    ap.add_argument('--inflight-mb', type=int, default=256, help='共享下载临时文件总预算MiB')
    ap.add_argument('--temp-dir', default='', help='共享下载临时目录，默认使用系统临时目录')
    ap.add_argument('--max-connections', type=int, default=64)
    ap.add_argument('--download-workers', type=int, default=8)
    ap.add_argument('--client-timeout', type=float, default=20.0)
    ap.add_argument('--media-timeout', type=float, default=30.0)
    ap.add_argument('--foreground-wait', type=float, default=2.0)
    ap.add_argument('--public-base-url', default='', help='例如https://tv.example.com，反代推荐配置')
    ap.add_argument('--trust-proxy', action='store_true', help='信任X-Forwarded-Proto，仅可信反代使用')
    ap.add_argument('--access-token', default=os.environ.get('YSP_ACCESS_TOKEN', ''), help='可选访问令牌，也可用YSP_ACCESS_TOKEN')
    ap.add_argument('--no-4k', action='store_true')
    ap.add_argument('--only-4k', action='store_true')
    ap.add_argument('--links-per-device', type=int, default=int(os.environ.get('YSP_LINKS_PER_DEVICE', '6')))
    ap.add_argument('--zap-debounce', type=float, default=float(os.environ.get('YSP_ZAP_DEBOUNCE', '10.0')))
    ap.add_argument('--engine-port', type=int, default=8787)
    ap.add_argument('--timeout', type=float, default=10.0)
    ap.add_argument('--no-engine', action='store_true')
    ap.add_argument('--quality', choices=('best', 'auto', 'fhd', 'shd'), default=None, help='best选择最高可用视频档位，auto交给播放器，fhd约1080p，shd约720p')
    ap.add_argument('--device-rate', choices=('auto', '36p', '10p'), default='auto')
    ap.add_argument('--epg-url', action='append', default=None, help='XMLTV或XMLTV.gz地址，可重复配置最多3个，按顺序回退')
    ap.add_argument('--epg-refresh', type=float, default=3600, help='EPG缓存刷新间隔秒，最少60')
    ap.add_argument('--no-epg', action='store_true', help='禁用EPG下载和本地节目单接口')
    ap.add_argument('--playback-policy', choices=('quality', 'stable', 'bandwidth'), default='quality', help='默认画质优先；stable固定来源优先级；bandwidth偏好低流量')
    ap.add_argument('--media-probe', choices=('background', 'off'), default='background', help='后台限量检测实际分片内容；每来源最短30秒一次')
    args = ap.parse_args()
    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, _handle_sigterm)
    if not (1 <= args.port <= 65535 and 1 <= args.engine_port <= 65535) or args.port == args.engine_port:
        ap.error('端口必须在1–65535之间且服务端口与引擎端口不同')
    if args.cache_mb < 0 or args.inflight_mb < 1 or args.max_connections < 1 or args.download_workers < 1 or args.links_per_device < 0:
        ap.error('缓存不能为负；在途预算、连接数和下载并发必须大于0')
    for name in ('timeout', 'media_timeout', 'client_timeout', 'foreground_wait'):
        value = getattr(args, name)
        if not math.isfinite(value) or value <= 0:
            ap.error(name + '必须是有限正数')
    if not math.isfinite(args.zap_debounce) or args.zap_debounce < 0:
        ap.error('zap-debounce必须是有限非负数')
    if args.public_base_url:
        parsed = urllib.parse.urlsplit(args.public_base_url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.path not in ('', '/') or parsed.query or parsed.fragment:
            ap.error('public-base-url必须是无路径、凭据或query的HTTP(S)地址')
    if not math.isfinite(args.epg_refresh) or args.epg_refresh < 60:
        ap.error('epg-refresh必须是至少60的有限秒数')
    epg_urls = args.epg_url if args.epg_url is not None else [u.strip() for u in os.environ.get('YSP_EPG_URL', 'https://epg.zsdc.eu.org/t.xml.gz,https://epg.pw/xmltv/epg_CN.xml.gz').split(',') if u.strip()]
    if len(epg_urls) > 3:
        ap.error('EPG源最多3个')
    for url in epg_urls:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
            ap.error('epg-url必须是无凭据的HTTP(S) XMLTV地址')
    here = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.abspath(args.data_dir or here)
    os.makedirs(data_dir, exist_ok=True)
    if args.temp_dir:
        os.makedirs(args.temp_dir, exist_ok=True)
    server_port, engine_port = args.port, args.engine_port
    engine_enabled = not args.no_engine
    shutdown_event.clear()
    media_proxy.close()
    media_proxy = SharedMediaProxy(policy=URLPolicy(engine_port=engine_port),
        max_cache_bytes=args.cache_mb * 2**20, max_inflight_bytes=args.inflight_mb * 2**20,
        max_downloads=args.download_workers, timeout=args.media_timeout,
        temp_dir=args.temp_dir or None)
    # Compatibility diagnostics now point to the cache actually used by media requests.
    global_ts_cache = media_proxy
    playback_policy = args.playback_policy
    selected_quality = args.quality or {'quality': 'best', 'stable': 'fhd', 'bandwidth': 'shd'}[playback_policy]
    for ch in CHANNEL_MAP.values():
        ch.defn = selected_quality
    if args.playback_policy == 'bandwidth' and args.device_rate == 'auto':
        args.device_rate = '10p'
    media_probe_manager = MediaProbeManager(proxy=media_proxy) if args.media_probe == 'background' else None
    only_4k = args.only_4k or os.environ.get('YSP_ONLY_4K_DEVICE', '').lower() in ('1', 'true', 'yes')
    active_backend_channels = set() if args.no_4k else set(TRUE_4K_CHANNELS if only_4k else BACKEND_CHANNELS)
    engine_args = argparse.Namespace(host=args.bind, port=args.port, timeout=args.timeout,
        insecure_tls=False, cache_ttl=60.0, stale_while_refresh_ttl=15.0,
        refresh_error_cooldown=5.0, playlist_cache_ttl=2.0,
        background_refresh_queue_limit=16, http_workers=args.max_connections, http_queue_limit=0,
        identity_reset_error_threshold=0, identity_reset_cooldown=300.0, refresh_interval=1.0,
        control_step_jitter_min_ms=0, control_step_jitter_max_ms=0, heartbeat_interval=30.0,
        heartbeat_ttl_guard=60.0, session_ttl=7200.0,
        meta_json=os.path.join(data_dir, 'proxy-cache-state-rs.json'),
        device_json=os.path.join(data_dir, 'device-state-rs.json'),
        links_per_device=args.links_per_device, zap_debounce=args.zap_debounce,
        foreground_wait=args.foreground_wait, device_rate=args.device_rate)
    epg_manager = EPGCache(() if args.no_epg else epg_urls, os.path.join(data_dir, 'epg-cache.json'), args.epg_refresh)
    resolver = Resolver(engine_args)
    try:
        active_server = BoundedHTTPServer((args.bind, args.port), Handler,
            max_connections=args.max_connections, client_timeout=args.client_timeout)
        active_server.public_base_url = args.public_base_url.rstrip('/')
        active_server.trust_proxy = args.trust_proxy
        active_server.access_token = args.access_token
        if engine_enabled:
            engine_enabled = start_companion_engine(here, engine_port)
        if not args.no_4k:
            resolver.start_heartbeat()
            resolver.start_refresh_worker()
            threading.Thread(target=init_resolver, daemon=True, name='engine-init').start()
        log(f'ysp-live {__version__} 本地优化版启动，频道={len(CHANNEL_MAP)}，端口={args.port}')
        log(f'订阅: http://localhost:{args.port}/all.m3u；存活:/livez；播放就绪:/readyz')
        log(f'选源策略={playback_policy}，列表画质={selected_quality}，分片检测={args.media_probe}')
        log(f'分片RAM缓存={args.cache_mb}MiB，在途临时文件预算={args.inflight_mb}MiB，下载并发={args.download_workers}')
        active_server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        shutdown_event.set()
        resolver.close()
        if epg_manager:
            epg_manager.close()
        if media_probe_manager:
            media_probe_manager.close()
        feature_pool.shutdown(wait=False, cancel_futures=True)
        diagnostic_pool.shutdown(wait=False, cancel_futures=True)
        media_proxy.close()
        if active_server:
            active_server.server_close()
            active_server = None
        stop_companion_engine()

if __name__ =='__main__':
    main ()
