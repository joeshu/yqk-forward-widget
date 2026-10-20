"""Local Migu catalogue service. No account registration or media-segment proxy."""
from __future__ import annotations

import argparse
from collections import OrderedDict, deque
from concurrent.futures import CancelledError, TimeoutError as FutureTimeout
import socket
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
from urllib.parse import parse_qs, urljoin, urlsplit

from migu import core as m
from migu.core import hls_references
from migu.native import NativeStore
from migu.android import AndroidStore
from migu.source import ListStore, CATCHUP_SOURCE, list_catchup
from migu.epg import EpgStore
from migu.workers import BoundedExecutor

VERSION = "0.8.3"
DEFAULT_PORT = 18768
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,128}")
EVENT_MESSAGES = {
    "HTTP_SERVER_STARTED": "本地 HTTP 服务已启动",
    "MIGU_REGION_RESTRICTED": "咪咕限制当前出口地区",
    "MIGU_LOGIN_OR_MEMBERSHIP_REQUIRED": "上游授权拒绝，需核对具体原因",
    "MIGU_AUTHORIZATION_REJECTED": "咪咕拒绝当前播放授权；不能仅凭此判定需要会员",
    "MIGU_LOGIN_REQUIRED": "咪咕明确要求登录",
    "MIGU_MEMBERSHIP_REQUIRED": "咪咕明确返回会员权限要求",
    "MIGU_API_FORMAT_CHANGED": "咪咕接口格式变化，需要更新适配",
    "MIGU_PLAY_URL_FORMAT_CHANGED": "播放地址格式变化，需要更新适配",
    "MIGU_TERMINAL_BLOCKED": "咪咕拒绝当前客户端/终端标识，需上游确认该客户端是否仍被允许",
    "MIGU_COPYRIGHT_SHIELD": "咪咕按节目版权临时屏蔽，节目结束后可能恢复",
    "MIGU_RESOLVE_BURST_LIMIT": "解析请求过于密集，已暂停，稍后重试",
    "NETWORK_ERROR": "网络连接失败或请求超时",
    "TLS_ERROR": "TLS 证书校验失败",
    "EPG_LOADING": "节目单正在后台加载，请稍后刷新",
    "EPG_EMPTY_OR_UNAVAILABLE": "暂未取得有效节目单，请查看节目单状态",
    "LIST_LOADING": "频道列表正在加载，请稍后重试",
    "SOURCE_SNAPSHOT_TOO_OLD": "频道快照已过期，正在尝试原始列表源",
    "EPG_DISABLED": "节目单已关闭",
}
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

    def record(self, code, details=None):
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
            line = {"time_utc": m.iso(m.utcnow()), "code": code, "message": EVENT_MESSAGES.get(code, "")}
            if details:
                line['upstream'] = {key: value for key, value in details.items() if key in {'channel_id','api_code','rid','auth_result','logged_in','has_play_url','returned_quality'} and (type(value) is bool or value is None or (isinstance(value,str) and re.fullmatch(r'[A-Z0-9_]{1,80}',value)))}
            self.events.append(line)
        try:
            print(f"[{line['time_utc']}] {code} {line['message']}" + (" " + json.dumps(line["upstream"],ensure_ascii=False,sort_keys=True) if "upstream" in line else ""), flush=True)
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
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-manifest")
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
            if self.closed or self.flights.get(key) is not future:
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

