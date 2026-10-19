#!/usr/bin/env python3
"""Migu dynamic service 0.2.1. Generated from the project sources; Python 3.10+."""
from __future__ import annotations

# Shared catalogue validation and bounded transport: update_migu.py
#!/usr/bin/env python3

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import socket
import ssl
import stat
import sys
import tempfile
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, unquote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

DEFAULT_SOURCE = "http://www.52top.com.cn:678/downloads/migu.txt"
MAX_BYTES = 8 * 1024 * 1024
MAX_LINE = 16 * 1024
CHINA = timezone(timedelta(hours=8))
EPG_URLS = (
    "https://develop202.github.io/migu_video/playback.xml",
    "https://raw.githubusercontent.com/develop202/migu_video/refs/heads/main/playback.xml",
)
CATCHUP_SOURCE = "&playbackbegin=${(b)yyyyMMddHHmmss}&playbackend=${(e)yyyyMMddHHmmss}"
EPG_ID_ALIASES = {"上视新闻综合": "上海新闻综合"}
SOURCE_HOSTS = {"www.52top.com.cn", "52top.com.cn", "raw.githubusercontent.com", "develop202.github.io"}
ATTR = re.compile(r'([a-z][a-z0-9-]*)="([^"\r\n]*)"')
CHANNEL_ATTRS = {"tvg-id", "tvg-name", "tvg-logo", "group-title", "svg-id", "svg-name"}
RETRY_STATUS = {408, 429, 500, 502, 503, 504}
NON_ASCII_PRINTABLE = re.compile(r'[^\x20-\x7e]')


class UpdateError(ValueError):
    """Safe messages must never contain remote URLs, response bodies or tokens."""


class FetchError(UpdateError):
    def __init__(self, code, retryable=False, retry_after=None):
        super().__init__(code)
        self.code, self.retryable, self.retry_after = code, retryable, retry_after


