"""Generate XMLTV from Migu's public daily programme API, in bounded batches."""
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError, as_completed
from datetime import datetime, timedelta, timezone
import json
import threading
import time
import xml.etree.ElementTree as ET

from migu import core as m
from migu.native import BUILTIN_CHANNELS
from migu.workers import BoundedExecutor


def official_programmes(pid, raw, now=None):
    now = now or m.utcnow()
    if not isinstance(raw, bytes) or len(raw) > 512*1024:
        raise m.FetchError('EPG_RESPONSE_TOO_LARGE')
    try:
        payload = json.loads(raw)
        if str(payload.get('code')) != '200':
            raise m.FetchError('EPG_API_REJECTED')
        programmes = (payload.get('body') or {}).get('program') or []
        if not isinstance(programmes, list) or len(programmes) > 7:
            raise m.FetchError('EPG_API_FORMAT_CHANGED')
        rows = set()
        count = 0
        for group in programmes:
            for programme in group.get('content') or []:
                count += 1
                if count > 1000:
                    raise m.FetchError('EPG_TOO_MANY_PROGRAMMES')
                if str(programme.get('pID', pid)) != pid:
                    continue
                title = programme.get('contName')
                begin, end = programme.get('startTime'), programme.get('endTime')
                if not isinstance(title, str) or not title.strip() or len(title) > 512 or not m.clean_text(title):
                    continue
                if type(begin) not in {int, float} or type(end) not in {int, float}:
                    continue
                try:
                    start = datetime.fromtimestamp(begin/1000, timezone.utc)
                    stop = datetime.fromtimestamp(end/1000, timezone.utc)
                except (ValueError, OverflowError, OSError):
                    continue
                if not timedelta(0) < stop-start <= timedelta(days=2) or stop < now-timedelta(days=1) or start > now+timedelta(days=7):
                    continue
                rows.add((start, stop, title))
        return tuple(sorted(rows))
    except (ValueError, TypeError, AttributeError) as failure:
        if isinstance(failure, m.UpdateError):
            raise
        raise m.FetchError('EPG_API_FORMAT_CHANGED') from None


def render_epg(schedules, now=None):
    now = now or m.utcnow()
    root = ET.Element('tv', {'generator-info-name': 'migu-live'})
    matched, count, latest = set(), 0, None
    for pid, name, _ in BUILTIN_CHANNELS:
        channel = ET.SubElement(root, 'channel', {'id': 'p'+pid})
        ET.SubElement(channel, 'display-name', {'lang': 'zh'}).text = name
    for pid, _, _ in BUILTIN_CHANNELS:
        for start, stop, title in schedules.get(pid, ()):
            if stop < now-timedelta(days=1):
                continue
            count += 1
            if count > 10000:
                raise m.FetchError('EPG_TOO_MANY_PROGRAMMES')
            matched.add(pid)
            node = ET.SubElement(root, 'programme', {'channel': 'p'+pid,
                'start': start.astimezone(m.CHINA).strftime('%Y%m%d%H%M%S %z'),
                'stop': stop.astimezone(m.CHINA).strftime('%Y%m%d%H%M%S %z')})
            ET.SubElement(node, 'title', {'lang': 'zh'}).text = title
            latest = max(latest, stop) if latest else stop
    if latest is None or latest <= now:
        raise m.FetchError('EPG_EMPTY_OR_EXPIRED')
    raw = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    if len(raw) > m.MAX_BYTES:
        raise m.FetchError('EPG_TOO_LARGE')
    return raw, {'programmes': count, 'matched_channels': len(matched),
                 'missing_channels': [name for pid, name, _ in BUILTIN_CHANNELS if pid not in matched]}, latest