class Service:
    def __init__(self, store, token, public_base, mode="redirect", manifests=None, require_token=True, epg=None):
        self.store, self.token, self.public_base, self.mode = store, token, public_base.rstrip("/"), mode
        self.manifests = manifests or ManifestCache()
        self.require_token = require_token
        self.diagnostics = Diagnostics()
        self.epg = epg or EpgStore()
        self.runtime = {"network_concurrency": 8, "python": sys.version.split()[0], "platform": sys.platform,
                        "main_thread": threading.current_thread() is threading.main_thread()}

    def catalogue(self, snapshot):
        suffix = "?token=" + self.token if self.require_token else ""
        epg_url = f'{self.public_base}/epg.xml{suffix}'
        header = '#EXTM3U' + (f' x-tvg-url="{epg_url}"' if self.epg.enabled else '')
        if getattr(snapshot.playlist, 'catchup', False):
            header += ' catchup="append" catchup-source="' + ('&' if self.require_token else '?') + CATCHUP_SOURCE[1:] + '"'
        lines = [header]
        for key, channel in snapshot.channels.items():
            logo = f' tvg-logo="{channel.logo}"' if channel.logo else ''
            lines.append(f'#EXTINF:-1 tvg-id="{key}" tvg-name="{channel.name}" group-title="{channel.group}"{logo},{channel.display}')
            lines.append(f'{self.public_base}/live/{key}.m3u8{suffix}')
        return ('\n'.join(lines)+'\n').encode('utf-8')

    def close(self):
        self.store.close()
        self.manifests.close()
        self.epg.close()

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
        request_channel_id = None
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
                    "runtime": service.runtime, "status": {**service.store.status(), "epg": service.epg.status()}, "events": service.diagnostics.snapshot()}))
                return
            if parts.path in {"/", "/health", "/status"}:
                self.send_body(200, m.json_bytes({"service": "migu-live", "version": VERSION, "process_up": True, "mode": service.mode, "runtime": service.runtime, **service.store.status(), "epg": service.epg.status()}))
                return
            if parts.path == "/epg.xml":
                self.send_body(200, service.epg.get(), "application/xml; charset=utf-8")
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
            request_channel_id = key[1:] if key.startswith("p") else None
            suffix = ''
            if "playbackbegin" in query or "playbackend" in query:
                if not getattr(snapshot.playlist, 'catchup', False):
                    raise ServiceError("CATCHUP_UNAVAILABLE", 400)
                try:
                    suffix = list_catchup(query)
                except m.UpdateError as failure:
                    raise ServiceError(str(failure),400) from None
            url = service.store.resolve(key) + suffix
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
            details = getattr(error, "details", None)
            log_details = dict(details or {})
            if request_channel_id:
                log_details.setdefault("channel_id", request_channel_id)
            service.diagnostics.record(str(error), log_details)
            code = str(error)
            status = 403 if code in {"MIGU_AUTHORIZATION_REJECTED", "MIGU_LOGIN_REQUIRED", "MIGU_MEMBERSHIP_REQUIRED", "MIGU_REGION_RESTRICTED", "MIGU_TERMINAL_BLOCKED", "MIGU_COPYRIGHT_SHIELD", "MIGU_CLIENT_VERSION_UPGRADE_REQUIRED"} else 429 if code == "MIGU_RESOLVE_BURST_LIMIT" else 404 if code == "EPG_DISABLED" else 503 if code in {"EPG_LOADING", "EPG_UNAVAILABLE", "MIGU_API_LOADING", "MIGU_API_CAPACITY"} or (code.startswith("EPG_") or code.startswith("LIST_") or code in {"SOURCE_SNAPSHOT_TOO_OLD", "TOO_FEW_CHANNELS"}) else 502
            self.send_body(status, m.json_bytes({"error": code, **({"upstream": details} if details else {})}), **({"Retry_After": str(getattr(error, "retry_after", 60)) if status == 429 else "3"} if status in {429,503} else {}))
        except (ValueError, OSError):
            self.send_body(400, m.json_bytes({"error": "REQUEST_OR_IO_ERROR"}))