def utcnow():
    return datetime.now(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds")


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def clean_text(value):
    # Scan ASCII in C; only inspect Unicode categories for non-printable/non-ASCII characters.
    return not any(unicodedata.category(match[0]) in {"Cc", "Cf", "Cs"} for match in NON_ASCII_PRINTABLE.finditer(value))


def validate_url(url, role):
    """Validate catalogue URLs and every redirect against a fixed trust set."""
    if len(url) > MAX_LINE or not clean_text(url) or any(ch.isspace() for ch in url):
        raise UpdateError("URL_CONTROL_OR_WHITESPACE")
    if any(ch in url for ch in ('|', '\\', '"', '<', '>')) or not clean_text(unquote(url)):
        raise UpdateError("URL_UNSAFE_CHARACTER")
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise UpdateError("URL_INVALID") from None
    host = (parts.hostname or "").lower()
    if parts.scheme not in {"http", "https"} or not host or parts.username is not None or parts.password is not None or parts.fragment:
        raise UpdateError("URL_SCHEME_OR_AUTHORITY")
    if role == "source":
        allowed = host in SOURCE_HOSTS and port in {None, 443}
        if parts.scheme == "http":
            allowed = url == DEFAULT_SOURCE  # Explicit exception for the known legacy source.
    elif role == "api":
        allowed = parts.scheme == "https" and host == "play.miguvideo.com" and port in {None, 443} and parts.path == "/playurl/v1/play/playurl"
    elif role in {"stream", "media"}:
        # The live GSLB redirects to hlszymgsplive.miguvideo.com:8080.
        allowed_ports = {None, 80, 443, 8080} if role == "media" else {None, 80, 443}
        allowed = any(host == domain or host.endswith("." + domain) for domain in ("miguvideo.com", "cmvideo.cn")) and port in allowed_ports
        if role == "stream":
            allowed = allowed and parts.path.endswith(".m3u8")
    elif role == "logo":
        allowed = host == "wapx.cmvideo.cn" and port in {None, 80, 443, 8080}
    else:
        raise UpdateError("URL_UNKNOWN_ROLE")
    if not allowed:
        raise UpdateError("URL_HOST_OR_PORT_NOT_ALLOWED")
    return parts


def parse_attributes(value, channel=False):
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


@dataclass(frozen=True)
class Channel:
    id: str
    name: str
    display: str
    group: str
    logo: str
    url: str
    signed_at: datetime


@dataclass(frozen=True)
class Playlist:
    channels: tuple[Channel, ...]
    catchup: bool
    duplicates_removed: int = 0

    def render(self):
        header = '#EXTM3U x-tvg-url="' + ",".join(EPG_URLS) + '"'
        if self.catchup:
            header += ' catchup="append" catchup-source="' + CATCHUP_SOURCE + '"'
        lines = [header]
        for channel in self.channels:
            attrs = (("tvg-id", channel.id), ("tvg-name", channel.name), ("tvg-logo", channel.logo), ("group-title", channel.group))
            lines.append("#EXTINF:-1 " + " ".join(f'{key}="{value}"' for key, value in attrs if value) + "," + channel.display)
            lines.append(channel.url)  # Never decode, reorder, strip or re-sign playback URLs.
        return ("\n".join(lines) + "\n").encode("utf-8")


def parse_playlist(raw):
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
    header = parse_attributes(lines[0][7:])
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
            attrs, display = parse_attributes(line[len("#EXTINF:-1"):], channel=True)
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
    return Playlist(tuple(channels), catchup, duplicates)


def normalize(raw):
    playlist = parse_playlist(raw)
    return playlist.render(), len(playlist.channels)


def validate_candidate(candidate, previous=None, *, now=None, min_channels=100, min_retention=0.9, max_age_hours=12):
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


class RestrictedRedirect(HTTPRedirectHandler):
    max_redirections = 4
    max_repeats = 2

    def __init__(self, role):
        self.role = role
        self.deadline = None

    def http_error_302(self, req, fp, code, msg, headers):
        # urllib's default implementation drains redirect bodies without a size limit.
        # Close instead; apply our deadline before opening each redirected connection.
        try:
            location = headers.get("Location") or headers.get("URI")
            if location is None:
                raise FetchError("REDIRECT_WITHOUT_LOCATION")
            newurl = urljoin(req.full_url, location)
            redirected = self.redirect_request(req, fp, code, msg, headers, newurl)
            if redirected is None:
                raise FetchError("REDIRECT_METHOD_NOT_ALLOWED")
            visited = dict(getattr(req, "redirect_dict", {}))
            if visited.get(newurl, 0) >= self.max_repeats or sum(visited.values()) >= self.max_redirections:
                raise FetchError("REDIRECT_LIMIT")
            visited[newurl] = visited.get(newurl, 0) + 1
            redirected.redirect_dict = visited
            remaining = self.deadline - time.monotonic() if self.deadline is not None else req.timeout
            if remaining <= 0:
                raise FetchError("FETCH_BUDGET_EXCEEDED")
        finally:
            fp.close()
        return self.parent.open(redirected, timeout=min(req.timeout, remaining))

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_url(newurl, self.role)
        if urlsplit(req.full_url).scheme == "https" and urlsplit(newurl).scheme != "https":
            raise FetchError("HTTPS_DOWNGRADE_BLOCKED")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urlsplit(req.full_url).netloc != urlsplit(newurl).netloc:
            for key in ("If-none-match", "If-modified-since"):
                redirected.remove_header(key)
        return redirected


def retry_delay(value):
    if not value:
        return None
    try:
        result = float(value)
        return max(0.0, result) if result < float("inf") else None
    except ValueError:
        try:
            return max(0.0, (parsedate_to_datetime(value) - utcnow()).total_seconds())
        except (ValueError, TypeError, OverflowError):
            return None


class HttpClient:
    def __init__(self, role="source", attempts=3, timeout=10, budget=45):
        self.role, self.attempts, self.timeout, self.budget = role, attempts, timeout, budget
        self.redirector = RestrictedRedirect(role)
        self.opener = build_opener(self.redirector)  # Inherit proxies and TLS trust.

    def get(self, url, *, headers=None, limit=MAX_BYTES):
        validate_url(url, self.role)
        self.last_url = url
        deadline = time.monotonic() + self.budget
        self.redirector.deadline = deadline
        request_headers = {"User-Agent": "MiguPlaylistUpdater/2.0", "Accept-Encoding": "identity"}
        request_headers.update(headers or {})
        for attempt in range(self.attempts):
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise FetchError("FETCH_BUDGET_EXCEEDED")
                with self.opener.open(Request(url, headers=request_headers), timeout=min(self.timeout, remaining)) as response:
                    validate_url(response.geturl(), self.role)
                    self.last_url = response.geturl()
                    if response.status != 200 or response.headers.get("Content-Encoding", "identity").lower() != "identity":
                        raise FetchError("RESPONSE_STATUS_OR_ENCODING")
                    if "text/html" in response.headers.get("Content-Type", "").lower():
                        raise FetchError("RESPONSE_IS_HTML")
                    try:
                        size = int(response.headers.get("Content-Length", "0"))
                    except ValueError:
                        raise FetchError("CONTENT_LENGTH_INVALID") from None
                    if size < 0 or size > limit:
                        raise FetchError("RESPONSE_TOO_LARGE")
                    chunks, total = [], 0
                    reader = getattr(response, "read1", response.read)
                    while True:
                        if time.monotonic() >= deadline:
                            raise FetchError("FETCH_BUDGET_EXCEEDED")
                        chunk = reader(min(65536, limit + 1 - total))
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > limit:
                            raise FetchError("RESPONSE_TOO_LARGE")
                        chunks.append(chunk)
                    if size and total != size:
                        raise FetchError("RESPONSE_TRUNCATED", retryable=True)
                    return b"".join(chunks), dict(response.headers)
            except HTTPError as error:
                code, after = error.code, error.headers.get("Retry-After")
                error.close()
                if code == 304:
                    return None, {}
                failure = FetchError("HTTP_" + str(code), code in RETRY_STATUS, retry_delay(after))
            except (ssl.SSLError, ssl.CertificateError):
                raise FetchError("TLS_ERROR") from None
            except (URLError, TimeoutError, socket.timeout, OSError, HTTPException) as error:
                reason = getattr(error, "reason", error)
                failure = FetchError("TLS_ERROR" if isinstance(reason, ssl.SSLError) else "NETWORK_ERROR", not isinstance(reason, ssl.SSLError))
            except FetchError as error:
                failure = error
            if not failure.retryable or attempt + 1 >= self.attempts:
                raise failure from None
            delay = failure.retry_after if failure.retry_after is not None else 2 ** attempt
            if delay > 10 or time.monotonic() + delay >= deadline:
                raise failure from None
            time.sleep(delay)
        raise FetchError("FETCH_FAILED")


def atomic_write(output, data):
    output = Path(output)
    if output.is_symlink():
        raise UpdateError("OUTPUT_SYMLINK_NOT_ALLOWED")
    if output.exists() and output.read_bytes() == data:
        return False
    output.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(output.stat().st_mode) if output.exists() else 0o644
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.chmod(temporary, mode)
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def read_json(path):
    try:
        if path.stat().st_size > 65536:
            return {}
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


@contextmanager
def output_lock(output):
    output.parent.mkdir(parents=True, exist_ok=True)
    lock = output.with_name(output.name + ".lock")
    if lock.is_symlink():
        raise UpdateError("LOCK_SYMLINK_NOT_ALLOWED")
    with lock.open("a+b") as handle:
        try:
            if os.name == "nt":
                import msvcrt
                handle.write(b"0")
                handle.flush()
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise UpdateError("UPDATE_ALREADY_RUNNING") from None
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            # Closing releases flock; never unlink the inode while another writer waits.


def safe_validator(value):
    return isinstance(value, str) and 0 < len(value) < 512 and clean_text(value) and value.isascii()


def refresh(args):
    output = args.output
    status_path = args.status or output.with_name(output.stem + "-status.json")
    with output_lock(output):
        previous_raw = output.read_bytes() if output.exists() else None
        previous = parse_playlist(previous_raw) if previous_raw is not None else None
        status = read_json(status_path)
        source_hash = digest(args.source.encode())
        headers = {}
        if previous_raw is not None and status.get("output_sha256") == digest(previous_raw) and status.get("source_sha256") == source_hash:
            for key, name in (("etag", "If-None-Match"), ("last_modified", "If-Modified-Since")):
                if safe_validator(status.get(key)):
                    headers[name] = status[key]
        if args.input:
            with args.input.open("rb") as handle:
                raw = handle.read(MAX_BYTES + 1)
            response_headers = {}
        else:
            raw, response_headers = HttpClient().get(args.source, headers=headers)
            if raw is None:
                if previous is None or not headers:
                    raise UpdateError("UNEXPECTED_NOT_MODIFIED")
                validate_candidate(previous, min_channels=args.min_channels, max_age_hours=args.max_age_hours)
                print("未变化：304；已重新检查本地列表结构和签名时间。")
                return False
        candidate = parse_playlist(raw)
        validate_candidate(candidate, previous, min_channels=args.min_channels, min_retention=0 if args.allow_channel_drop else 0.9, max_age_hours=args.max_age_hours)
        data = candidate.render()
        changed = atomic_write(output, data)
        metadata = {
            "schema_version": 1,
            "output_sha256": digest(data),
            "source_sha256": source_hash,
            "channels": len(candidate.channels),
            "groups": len({channel.group for channel in candidate.channels}),
            "signature_oldest_utc": iso(min(channel.signed_at for channel in candidate.channels)),
            "signature_newest_utc": iso(max(channel.signed_at for channel in candidate.channels)),
            "max_snapshot_age_hours": args.max_age_hours,
            "source_transport": "local" if args.input else urlsplit(args.source).scheme,
            "source_transport_authenticated": not args.input and urlsplit(args.source).scheme == "https",
            "validation": "catalogue_structure_and_freshness_only",
            "playback_verified": False,
        }
        for key, header in (("etag", "etag"), ("last_modified", "last-modified")):
            value = next((v for k, v in response_headers.items() if k.lower() == header), None)
            if safe_validator(value):
                metadata[key] = value
        # No timestamp-only commits. This is a publication record, not a health heartbeat.
        metadata["published_at_utc"] = iso(utcnow()) if changed or status.get("output_sha256") != digest(data) else status.get("published_at_utc", iso(utcnow()))
        atomic_write(status_path, json_bytes(metadata))
        print(f"{'已更新' if changed else '未变化'}：{len(candidate.channels)} 个频道；结构与签名时间检查通过，实际播放未验证。")
        return changed


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--source", default=DEFAULT_SOURCE)
    source.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path, default=Path("migu.m3u8"))
    parser.add_argument("--status", type=Path)
    parser.add_argument("--min-channels", type=int, default=100)
    parser.add_argument("--max-age-hours", type=float, default=12)
    parser.add_argument("--allow-channel-drop", action="store_true", help="Explicitly allow removal/replacement of more than 10%% of channel IDs")
    args = parser.parse_args(argv)
    if args.min_channels < 1 or not 0 < args.max_age_hours <= 168:
        parser.error("min-channels must be positive; max-age-hours must be in (0, 168]")
    targets = [args.output, args.status or args.output.with_name(args.output.stem + "-status.json"), args.output.with_name(args.output.name + ".lock")]
    if len({path.resolve() for path in targets}) != len(targets) or (args.input and args.input.resolve() in {p.resolve() for p in targets[1:]}):
        parser.error("output, status and lock paths must be distinct")
    try:
        refresh(args)
    except UpdateError as error:
        print(f"更新失败：{error}；未用不合格的来源数据覆盖列表。", file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print("更新失败：LOCAL_IO_OR_DATA_ERROR；请检查本地文件和权限。", file=sys.stderr)
        return 1
    return 0

# Capture shared functions before defining the service CLI.
from types import SimpleNamespace as _SharedNamespace
m = _SharedNamespace(**{key: value for key, value in globals().copy().items() if not key.startswith("__")})

# Shared HLS validation: migu/probe.py
def hls_references(raw, base):
    try:
        text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    except UnicodeError:
        raise m.UpdateError("HLS_NOT_UTF8") from None
    if not m.clean_text(text.replace("\n", "")):
        raise m.UpdateError("HLS_CONTROL_CHARACTER")
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    if not lines or lines[0] != "#EXTM3U" or any(len(line) > m.MAX_LINE for line in lines):
        raise m.UpdateError("HLS_HEADER_INVALID")
    master = any(line.startswith("#EXT-X-STREAM-INF:") for line in lines)
    media = any(line.startswith("#EXTINF:") for line in lines)
    if master and media:
        raise m.UpdateError("HLS_MIXED_PLAYLIST")
    references = []
    if master:
        for index, line in enumerate(lines):
            if line.startswith("#EXT-X-STREAM-INF:"):
                if index + 1 >= len(lines) or lines[index + 1].startswith("#"):
                    raise m.UpdateError("HLS_VARIANT_MISSING")
                references.append(urljoin(base, lines[index + 1]))
    elif media:
        if not any(re.fullmatch(r"#EXT-X-TARGETDURATION:[1-9]\d*", line) for line in lines):
            raise m.UpdateError("HLS_TARGET_DURATION_MISSING")
        pending = False
        for line in lines:
            if line.startswith("#EXTINF:"):
                if pending:
                    raise m.UpdateError("HLS_SEGMENT_MISSING")
                try:
                    duration = float(line[len("#EXTINF:"):].split(",", 1)[0])
                except ValueError:
                    raise m.UpdateError("HLS_DURATION_INVALID") from None
                if not 0 < duration < float("inf"):
                    raise m.UpdateError("HLS_DURATION_INVALID")
                pending = True
            elif not line.startswith("#"):
                if not pending:
                    raise m.UpdateError("HLS_SEGMENT_WITHOUT_DURATION")
                references.append(urljoin(base, line))
                pending = False
        if pending:
            raise m.UpdateError("HLS_SEGMENT_MISSING")
    if not references:
        raise m.UpdateError("HLS_EMPTY_PLAYLIST")
    for reference in references:
        m.validate_url(reference, "media")
    return "master" if master else "media", references

# Built-in channel metadata and official API: migu/native.py
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass
import hashlib
import json
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit


BUILTIN_CHANNELS = (
    ('608807420', 'CCTV1综合', '央视'),
    ('631780532', 'CCTV2财经', '央视'),
    ('624878271', 'CCTV3综艺', '央视'),
    ('631780421', 'CCTV4中文国际', '央视'),
    ('641886683', 'CCTV5体育', '央视'),
    ('641886773', 'CCTV5+体育赛事', '央视'),
    ('624878396', 'CCTV6电影', '央视'),
    ('673168121', 'CCTV7国防军事', '央视'),
    ('624878356', 'CCTV8电视剧', '央视'),
    ('673168140', 'CCTV9纪录', '央视'),
    ('624878405', 'CCTV10科教', '央视'),
    ('667987558', 'CCTV11戏曲', '央视'),
    ('673168185', 'CCTV12社会与法', '央视'),
    ('608807423', 'CCTV13新闻', '央视'),
    ('624878440', 'CCTV14少儿', '央视'),
    ('673168223', 'CCTV15音乐', '央视'),
    ('673168256', 'CCTV17农业农村', '央视'),
    ('608807419', 'CCTV4欧洲', '央视'),
    ('608807416', 'CCTV4美洲', '央视'),
    ('609006487', 'CGTN外语纪录', '央视'),
    ('609154345', 'CGTN阿拉伯语', '央视'),
    ('609006450', 'CGTN西班牙语', '央视'),
    ('609006476', 'CGTN法语', '央视'),
    ('609006446', 'CGTN俄语', '央视'),
    ('884121956', '老故事', '央视'),
    ('624878970', '发现之旅', '央视'),
    ('708869532', '中学生', '央视'),
    ('609017205', 'CGTN', '央视'),
    ('646596895', '赛事最经典', '体育'),
    ('629943305', '体坛名栏汇', '体育'),
    ('637444975', '四海钓鱼', '体育'),
    ('956909356', '陕西体育休闲频道', '体育'),
    ('915512915', '24小时城市联赛轮播台', '体育'),
    ('958475359', '武术世界', '体育'),
    ('961930263', '快乐垂钓', '体育'),
    ('651632648', '东方卫视', '卫视'),
    ('623899368', '江苏卫视', '卫视'),
    ('608831231', '广东卫视', '卫视'),
    ('630287636', '北京卫视', '卫视'),
    ('630291707', '辽宁卫视', '卫视'),
    ('962042070', '河北卫视', '卫视'),
    ('783847495', '江西卫视', '卫视'),
    ('790187291', '河南卫视', '卫视'),
    ('738910838', '陕西卫视', '卫视'),
    ('608917627', '大湾区卫视', '卫视'),
    ('947472496', '湖北卫视', '卫视'),
    ('947472500', '吉林卫视', '卫视'),
    ('947472506', '青海卫视', '卫视'),
    ('849116810', '东南卫视', '卫视'),
    ('947472502', '海南卫视', '卫视'),
    ('849119120', '海峡卫视', '卫视'),
    ('956904896', '中国农林卫视', '卫视'),
    ('956923145', '兵团卫视', '卫视'),
    ('738910535', '宁夏卫视', '卫视'),
    ('738910914', '重庆卫视', '卫视'),
    ('961023778', '三沙卫视', '卫视'),
    ('738906901', '黑龙江卫视', '卫视'),
    ('651632657', '上视新闻综合', '地方'),
    ('617290047', '上视东方影视', '地方'),
    ('608780988', '上海第一财经', '地方'),
    ('838109047', '南京新闻综合频道', '地方'),
    ('838153729', '南京教科频道', '地方'),
    ('838151753', '南京十八频道', '地方'),
    ('626064707', '体育休闲频道', '地方'),
    ('626064714', '江苏城市频道', '地方'),
    ('626064674', '江苏国际', '地方'),
    ('628008321', '江苏教育', '地方'),
    ('626064697', '江苏影视频道', '地方'),
    ('626065193', '江苏综艺频道', '地方'),
    ('626064693', '公共新闻频道', '地方'),
    ('639731825', '盐城新闻综合', '地方'),
    ('639731826', '淮安新闻综合', '地方'),
    ('639731818', '泰州新闻综合', '地方'),
    ('639731715', '连云港新闻综合', '地方'),
    ('639731832', '宿迁新闻综合', '地方'),
    ('639731747', '徐州新闻综合', '地方'),
    ('626064703', '优漫卡通频道', '地方'),
    ('955227985', '南通新闻综合', '地方'),
    ('955227996', '宜兴新闻综合', '地方'),
    ('639737327', '溧水新闻综合', '地方'),
    ('956909362', '陕西银龄频道', '地方'),
    ('956909358', '陕西都市青春频道', '地方'),
    ('956909303', '陕西秦腔频道', '地方'),
    ('956909289', '陕西新闻资讯频道', '地方'),
    ('956923159', '财富天下', '地方'),
    ('639731783', '镇江新闻综合', '地方'),
    ('962067517', '海南广播电视总台新闻频道', '地方'),
    ('962045226', '海南广播电视总台自贸频道', '地方'),
    ('962045223', '海南广播电视总台社会与法频道', '地方'),
    ('962067526', '海南广播电视总台文旅频道', '地方'),
    ('962067523', '海南广播电视总台少儿频道', '地方'),
    ('639731952', '广东珠江频道', '地方'),
    ('713600957', '建党105周年巡礼', '影视'),
    ('625703337', '经典香港电影', '影视'),
    ('619495952', '新片放映厅', '影视'),
    ('952383261', 'CHC影迷电影', '影视'),
    ('644368714', 'CHC动作电影', '影视'),
    ('644368373', 'CHC家庭影院', '影视'),
    ('713591450', '和美乡途轮播台', '影视'),
    ('614961829', '南方影视', '影视'),
    ('959986621', '中国天气', '新闻'),
    ('923287154', 'CETV1', '教育'),
    ('923287211', 'CETV2', '教育'),
    ('923287339', 'CETV4', '教育'),
    ('609154353', '山东教育', '教育'),
    ('609158151', '熊猫频道01高清', '熊猫'),
    ('608933610', '熊猫频道1', '熊猫'),
    ('608933640', '熊猫频道2', '熊猫'),
    ('608934619', '熊猫频道3', '熊猫'),
    ('608934721', '熊猫频道4', '熊猫'),
    ('608935104', '熊猫频道5', '熊猫'),
    ('608935797', '熊猫频道6', '熊猫'),
    ('609169286', '熊猫频道7', '熊猫'),
    ('609169287', '熊猫频道8', '熊猫'),
    ('609169226', '熊猫频道9', '熊猫'),
    ('609169285', '熊猫频道10', '熊猫'),
    ('629942228', '最强综艺趴', '综艺'),
    ('614952364', '嘉佳卡通', '少儿'),
    ('629942219', '经典动画大集合', '少儿'),
    ('713589837', '新动力量创一流', '纪实'),
    ('959986618', '中华特产', '纪实'),
    ('958475356', '环球旅游', '纪实'),
    ('961930369', '梨园频道', '纪实'),
)


def native_play_url(pid, client_factory=m.HttpClient):
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
    timestamp = str(int(time.time() * 1000))
    payload = hashlib.md5((timestamp + pid + "26000370").encode()).hexdigest()
    signature = hashlib.md5((payload + "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123").encode()).hexdigest()
    endpoint = ("https://play.miguvideo.com/playurl/v1/play/playurl"
                f"?contId={pid}&rateType=2&timestamp={timestamp}&salt=1230024&sign={signature}")
    headers = {"AppVersion": "2600037000", "TerminalId": "android",
               "X-UP-CLIENT-CHANNEL-ID": "2600037000-99000-200300220100002"}
    # Do not request FLV, H265, HDR or higher paid quality profiles.
    if pid not in {"641886683", "641886773"}:
        headers["appCode"] = "miguvideo_default_android"
    raw, _ = client_factory("api", attempts=1, timeout=8, budget=10).get(endpoint, headers=headers, limit=256 * 1024)
    try:
        data = json.loads(raw)
        body = data.get("body") or {}
        info = body.get("urlInfo") or {}
        reason = data.get("rid", "")
        if reason == "COPYRIGHT_AREA_INVALID":
            raise m.FetchError("MIGU_REGION_RESTRICTED")
        if reason in {"TIPS_NEED_MEMBER", "NEED_LOGIN", "USER_NOT_LOGIN"} or (body.get("auth") or {}).get("authResult") == "FAIL":
            raise m.FetchError("MIGU_LOGIN_OR_MEMBERSHIP_REQUIRED")
        if str(data.get("code")) != "200":
            raise m.FetchError("MIGU_API_REJECTED")
        url = info.get("url")
        if not isinstance(url, str) or not url:
            raise m.FetchError("MIGU_PLAY_URL_MISSING")
        m.validate_url(url, "stream")
        content_pid = str((body.get("content") or {}).get("contId", pid))
        if content_pid != pid:
            raise m.FetchError("MIGU_CHANNEL_MISMATCH")
        query = parse_qs(urlsplit(url).query)
        # Already complete URLs are preserved byte for byte.
        if "ddCalcu" in query:
            return url
        seed = query.get("puData", [""])
        if len(seed) != 1 or re.fullmatch(r"[0-9a-fA-F]{16,128}", seed[0]) is None:
            raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
        seed = seed[0]
        keys = "cdabyzwxkl"
        extra = {1: "v", 2: keys[int(str(m.utcnow().astimezone(m.CHINA).year)[0])], 3: keys[int(pid[6])], 4: "a"}
        proof = "".join(seed[-i-1] + seed[i] + extra.get(i, "") for i in range((len(seed)+1)//2))
        return url + "&ddCalcu=" + proof + "&sv=10004&ct=android"
    except (TypeError, AttributeError, IndexError, json.JSONDecodeError):
        raise m.FetchError("MIGU_API_FORMAT_CHANGED") from None


@dataclass(frozen=True)
class NativeSnapshot:
    playlist: object
    channels: object


class NativeStore:
    """Built-in metadata; bounded, coalesced on-demand resolution, memory only."""
    provider = "migu"

    def __init__(self, resolver=native_play_url, clock=time.monotonic):
        self.resolver, self.clock = resolver, clock
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="migu-api")
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.last_error, self.fetches = False, None, 0
        channels = {"p" + pid: m.Channel(name, name, name, group, "", "", m.utcnow()) for pid, name, group in BUILTIN_CHANNELS}
        self.snapshot = NativeSnapshot(m.Playlist(tuple(channels.values()), False), MappingProxyType(channels))

    def get(self, wait=0):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            return self.snapshot

    def _finish(self, key, future):
        try:
            url, error = future.result(), None
        except Exception as failure:
            url, error = "", str(failure) if isinstance(failure, m.UpdateError) else "MIGU_API_ERROR"
        with self.lock:
            if self.flights.get(key) is not future:
                return
            del self.flights[key]
            self.last_error = error
            self.entries[key] = (self.clock() + (5 if error else 30), url, error)
            while len(self.entries) > 64:
                self.entries.popitem(last=False)

    def resolve(self, key, wait=9):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if key not in self.snapshot.channels:
                raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
            cached = self.entries.get(key)
            if cached and cached[0] > self.clock():
                self.entries.move_to_end(key)
                if cached[2]:
                    raise m.FetchError(cached[2])
                return cached[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 8:
                    raise m.FetchError("MIGU_API_CAPACITY")
                future = self.pool.submit(self.resolver, key[1:])
                self.flights[key] = future
                self.fetches += 1
                future.add_done_callback(lambda done: self._finish(key, done))
        try:
            return future.result(timeout=wait)
        except FutureTimeout:
            raise m.FetchError("MIGU_API_LOADING") from None
        except m.UpdateError:
            raise
        except Exception:
            raise m.FetchError("MIGU_API_ERROR") from None

    def status(self):
        with self.lock:
            return {"provider": self.provider, "catalogue_ready": True, "channels": len(self.snapshot.channels),
                    "source_transport": "https", "last_error": self.last_error, "api_requests": self.fetches,
                    "playback_verified": False, "quality": "anonymous-SD", "storage": "memory"}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)

# Service implementation: migu/service.py
import argparse
from collections import OrderedDict, deque
from contextlib import nullcontext
from concurrent.futures import CancelledError, ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass, replace
from datetime import datetime, timedelta
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sys
import tempfile
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urljoin, urlsplit


VERSION = "0.2.1"
DEFAULT_PORT = 18768
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,128}")
URI_ATTRIBUTE = re.compile(r'(?<![\w-])URI="([^"\r\n]*)"')


class ServiceError(Exception):
    def __init__(self, code, status=503):
        super().__init__(code)
        self.code, self.status = code, status


class Diagnostics:
    """Small per-service ring; only fixed event codes, never exception text/URLs."""
    def __init__(self, clock=time.monotonic):
        self.clock, self.lock = clock, threading.Lock()
        self.events, self.last = deque(maxlen=120), OrderedDict()

    def record(self, code):
        if not isinstance(code, str) or re.fullmatch(r"[A-Z][A-Z0-9_]{0,79}", code) is None:
            code = "UNCLASSIFIED_ERROR"
        now = self.clock()
        with self.lock:
            if code in self.last and now - self.last[code] < 15:
                return
            self.last[code] = now
            self.last.move_to_end(code)
            while len(self.last) > 64:
                self.last.popitem(last=False)
            line = {"time_utc": m.iso(m.utcnow()), "code": code}
            self.events.append(line)
        try:
            print(f"[{line['time_utc']}] {code}", flush=True)
        except (OSError, ValueError):
            pass  # A closed app console must not interrupt serving a player.

    def snapshot(self):
        with self.lock:
            return list(self.events)


def read_private(path, limit):
    if path.is_symlink():
        raise ServiceError("CACHE_SYMLINK_NOT_ALLOWED")
    with path.open("rb") as handle:
        raw = handle.read(limit + 1)
    if len(raw) > limit:
        raise ServiceError("CACHE_TOO_LARGE")
    return raw


def private_write(path, data):
    if path.is_symlink():
        raise ServiceError("CACHE_SYMLINK_NOT_ALLOWED")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)  # 0600; never use the public updater's 0644 default.
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def load_access_token(directory, variable=None):
    if variable:
        if re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", variable) is None:
            raise ServiceError("TOKEN_ENV_NAME_INVALID")
        token = os.environ.get(variable, "")
    else:
        path = directory / "access.token"
        try:
            token = read_private(path, 256).decode("ascii").strip()
            if os.name != "nt":
                os.chmod(path, 0o600)
        except FileNotFoundError:
            token = secrets.token_urlsafe(32)
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="ascii") as handle:
                handle.write(token + "\n")
                handle.flush()
                os.fsync(handle.fileno())
    if TOKEN_PATTERN.fullmatch(token) is None:
        raise ServiceError("TOKEN_MUST_BE_32_TO_128_URLSAFE_CHARACTERS")
    return token


