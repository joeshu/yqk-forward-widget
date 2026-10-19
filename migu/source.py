"""Use the published playlist's existing URLs; never call the anonymous play API."""
from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime, timedelta
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit
from migu import core as m
from migu.core import Channel, CHINA, MAX_BYTES, MAX_LINE, UpdateError, clean_text, validate_url, utcnow
from migu.workers import BoundedExecutor

LIST_SOURCES = (
    'https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu.m3u8',
    'http://www.52top.com.cn:678/downloads/migu.txt',
)
CATCHUP_SOURCE = '&playbackbegin=${(b)yyyyMMddHHmmss}&playbackend=${(e)yyyyMMddHHmmss}'
EPG_ID_ALIASES = {'上视新闻综合': '上海新闻综合'}
ATTR = re.compile(r'([a-z][a-z0-9-]*)="([^"\r\n]*)"')
CHANNEL_ATTRS = {'tvg-id','tvg-name','tvg-logo','group-title','svg-id','svg-name'}

@dataclass(frozen=True)
class ListPlaylist:
    channels: tuple
    catchup: bool
    duplicates_removed: int = 0

@dataclass(frozen=True)
class ListSnapshot:
    playlist: ListPlaylist
    channels: object

def parse_list_attributes(value, channel=False):
    attrs, rest = {}, value.strip()
    while rest and not (channel and rest.startswith(",")):
        match = ATTR.match(rest)
        if match is None or match[1] in attrs:
            raise UpdateError("METADATA_INVALID_OR_DUPLICATE")
        attrs[match[1]] = match[2]
        rest = rest[match.end():]
        if rest and not rest[0].isspace() and not (channel and rest[0] == ","):
            raise UpdateError("METADATA_SEPARATOR")
        rest = rest.lstrip()
    if channel:
        if not rest.startswith(",") or not rest[1:].strip():
            raise UpdateError("CHANNEL_NAME_MISSING")
        return attrs, rest[1:].strip()
    return attrs

def parse_source_list(raw):
    if len(raw) > MAX_BYTES:
        raise UpdateError("PLAYLIST_TOO_LARGE")
    try:
        text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    except UnicodeError:
        raise UpdateError("PLAYLIST_NOT_UTF8") from None
    if not clean_text(text.replace("\n", "")):
        raise UpdateError("PLAYLIST_CONTROL_CHARACTER")
    lines = text.split("\n")
    if any(len(line) > MAX_LINE for line in lines):
        raise UpdateError("PLAYLIST_LINE_TOO_LONG")
    if not lines or not (lines[0] == "#EXTM3U" or lines[0].startswith("#EXTM3U ")):
        raise UpdateError("PLAYLIST_HEADER_INVALID")
    header = parse_list_attributes(lines[0][7:])
    if set(header) - {"x-tvg-url", "tvg-url", "url-tvg", "catchup", "catchup-source"}:
        raise UpdateError("HEADER_ATTRIBUTE_NOT_ALLOWED")
    catchup = "catchup" in header or "catchup-source" in header
    if catchup and (header.get("catchup") != "append" or header.get("catchup-source") != CATCHUP_SOURCE):
        raise UpdateError("CATCHUP_TEMPLATE_NOT_ALLOWED")
    channels, seen, duplicates = [], set(), 0
    pending = None
    for line in lines[1:]:
        if not line:
            continue
        if line.startswith("#EXTINF:"):
            if pending is not None or not line.startswith("#EXTINF:-1 "):
                raise UpdateError("CHANNEL_METADATA_INVALID")
            attrs, display = parse_list_attributes(line[len("#EXTINF:-1"):], channel=True)
            if set(attrs) - CHANNEL_ATTRS:
                raise UpdateError("CHANNEL_ATTRIBUTE_NOT_ALLOWED")
            for suffix in ("id", "name"):
                standard, legacy = "tvg-" + suffix, "svg-" + suffix
                if standard in attrs and legacy in attrs and attrs[standard] != attrs[legacy]:
                    raise UpdateError("CHANNEL_ATTRIBUTE_CONFLICT")
                attrs.setdefault(standard, attrs.get(legacy, display))
            attrs["tvg-id"] = EPG_ID_ALIASES.get(attrs["tvg-id"], attrs["tvg-id"])
            if any(not attrs[key] or len(attrs[key]) > 256 for key in ("tvg-id", "tvg-name")) or len(display) > 256 or '"' in display:
                raise UpdateError("CHANNEL_NAME_INVALID")
            if attrs.get("tvg-logo"):
                validate_url(attrs["tvg-logo"], "logo")
            pending = (attrs, display)
        elif line.startswith("#"):
            raise UpdateError("PLAYLIST_DIRECTIVE_NOT_ALLOWED")
        else:
            if pending is None:
                raise UpdateError("URL_WITHOUT_CHANNEL")
            parts = validate_url(line, "stream")
            try:
                params = parse_qs(parts.query, keep_blank_values=True, max_num_fields=100)
            except ValueError:
                raise UpdateError("URL_TOO_MANY_PARAMETERS") from None
            timestamps = params.get("timestamp", [])
            if len(timestamps) != 1 or re.fullmatch(r"\d{14}", timestamps[0]) is None:
                raise UpdateError("SIGNATURE_TIMESTAMP_MISSING")
            try:
                signed_at = datetime.strptime(timestamps[0], "%Y%m%d%H%M%S").replace(tzinfo=CHINA)
            except ValueError:
                raise UpdateError("SIGNATURE_TIMESTAMP_INVALID") from None
            attrs, display = pending
            channel = Channel(attrs["tvg-id"], attrs["tvg-name"], display, attrs.get("group-title", ""), attrs.get("tvg-logo", ""), line, signed_at)
            if channel in seen:
                duplicates += 1
            else:
                seen.add(channel)
                channels.append(channel)
            if len(channels) > 2000:
                raise UpdateError("TOO_MANY_CHANNELS")
            pending = None
    if pending is not None or not channels:
        raise UpdateError("PLAYLIST_EMPTY_OR_TRUNCATED")
    return ListPlaylist(tuple(channels), catchup, duplicates)