class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, address, service, max_clients=32):
        if not service.require_token and address[0] != "127.0.0.1":
            raise ServiceError("NON_LOOPBACK_REQUIRES_TOKEN")
        self.service = service
        self.slots = threading.BoundedSemaphore(max_clients)
        self.connections, self.connection_lock = set(), threading.Lock()
        super().__init__(address, Handler)

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(10)
        with self.connection_lock:
            self.connections.add(sock)
        return sock, address

    def shutdown_request(self, request):
        with self.connection_lock:
            self.connections.discard(request)
        super().shutdown_request(request)

    def server_close(self):
        super().server_close()
        with self.connection_lock:
            connections = list(self.connections)
            self.connections.clear()
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()

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
    elif stage in {"data-directory", "access-token"}:
        print("请检查访问令牌的可写目录；默认本机模式只使用内存。", file=sys.stderr)

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int, nargs="?", default=DEFAULT_PORT)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--public-base", help="Fixed external HTTP(S) URL")
    parser.add_argument("--data-dir", type=Path, help="Only needed for a persistent service access token")
    parser.add_argument("--token-env", help="Environment variable holding the service access token")
    parser.add_argument("--require-token", action="store_true")
    parser.add_argument("--provider", choices=("list","native","android"), default="android", help="android: direct reference-compatible API (default); native: older API; list: explicit external catalogue")
    parser.add_argument("--list-source", choices=("auto","github","upstream"), default="auto")
    parser.add_argument("--mode", choices=("redirect", "manifest"), default="redirect")
    parser.add_argument("--epg-cache", action="store_true", help="Persist valid programme schedules; fall back to memory if unavailable")
    parser.add_argument("--no-epg", action="store_true", help="Disable the XMLTV feed")
    args = parser.parse_args(argv)
    stage = "configuration"
    try:
        address = ipaddress.IPv4Address(args.bind)
        if not 1 <= args.port <= 65535:
            parser.error("port must be between 1 and 65535")
        base = args.public_base or f"http://{args.bind}:{args.port}"
        parts = urlsplit(base)
        if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username is not None or parts.password is not None or parts.query or parts.fragment or not m.clean_text(base) or any(ch.isspace() or ch in ('"', '<', '>', '\\') for ch in base):
            parser.error("public-base must be a fixed HTTP(S) URL without credentials/query/fragment")
        if not address.is_loopback and not args.public_base:
            parser.error("non-loopback bind requires an explicit --public-base")
        try:
            public_loopback = ipaddress.ip_address(parts.hostname).is_loopback
        except ValueError:
            public_loopback = parts.hostname == "localhost"
        require_token = args.require_token or bool(args.token_env) or not address.is_loopback or not public_loopback
        if require_token and not args.token_env:
            stage = "data-directory"
            args.data_dir = service_data_directory(args.data_dir)
        stage = "access-token"
        token = load_access_token(args.data_dir, args.token_env) if require_token else ""
        cache_path = None
        if args.epg_cache and not args.no_epg:
            try:
                directory = service_data_directory(args.data_dir)
                cache_path = directory / "epg-cache-v1.json"
            except (OSError, ValueError, ServiceError):
                print("[节目单] 缓存目录不可写，继续使用内存模式。", flush=True)
        stage = "provider"
        if args.provider == "list":
            store = ListStore(args.list_source)
        elif args.provider == "android":
            store = AndroidStore()
        else:
            store = NativeStore()
        service = Service(store, token, base, args.mode, require_token=require_token, epg=EpgStore(enabled=not args.no_epg, cache_path=cache_path))
        previous_signal = None
        try:
            stage = "bind"
            server = BoundedServer((args.bind, args.port), service)
            try:
                if threading.current_thread() is threading.main_thread():
                    try:
                        previous_signal = signal.signal(signal.SIGTERM, stop_from_signal)
                    except (OSError, ValueError, AttributeError):
                        print("[系统] 信号接口不可用，请使用 App 停止按钮。", flush=True)
                print(f"migu-live {VERSION}; provider={store.provider}; mode={args.mode}; listening={args.bind}:{args.port}", flush=True)
                print(f"[环境] Python {service.runtime['python']}; system={service.runtime['platform']}; main_thread={threading.current_thread() is threading.main_thread()}", flush=True)
                print("[系统] HTTP 服务启动成功；列表地址在首次订阅时加载，不调用官方匿名播放接口。" if args.provider == "list" else f"[系统] HTTP 服务启动成功；内置频道 {len(store.get().channels)} 个，官方取源按需进行。", flush=True)
                suffix = "?token=<access-token>" if require_token else ""
                for label, path in (("Subscription", "/all.m3u"), ("Diagnostics", "/diag")):
                    print(f"{label}: {base.rstrip('/')}{path}{suffix}", flush=True)
                if not args.no_epg:
                    print(f"EPG: {base.rstrip('/')}/epg.xml{suffix}", flush=True)
                if require_token:
                    print("Token: explicit environment variable" if args.token_env else f"Token file: {args.data_dir / 'access.token'}", flush=True)
                service.diagnostics.record("HTTP_SERVER_STARTED")
                stage = "serve"
                server.serve_forever(poll_interval=0.2)
            finally:
                server.server_close()
                if previous_signal is not None:
                    try:
                        signal.signal(signal.SIGTERM, previous_signal)
                    except (OSError, ValueError):
                        pass
        finally:
            service.close()
    except KeyboardInterrupt:
        print("[系统] 服务已停止，监听端口已释放。", flush=True)
        return 0
    except (OSError, ValueError, ServiceError, RuntimeError, ImportError) as error:
        startup_error(stage, error)
        return 1
    return 0