def channel_key(channel):
    programme = parse_qs(urlsplit(channel.url).query).get("ProgramID", [""])[0]
    return "p" + programme if re.fullmatch(r"\d{1,20}", programme) else "n" + m.digest(channel.id.encode())[:24]


@dataclass(frozen=True)
class Snapshot:
    playlist: m.Playlist
    channels: object
    raw: bytes


def make_snapshot(playlist):
    channels = {}
    for channel in playlist.channels:
        key = channel_key(channel)
        if key in channels and channels[key].id != channel.id:
            raise ServiceError("CHANNEL_ID_COLLISION")
        channels.setdefault(key, channel)
    return Snapshot(playlist, MappingProxyType(channels), playlist.render())


class CatalogueStore:
    """One bounded source refresh, shared by all channels and all viewers."""
    def __init__(self, directory, *, source=m.DEFAULT_SOURCE, input_path=None, refresh_seconds=60,
                 max_age_hours=12, min_channels=100, client_factory=m.HttpClient, clock=time.monotonic):
        self.directory, self.source, self.input_path = directory, source, input_path
        self.refresh_seconds, self.max_age_hours, self.min_channels = refresh_seconds, max_age_hours, min_channels
        self.client_factory, self.clock = client_factory, clock
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="migu-catalogue")
        self.future, self.snapshot, self.closed = None, None, False
        self.fresh_until, self.retry_at, self.failures = 0, 0, 0
        self.last_error, self.refreshes, self.last_success = None, 0, None
        self.cache = directory / "catalogue.m3u8"
        self.meta_path = directory / "catalogue-meta.json"
        self.source_id = m.digest(("file:" + str(input_path.resolve()) if input_path else source).encode())
        try:
            candidate = m.parse_playlist(read_private(self.cache, m.MAX_BYTES))
            self._validate(candidate)
            self.snapshot = make_snapshot(candidate)
        except (OSError, ValueError, ServiceError):
            pass  # Startup never describes an expired or malformed disk cache as usable.

    def _validate(self, candidate, previous=None):
        m.validate_candidate(candidate, previous, min_channels=self.min_channels, max_age_hours=self.max_age_hours)

    def _usable(self, snapshot):
        if snapshot is None:
            return False
        try:
            self._validate(snapshot.playlist)
            return True
        except m.UpdateError:
            return False

    def _refresh(self):
        try:
            with self.lock:
                previous = self.snapshot
            metadata = m.read_json(self.meta_path) if not self.meta_path.is_symlink() else {}
            headers = {}
            if previous and metadata.get("source_sha256") == self.source_id and metadata.get("output_sha256") == m.digest(previous.raw):
                for key, name in (("etag", "If-None-Match"), ("last_modified", "If-Modified-Since")):
                    if m.safe_validator(metadata.get(key)):
                        headers[name] = metadata[key]
            if self.input_path:
                raw, response_headers = read_private(self.input_path, m.MAX_BYTES), {}
            else:
                client = self.client_factory(attempts=2, timeout=6, budget=15)
                raw, response_headers = client.get(self.source, headers=headers)
            if raw is None:
                if previous is None or not headers:
                    raise ServiceError("UNEXPECTED_NOT_MODIFIED")
                candidate = previous.playlist
            else:
                candidate = m.parse_playlist(raw)
            self._validate(candidate, previous.playlist if previous else None)
            snapshot = make_snapshot(candidate)
            metadata = {"source_sha256": self.source_id, "output_sha256": m.digest(snapshot.raw)}
            for key, header in (("etag", "etag"), ("last_modified", "last-modified")):
                value = next((value for name, value in response_headers.items() if name.lower() == header), None)
                if raw is None:
                    value = headers.get("If-None-Match" if key == "etag" else "If-Modified-Since")
                if m.safe_validator(value):
                    metadata[key] = value
            with self.lock:
                if self.closed:
                    return
            # Disk failure leaves the previous in-memory generation untouched.
            if previous is None or previous.raw != snapshot.raw:
                private_write(self.cache, snapshot.raw)
            encoded_metadata = m.json_bytes(metadata)
            if not self.meta_path.exists() or read_private(self.meta_path, 65536) != encoded_metadata:
                private_write(self.meta_path, encoded_metadata)
            with self.lock:
                self.snapshot = snapshot
                self.fresh_until = self.clock() + self.refresh_seconds
                self.failures, self.retry_at, self.last_error = 0, 0, None
                self.refreshes += 1
                self.last_success = m.iso(m.utcnow())
        except Exception as error:
            with self.lock:
                self.failures += 1
                self.retry_at = self.clock() + min(60, 5 * 2 ** min(self.failures - 1, 4))
                self.last_error = str(error) if isinstance(error, (m.UpdateError, ServiceError)) else "SOURCE_OR_CACHE_ERROR"
        finally:
            with self.lock:
                self.future = None

    def get(self, wait=5):
        with self.lock:
            if self.closed:
                raise ServiceError("SERVICE_STOPPING")
            usable = self.snapshot if self._usable(self.snapshot) else None
            now = self.clock()
            if usable and now < self.fresh_until:
                return usable
            if self.future is None and now >= self.retry_at:
                self.future = self.pool.submit(self._refresh)
            future = self.future
            if usable:
                return usable  # stale-while-refresh, within absolute signature-age policy only.
        if future is not None:
            try:
                future.result(timeout=wait)
            except FutureTimeout:
                raise ServiceError("CATALOGUE_LOADING") from None
            except CancelledError:
                raise ServiceError("SERVICE_STOPPING") from None
        with self.lock:
            if self._usable(self.snapshot):
                return self.snapshot
            raise ServiceError(self.last_error or "CATALOGUE_UNAVAILABLE")

    def status(self):
        with self.lock:
            ready = self._usable(self.snapshot)
            return {"catalogue_ready": ready, "channels": len(self.snapshot.channels) if ready else 0,
                    "refreshing": self.future is not None, "refreshes": self.refreshes,
                    "last_source_success_utc": self.last_success, "last_error": self.last_error,
                    "source_transport": "local" if self.input_path else urlsplit(self.source).scheme,
                    "playback_verified": False}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)


