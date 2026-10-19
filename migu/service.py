"""Local Migu catalogue service. No account registration or media-segment proxy."""
from __future__ import annotations

import argparse
from collections import OrderedDict
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

import update_migu as m
from migu.probe import hls_references
from migu.native import NativeStore

VERSION = "0.2.0"
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
            url = service.store.resolve(key) if getattr(service.store, "provider", None) == "migu" else channel.url + suffix
            m.validate_url(url, "media")
            if service.mode == "redirect":
                self.send_body(302, Location=url)
            else:
                self.send_body(200, service.manifests.get(url), "application/vnd.apple.mpegurl; charset=utf-8")
        except ServiceError as error:
            self.send_body(error.status, m.json_bytes({"error": error.code}), **({"Retry_After": "3"} if error.status == 503 else {}))
        except m.UpdateError as error:
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
    parser.add_argument("port", type=int, nargs="?", default=18768)
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
                print(f"Subscription: {base.rstrip('/')}/all.m3u" + ("?token=<access-token>" if require_token else ""), flush=True)
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