class EpgStore:
    def __init__(self, client_factory=m.HttpClient, clock=time.monotonic, enabled=True):
        self.client_factory, self.clock, self.enabled = client_factory, clock, enabled
        self.lock, self.ready = threading.RLock(), threading.Event()
        self.pool = BoundedExecutor(1, thread_name_prefix='migu-epg-refresh', max_pending=1)
        self.downloads = BoundedExecutor(4, thread_name_prefix='migu-epg', max_pending=4)
        self.future, self.closed, self.data = None, False, None
        self.details, self.latest, self.last_error, self.updated = {}, None, None, None
        self.fresh_until, self.retry_at, self.valid_until = 0, 0, 0
        self.rows, self.day = {}, None
        self.attempts = {}
        self.upstream_error = None

    def _usable(self):
        return self.data is not None and self.clock() < self.valid_until and self.latest > m.utcnow()

    def _fetch(self, pid, day):
        url = f'https://program-sc.miguvideo.com/live/v2/tv-programs-data/{pid}/{day}'
        raw, _ = self.client_factory('epg', attempts=1, timeout=5, budget=6).get(url, limit=512*1024)
        return official_programmes(pid, raw)

    def _publish(self):
        result = render_epg(self.rows)
        with self.lock:
            if self.closed:
                return
            self.data, self.details, self.latest = result
            self.valid_until = self.clock() + 36*3600
            self.updated = m.iso(m.utcnow())
            self.ready.set()

    def _refresh(self, day):
        try:
            if self.day != day:
                self.rows, self.attempts, self.day = {}, {}, day
            failures = 0
            deadline = time.monotonic() + 120
            pending = [pid for pid, _, _ in BUILTIN_CHANNELS if self.clock() >= self.attempts.get(pid, 0)]
            for index in range(0, len(pending), 4):
                if self.closed or time.monotonic() >= deadline:
                    break
                batch = {self.downloads.submit(self._fetch, pid, day): pid for pid in pending[index:index+4]}
                completed = set()
                try:
                    for future in as_completed(batch, timeout=8):
                        pid = batch[future]
                        completed.add(future)
                        try:
                            rows = future.result()
                            self.rows[pid] = rows
                            self.attempts[pid] = self.clock() + (6*3600 if rows else 15*60)
                            if self.data is None and rows:
                                try:
                                    self._publish()  # A slow sibling must not hide ready programmes.
                                except m.UpdateError:
                                    pass
                        except Exception as failure:
                            failures += 1
                            with self.lock:
                                self.upstream_error = str(failure) if isinstance(failure, m.UpdateError) else 'EPG_FETCH_ERROR'
                            self.attempts[pid] = self.clock() + 15*60
                except FutureTimeout:
                    for future in set(batch)-completed:
                        future.cancel()
                        self.attempts[batch[future]] = self.clock() + 15*60
                        failures += 1
                if self.closed:
                    return
                try:
                    self._publish()  # Publish usable partial data; continue filling other channels.
                except m.UpdateError:
                    pass
            with self.lock:
                if not self.closed:
                    self.upstream_error = self.upstream_error if failures else None
                    self.last_error = 'EPG_REFRESH_PARTIAL_FAILURE' if failures else (None if self.details.get('matched_channels') == len(BUILTIN_CHANNELS) else 'EPG_PARTIAL_OR_FAILED')
                    self.fresh_until = self.clock() + (60 if len(self.attempts) < len(BUILTIN_CHANNELS) else 15*60)
                    self.retry_at = self.clock() + 60
                    if not self._usable():
                        self.last_error = 'EPG_EMPTY_OR_UNAVAILABLE'
                    self.ready.set()
        except Exception as failure:
            with self.lock:
                if not self.closed:
                    self.last_error = str(failure) if isinstance(failure, m.UpdateError) else 'EPG_REFRESH_ERROR'
                    self.retry_at = self.clock() + 60
                    self.ready.set()
        finally:
            with self.lock:
                self.future = None

    def get(self, wait=5):
        with self.lock:
            if not self.enabled:
                raise m.FetchError('EPG_DISABLED')
            if self.closed:
                raise m.FetchError('SERVICE_STOPPING')
            day = m.utcnow().astimezone(m.CHINA).strftime('%Y%m%d')
            usable = self._usable()
            if usable and self.clock() < self.fresh_until and self.day == day:
                return self.data
            if self.future is None and (self.clock() >= self.retry_at or self.day != day):
                if not usable:
                    self.ready.clear()
                self.future = self.pool.submit(self._refresh, day)
            if usable:
                return self.data
            future = self.future
        if future is not None:
            try:
                future.result(timeout=wait)
            except (FutureTimeout, CancelledError):
                pass
        with self.lock:
            if self.closed:
                raise m.FetchError('SERVICE_STOPPING')
            if self._usable():
                return self.data
            raise m.FetchError(self.last_error or 'EPG_LOADING')

    def status(self):
        with self.lock:
            return {'enabled': self.enabled, 'source': 'migu-official', 'ready': self._usable(),
                    'refreshing': self.future is not None, 'updated_utc': self.updated,
                    'last_error': self.last_error, 'upstream_error': self.upstream_error, **self.details}

    def close(self):
        with self.lock:
            self.closed = True
            self.ready.set()
        self.pool.shutdown(wait=False)
        self.downloads.shutdown(wait=False)