def rewrite_manifest(raw, final_url):
    hls_references(raw, final_url)  # Reject HTML/empty/truncated or non-media catalogues.
    text = raw.decode("utf-8-sig").replace("\r\n", "\n")

    def absolute(value):
        resolved = urljoin(final_url, value)
        m.validate_url(resolved, "media")
        return resolved

    lines = []
    for line in text.splitlines():
        if line and not line.startswith("#"):
            line = absolute(line)
        elif line.startswith("#"):
            line = URI_ATTRIBUTE.sub(lambda match: 'URI="' + absolute(match[1]) + '"', line)
        lines.append(line)
    return ("\n".join(lines) + "\n").encode("utf-8")


class ManifestCache:
    """At most four fetches/eight pending keys; bounded shared results and failures."""
    def __init__(self, client_factory=m.HttpClient, clock=time.monotonic):
        self.client_factory, self.clock = client_factory, clock
        self.lock = threading.RLock()
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="migu-manifest")
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.bytes, self.fetches = False, 0, 0

    def _fetch(self, url):
        client = self.client_factory("media", attempts=1, timeout=8, budget=12)
        raw, _ = client.get(url, limit=512 * 1024)
        if raw is None:
            raise ServiceError("UPSTREAM_UNEXPECTED_304", 502)
        return rewrite_manifest(raw, client.last_url)

    def _finish(self, key, future):
        try:
            data, error = future.result(), None
        except Exception as failure:
            data = b""
            error = str(failure) if isinstance(failure, (m.UpdateError, ServiceError)) else "UPSTREAM_ERROR"
        with self.lock:
            if self.flights.get(key) is not future:
                return
            del self.flights[key]
            old = self.entries.pop(key, None)
            self.bytes -= len(old[1]) if old else 0
            self.entries[key] = (self.clock() + (3 if error else 1), data, error)
            self.bytes += len(data)
            while len(self.entries) > 32 or self.bytes > 8 * 1024 * 1024:
                _, removed = self.entries.popitem(last=False)
                self.bytes -= len(removed[1])

    def get(self, url, wait=9):
        key = m.digest(url.encode())
        with self.lock:
            if self.closed:
                raise ServiceError("SERVICE_STOPPING")
            entry = self.entries.get(key)
            if entry and entry[0] > self.clock():
                self.entries.move_to_end(key)
                if entry[2]:
                    raise ServiceError(entry[2], 502)
                return entry[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 8:
                    raise ServiceError("MANIFEST_CAPACITY")
                future = self.pool.submit(self._fetch, url)
                self.flights[key] = future
                self.fetches += 1
                future.add_done_callback(lambda done: self._finish(key, done))
        try:
            data, error = future.result(timeout=wait), None
        except FutureTimeout:
            raise ServiceError("MANIFEST_LOADING") from None
        except CancelledError:
            raise ServiceError("SERVICE_STOPPING") from None
        except (OSError, ValueError, ServiceError) as failure:
            data = b""
            error = str(failure) if isinstance(failure, (m.UpdateError, ServiceError)) else "UPSTREAM_ERROR"
        if error:
            raise ServiceError(error, 502)
        return data

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)


