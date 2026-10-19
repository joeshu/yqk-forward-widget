#!/usr/bin/env python3
"""Migu dynamic service 0.1.0. Generated from the project sources; Python 3.10+."""
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

# Service implementation: migu/service.py
import argparse
from collections import OrderedDict
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


VERSION = "0.1.0"
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,128}")
URI_ATTRIBUTE = re.compile(r'(?<![\w-])URI="([^"\r\n]*)"')


class ServiceError(Exception):
    def __init__(self, code, status=503):
        super().__init__(code)
        self.code, self.status = code, status


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

    def catalogue(self, snapshot):
        suffix = "?token=" + self.token if self.require_token else ""
        channels = [replace(channel, url=f"{self.public_base}/live/{key}.m3u8{suffix}") for key, channel in snapshot.channels.items()]
        rendered = m.Playlist(tuple(channels), snapshot.playlist.catchup).render()
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
        try:
            if len(self.path) > 4096:
                raise ServiceError("REQUEST_TOO_LONG", 414)
            parts = urlsplit(self.path)
            query = parse_qs(parts.query, keep_blank_values=True, max_num_fields=4)
            if parts.scheme or parts.netloc or parts.fragment or set(query) - {"token", "playbackbegin", "playbackend"} or any(len(values) != 1 for values in query.values()):
                raise ServiceError("REQUEST_INVALID", 400)
            service = self.server.service
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
            url = channel.url + suffix
            m.validate_url(url, "media")
            if service.mode == "redirect":
                self.send_body(302, Location=url)
            else:
                self.send_body(200, service.manifests.get(url), "application/vnd.apple.mpegurl; charset=utf-8")
        except ServiceError as error:
            self.send_body(error.status, m.json_bytes({"error": error.code}), **({"Retry_After": "3"} if error.status == 503 else {}))
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


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int, nargs="?", default=18768)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--public-base", help="Fixed external URL; never inferred from Host/Forwarded headers")
    parser.add_argument("--data-dir", type=Path, default=Path("migu-live-data"))
    parser.add_argument("--token-env", help="Explicit environment variable holding a URL-safe access token")
    parser.add_argument("--require-token", action="store_true", help="Also require a token for local-only requests")
    parser.add_argument("--mode", choices=("redirect", "manifest"), default="redirect")
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--source", default=m.DEFAULT_SOURCE)
    source.add_argument("--input", type=Path)
    parser.add_argument("--refresh-seconds", type=float, default=60)
    parser.add_argument("--max-age-hours", type=float, default=12)
    parser.add_argument("--min-channels", type=int, default=100)
    args = parser.parse_args(argv)
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
        if not args.input:
            m.validate_url(args.source, "source")
        if args.data_dir.is_symlink():
            raise ServiceError("DATA_DIRECTORY_SYMLINK_NOT_ALLOWED")
        args.data_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            public_loopback = ipaddress.ip_address(parts.hostname).is_loopback
        except ValueError:
            public_loopback = parts.hostname == "localhost"
        require_token = args.require_token or bool(args.token_env) or not address.is_loopback or not public_loopback
        token = load_access_token(args.data_dir, args.token_env) if require_token else ""
        with m.output_lock(args.data_dir / "runtime"):
            store = CatalogueStore(args.data_dir, source=args.source, input_path=args.input, refresh_seconds=args.refresh_seconds, max_age_hours=args.max_age_hours, min_channels=args.min_channels)
            service = Service(store, token, base, args.mode, require_token=require_token)
            try:
                server = BoundedServer((args.bind, args.port), service)
                if threading.current_thread() is threading.main_thread():
                    signal.signal(signal.SIGTERM, stop_from_signal)
                print(f"migu-live {VERSION}; mode={args.mode}; listening={args.bind}:{args.port}", flush=True)
                print(f"Subscription: {base.rstrip('/')}/all.m3u" + ("?token=<access-token>" if require_token else ""), flush=True)
                if require_token:
                    print("Token: explicit environment variable" if args.token_env else f"Token file: {args.data_dir / 'access.token'}", flush=True)
                try:
                    server.serve_forever(poll_interval=0.2)
                finally:
                    server.server_close()
            finally:
                service.close()
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError, ServiceError):
        print("Startup failed: check bind, private data directory, access token and source policy.", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