def validate_list_candidate(candidate, previous=None, *, now=None, min_channels=100, min_retention=0.9, max_age_hours=12):
    now = now or utcnow()
    if len(candidate.channels) < min_channels:
        raise UpdateError("TOO_FEW_CHANNELS")
    # Publication policy, not an inferred token expiry time.
    for channel in candidate.channels:
        if channel.signed_at > now + timedelta(minutes=15):
            raise UpdateError("SIGNATURE_FROM_FUTURE")
        if channel.signed_at < now - timedelta(hours=max_age_hours):
            raise UpdateError("SOURCE_SNAPSHOT_TOO_OLD")
    if previous is not None:
        previous_ids = {channel.id for channel in previous.channels}
        candidate_ids = {channel.id for channel in candidate.channels}
        if len(candidate_ids & previous_ids) < len(previous_ids) * min_retention:
            raise UpdateError("CHANNEL_RETENTION_TOO_LOW")
        last_times = {}
        for channel in previous.channels:
            last_times[channel.id] = max(last_times.get(channel.id, channel.signed_at), channel.signed_at)
        if any(channel.id in last_times and channel.signed_at < last_times[channel.id] for channel in candidate.channels):
            raise UpdateError("SOURCE_SIGNATURE_ROLLBACK")

def source_key(channel):
    programme = parse_qs(urlsplit(channel.url).query).get('ProgramID', [''])[0]
    return 'p'+programme if re.fullmatch(r'[0-9]{1,20}',programme) else 'n'+m.digest(channel.id.encode())[:24]


def list_snapshot(playlist):
    channels = {}
    for channel in playlist.channels:
        key = source_key(channel)
        if key in channels and channels[key].id != channel.id:
            raise m.FetchError('LIST_CHANNEL_ID_COLLISION')
        channels.setdefault(key,channel)
    return ListSnapshot(playlist,MappingProxyType(channels))