def catchup_suffix(query):
    start, end = query.get("playbackbegin"), query.get("playbackend")
    if not start and not end:
        return ""
    if not start or not end or any(re.fullmatch(r"\d{14}", value) is None for value in (start[0], end[0])):
        raise ServiceError("CATCHUP_TIME_INVALID", 400)
    try:
        begin = datetime.strptime(start[0], "%Y%m%d%H%M%S").replace(tzinfo=m.CHINA)
        finish = datetime.strptime(end[0], "%Y%m%d%H%M%S").replace(tzinfo=m.CHINA)
    except ValueError:
        raise ServiceError("CATCHUP_TIME_INVALID", 400) from None
    now = m.utcnow()
    if not begin < finish or finish - begin > timedelta(days=1) or begin < now - timedelta(days=7) or finish > now + timedelta(minutes=5):
        raise ServiceError("CATCHUP_TIME_OUT_OF_POLICY", 400)
    return "&playbackbegin=" + start[0] + "&playbackend=" + end[0]


class Service:
    def __init__(self, store, token, public_base, mode="redirect", manifests=None, require_token=True):
        self.store, self.token, self.public_base, self.mode = store, token, public_base.rstrip("/"), mode
        self.manifests = manifests or ManifestCache()
        self.require_token = require_token
        self.diagnostics = Diagnostics()

    def catalogue(self, snapshot):
        suffix = "?token=" + self.token if self.require_token else ""
        channels = [replace(channel, url=f"{self.public_base}/live/{key}.m3u8{suffix}") for key, channel in snapshot.channels.items()]
        rendered = m.Playlist(tuple(channels), snapshot.playlist.catchup).render()
        if getattr(self.store, "provider", None) == "migu":
            # Native mode has no external EPG dependency and advertises no unverified catchup.
            rendered = b"#EXTM3U\n" + rendered.split(b"\n", 1)[1]
        if not self.require_token:
            rendered = rendered.replace(('catchup-source="' + m.CATCHUP_SOURCE).encode(), ('catchup-source="?' + m.CATCHUP_SOURCE[1:]).encode(), 1)
        return rendered

    def close(self):
        self.store.close()
        self.manifests.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "migu-live/" + VERSION
    sys_version = ""

    def log_message(self, *args):
        pass  # Query strings contain the access token; never use the default access log.

    def send_body(self, status, data=b"", mime="application/json; charset=utf-8", **headers):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Connection", "close")
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        service = self.server.service
        try:
            if len(self.path) > 4096:
                raise ServiceError("REQUEST_TOO_LONG", 414)
            parts = urlsplit(self.path)
            query = parse_qs(parts.query, keep_blank_values=True, max_num_fields=4)
            if parts.scheme or parts.netloc or parts.fragment or set(query) - {"token", "playbackbegin", "playbackend"} or any(len(values) != 1 for values in query.values()):
                raise ServiceError("REQUEST_INVALID", 400)
            hosts = self.headers.get_all("Host", [])
            if len(hosts) != 1:
                raise ServiceError("HOST_REQUIRED", 400)
            if not service.require_token:
                port = self.server.server_address[1]
                allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
                if port == 80:
                    allowed_hosts |= {"127.0.0.1", "localhost"}
                if hosts[0].lower() not in allowed_hosts:
                    raise ServiceError("LOCAL_HOST_REQUIRED", 403)
                origin = self.headers.get("Origin")
                if (origin and urlsplit(origin).netloc.lower() not in allowed_hosts) or self.headers.get("Sec-Fetch-Site") == "cross-site":
                    raise ServiceError("LOCAL_ORIGIN_REQUIRED", 403)
            authorization = self.headers.get_all("Authorization", [])
            if len(authorization) > 1:
                raise ServiceError("AUTH_REQUIRED", 401)
            bearer = authorization[0].removeprefix("Bearer ") if authorization and authorization[0].startswith("Bearer ") else ""
            query_token = query.get("token", [""])[0]
            supplied = query_token or bearer
            if service.require_token and (not TOKEN_PATTERN.fullmatch(supplied) or not hmac.compare_digest(service.token, supplied) or (bearer and query_token and not hmac.compare_digest(bearer, query_token))):
                raise ServiceError("AUTH_REQUIRED", 401)
            if parts.path == "/diag":
                self.send_body(200, m.json_bytes({"service": "migu-live", "version": VERSION,
                    "status": service.store.status(), "events": service.diagnostics.snapshot()}))
                return
            if parts.path in {"/", "/health", "/status"}:
                self.send_body(200, m.json_bytes({"service": "migu-live", "version": VERSION, "process_up": True, "mode": service.mode, **service.store.status()}))
                return
            if parts.path not in {"/all.m3u", "/migu.m3u8"} and re.fullmatch(r"/live/[pn][0-9a-f]{1,24}\.m3u8", parts.path) is None:
                raise ServiceError("NOT_FOUND", 404)
            snapshot = service.store.get()
            if parts.path in {"/all.m3u", "/migu.m3u8"}:
                self.send_body(200, service.catalogue(snapshot), "application/vnd.apple.mpegurl; charset=utf-8")
                return
            key = parts.path[len("/live/"):-len(".m3u8")]
            channel = snapshot.channels.get(key)
            if channel is None:
                raise ServiceError("CHANNEL_NOT_FOUND", 404)
            suffix = catchup_suffix(query)
            if suffix and not snapshot.playlist.catchup:
                raise ServiceError("CATCHUP_UNAVAILABLE", 400)
            url = service.store.resolve(key) if getattr(service.store, "provider", None) == "migu" else channel.url + suffix
            m.validate_url(url, "media")
            if service.mode == "redirect":
                self.send_body(302, Location=url)
            else:
                self.send_body(200, service.manifests.get(url), "application/vnd.apple.mpegurl; charset=utf-8")
        except ServiceError as error:
            if error.status >= 500:
                service.diagnostics.record(error.code)
            self.send_body(error.status, m.json_bytes({"error": error.code}), **({"Retry_After": "3"} if error.status == 503 else {}))
        except m.UpdateError as error:
            service.diagnostics.record(str(error))
            self.send_body(502, m.json_bytes({"error": str(error)}))
        except (ValueError, OSError):
            self.send_body(400, m.json_bytes({"error": "REQUEST_OR_IO_ERROR"}))


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address, service, max_clients=32):
        if not service.require_token and address[0] != "127.0.0.1":
            raise ServiceError("NON_LOOPBACK_REQUIRES_TOKEN")
        self.service = service
        self.slots = threading.BoundedSemaphore(max_clients)
        super().__init__(address, Handler)

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(10)
        return sock, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: 3\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # Socket errors must not print a traceback containing request context.


