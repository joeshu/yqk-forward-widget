#!/usr/bin/env python3
"""Validate and refresh the Migu IPTV catalogue. Python 3.10+, standard library only."""
from __future__ import annotations

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


if __name__ == "__main__":
    raise SystemExit(main())