def list_catchup(query):
    begin, end = query.get('playbackbegin'), query.get('playbackend')
    if begin is None and end is None:
        return ''
    if not begin or not end or any(re.fullmatch(r'[0-9]{14}',x) is None for x in (begin[0],end[0])):
        raise m.FetchError('CATCHUP_TIME_INVALID')
    try:
        first = datetime.strptime(begin[0],'%Y%m%d%H%M%S').replace(tzinfo=m.CHINA)
        last = datetime.strptime(end[0],'%Y%m%d%H%M%S').replace(tzinfo=m.CHINA)
    except ValueError:
        raise m.FetchError('CATCHUP_TIME_INVALID') from None
    now = m.utcnow()
    if not first < last or last-first > timedelta(days=1) or first < now-timedelta(days=7) or last > now+timedelta(minutes=5):
        raise m.FetchError('CATCHUP_TIME_OUT_OF_POLICY')
    return '&playbackbegin='+begin[0]+'&playbackend='+end[0]


class ListStore:
    provider = 'published-list'

    def __init__(self, source='auto', client_factory=m.HttpClient, clock=time.monotonic, min_channels=100):
        self.sources = LIST_SOURCES if source=='auto' else (LIST_SOURCES[0 if source=='github' else 1],)
        self.client_factory, self.clock, self.min_channels = client_factory, clock, min_channels
        self.lock = threading.RLock()
        self.pool = BoundedExecutor(1,thread_name_prefix='migu-list',max_pending=1)
        self.snapshot, self.future, self.closed = None,None,False
        self.fresh_until, self.retry_at, self.failures = 0,0,0
        self.last_error, self.updated, self.active_source = None,None,None
        self.fetches = 0

    def _usable(self):
        if self.snapshot is None:
            return False
        try:
            validate_list_candidate(self.snapshot.playlist,min_channels=self.min_channels)
            return True
        except m.UpdateError:
            return False

    def _refresh(self):
        try:
            with self.lock: previous=self.snapshot
            selected = None
            error = 'LIST_UNAVAILABLE'
            for source in self.sources:
                if self.closed:
                    return
                try:
                    raw,_ = self.client_factory('catalogue',attempts=1,timeout=5,budget=8).get(source,limit=m.MAX_BYTES)
                    playlist=parse_source_list(raw)
                    validate_list_candidate(playlist,previous.playlist if previous else None,min_channels=self.min_channels)
                    selected=list_snapshot(playlist)
                    break
                except (ValueError,OSError) as failure:
                    error=str(failure) if isinstance(failure,m.UpdateError) else 'LIST_NETWORK_ERROR'
            if selected is None:
                raise m.FetchError(error)
            with self.lock:
                if self.closed:return
                self.snapshot=selected
                self.active_source='github' if source==LIST_SOURCES[0] else 'upstream-http'
                self.fresh_until=self.clock()+60
                self.retry_at,self.failures,self.last_error=0,0,None
                self.updated=m.iso(m.utcnow())
                self.fetches+=1
        except Exception as failure:
            with self.lock:
                if not self.closed:
                    self.failures+=1
                    self.retry_at=self.clock()+min(60,5*2**min(self.failures-1,4))
                    self.last_error=str(failure) if isinstance(failure,m.UpdateError) else 'LIST_REFRESH_ERROR'
        finally:
            with self.lock:self.future=None

    def get(self,wait=6):
        with self.lock:
            if self.closed:raise m.FetchError('SERVICE_STOPPING')
            usable=self._usable()
            if usable and self.clock()<self.fresh_until:return self.snapshot
            if self.future is None and self.clock()>=self.retry_at:self.future=self.pool.submit(self._refresh)
            if usable:return self.snapshot
            future=self.future
        if future:
            try:future.result(timeout=wait)
            except (FutureTimeout,CancelledError):pass
        with self.lock:
            if self._usable():return self.snapshot
            raise m.FetchError(self.last_error or 'LIST_LOADING')

    def resolve(self,key):
        channel=self.get().channels.get(key)
        if channel is None:raise m.FetchError('MIGU_UNKNOWN_CHANNEL')
        return channel.url

    def status(self):
        with self.lock:
            ready=self._usable()
            return {'provider':self.provider,'catalogue_ready':ready,'channels':len(self.snapshot.channels) if ready else 0,
                    'refreshing':self.future is not None,'source':self.active_source,'updated_utc':self.updated,
                    'last_error':self.last_error,'catalogue_refreshes':self.fetches,'playback_verified':False,
                    'quality':'source-provided','storage':'memory'}

    def close(self):
        with self.lock:self.closed=True
        self.pool.shutdown(wait=False)