def stop_from_signal(*unused):
    raise KeyboardInterrupt()


def service_data_directory(explicit=None):
    """Never assume the app's current working directory is writable."""
    directory = explicit or Path.home() / ".cache" / "migu-live"
    if directory.is_symlink():
        raise ServiceError("DATA_DIRECTORY_SYMLINK_NOT_ALLOWED")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryFile(dir=directory) as handle:
        handle.write(b"probe")
        handle.flush()
    return directory


def startup_error(stage, error):
    code = str(error) if isinstance(error, (ServiceError, m.UpdateError)) else type(error).__name__
    number = getattr(error, "errno", None)
    print(f"Startup failed [{stage}]: {code}" + (f" (errno={number}: {os.strerror(number)})" if number else ""), file=sys.stderr, flush=True)
    if stage == "bind":
        print("端口可能被占用，或当前 App 不允许本地监听；可尝试其他端口。", file=sys.stderr)
    elif stage in {"data-directory", "cache-lock", "access-token"}:
        print("请检查 App 的可写目录；默认官方取源、仅本机访问无需缓存目录或文件锁。", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int, nargs="?", default=DEFAULT_PORT)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--public-base", help="Fixed external URL; never inferred from Host/Forwarded headers")
    parser.add_argument("--data-dir", type=Path, help="Private writable cache directory; native local mode writes no files")
    parser.add_argument("--token-env", help="Explicit environment variable holding a URL-safe access token")
    parser.add_argument("--require-token", action="store_true", help="Also require a token for local-only requests")
    parser.add_argument("--mode", choices=("redirect", "manifest"), default="redirect")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--source", help="Explicit legacy catalogue URL; default uses built-in official Migu API")
    source.add_argument("--input", type=Path)
    parser.add_argument("--refresh-seconds", type=float, default=60)
    parser.add_argument("--max-age-hours", type=float, default=12)
    parser.add_argument("--min-channels", type=int, default=100)
    args = parser.parse_args(argv)
    stage = "configuration"
    try:
        address = ipaddress.IPv4Address(args.bind)
        if not 1 <= args.port <= 65535 or not 5 <= args.refresh_seconds <= 3600 or not 0 < args.max_age_hours <= 168 or args.min_channels < 1:
            parser.error("port, refresh interval, age policy or minimum channel count is invalid")
        base = args.public_base or f"http://{args.bind}:{args.port}"
        parts = urlsplit(base)
        if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username is not None or parts.password is not None or parts.query or parts.fragment or not m.clean_text(base) or any(ch.isspace() or ch in ('"', '<', '>', '\\') for ch in base):
            parser.error("public-base must be a fixed HTTP(S) URL without credentials/query/fragment")
        if not address.is_loopback and not args.public_base:
            parser.error("non-loopback bind requires an explicit --public-base")
        if args.source:
            m.validate_url(args.source, "source")
        try:
            public_loopback = ipaddress.ip_address(parts.hostname).is_loopback
        except ValueError:
            public_loopback = parts.hostname == "localhost"
        require_token = args.require_token or bool(args.token_env) or not address.is_loopback or not public_loopback
        legacy = bool(args.source or args.input)
        if legacy or (require_token and not args.token_env):
            stage = "data-directory"
            args.data_dir = service_data_directory(args.data_dir)
        stage = "access-token"
        token = load_access_token(args.data_dir, args.token_env) if require_token else ""
        stage = "cache-lock"
        with m.output_lock(args.data_dir / "runtime") if legacy else nullcontext():
            stage = "provider"
            store = CatalogueStore(args.data_dir, source=args.source or m.DEFAULT_SOURCE, input_path=args.input, refresh_seconds=args.refresh_seconds, max_age_hours=args.max_age_hours, min_channels=args.min_channels) if legacy else NativeStore()
            service = Service(store, token, base, args.mode, require_token=require_token)
            try:
                stage = "bind"
                server = BoundedServer((args.bind, args.port), service)
                previous_signal = None
                try:
                    if threading.current_thread() is threading.main_thread():
                        previous_signal = signal.signal(signal.SIGTERM, stop_from_signal)
                except (OSError, ValueError, AttributeError):
                    print("当前运行环境不支持 SIGTERM；请使用 App 的停止按钮。", file=sys.stderr)
                print(f"migu-live {VERSION}; provider={'legacy' if legacy else 'official-api'}; mode={args.mode}; listening={args.bind}:{args.port}", flush=True)
                print(f"[系统] HTTP 服务启动成功；{'第三方列表按需加载' if legacy else '内置频道 ' + str(len(store.get().channels)) + ' 个，官方取源按需进行'}。", flush=True)
                print(f"Subscription: {base.rstrip('/')}/all.m3u" + ("?token=<access-token>" if require_token else ""), flush=True)
                print(f"Diagnostics: {base.rstrip('/')}/diag" + ("?token=<access-token>" if require_token else ""), flush=True)
                service.diagnostics.record("HTTP_SERVER_STARTED")
                if require_token:
                    print("Token: explicit environment variable" if args.token_env else f"Token file: {args.data_dir / 'access.token'}", flush=True)
                try:
                    stage = "serve"
                    server.serve_forever(poll_interval=0.2)
                finally:
                    server.server_close()
                    if previous_signal is not None:
                        signal.signal(signal.SIGTERM, previous_signal)
            finally:
                service.close()
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, ServiceError, RuntimeError, ImportError) as error:
        startup_error(stage, error)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
