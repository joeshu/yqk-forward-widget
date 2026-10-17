"""Socket-level regressions. All upstreams are local; no live channel is contacted.

Run: python -m unittest discover -s tests -p 'test_integration.py' -v
The private-address policy is enabled only for the explicitly local test fixture.
"""
from __future__ import annotations

import base64
import concurrent.futures
import contextlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import ysp_runtime as runtime


def load_application():
    name = "ysp_integration_application"
    spec = importlib.util.spec_from_file_location(name, ROOT / "ysp-live-v9.5.4.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    # Loading a library for tests must not replace the runner's signal handler.
    with patch("signal.signal"):
        spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def running_server(handler, *, tls_context=None, server_class=ThreadingHTTPServer, **kwargs):
    server = server_class(("127.0.0.1", 0), handler, **kwargs)
    server.daemon_threads = True
    if tls_context:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


class LocalOrigin:
    """An origin whose stalled second chunk makes streaming observable."""

    payload = bytes(range(256)) * 2048
    first_chunk = 64 * 1024

    def __init__(self):
        self.counts = Counter()
        self.lock = threading.Lock()
        self.started = threading.Event()
        self.release = threading.Event()
        self.redirect_target = None
        self.pause_broken = False

    def handler(self):
        origin = self

        class OriginHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self.respond(head_only=True)

            def do_GET(self):
                self.respond()

            def respond(self, head_only=False):
                path = urllib.parse.urlsplit(self.path).path
                with origin.lock:
                    origin.counts[(self.command, path)] += 1
                if path == "/redirect.m3u8":
                    self.send_response(302)
                    self.send_header("Location", origin.redirect_target or "/final/list.m3u8")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if path == "/final/list.m3u8":
                    payload = (b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
                               b'#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
                               b'#EXT-X-MAP:URI="init.mp4"\n'
                               b'#EXTINF:6,\nsegment.ts\n')
                    self.send_response(200)
                    self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    if not head_only:
                        self.wfile.write(payload)
                    return
                if path not in ("/full.ts", "/stream.ts", "/broken.ts"):
                    self.send_error(404)
                    return
                payload = origin.payload
                status, content_range = 200, None
                if self.headers.get("Range"):
                    value = self.headers["Range"]
                    start_s, end_s = value.removeprefix("bytes=").split("-")
                    if not start_s:
                        start, end = max(0, len(payload) - int(end_s)), len(payload) - 1
                    else:
                        start = int(start_s)
                        end = min(int(end_s) if end_s else len(payload) - 1, len(payload) - 1)
                    if start >= len(payload) or start > end:
                        self.send_response(416)
                        self.send_header("Content-Range", f"bytes */{len(payload)}")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    status = 206
                    content_range = f"bytes {start}-{end}/{len(payload)}"
                    payload = payload[start:end + 1]
                self.send_response(status)
                self.send_header("Content-Type", "video/mp2t")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Accept-Ranges", "bytes")
                if content_range:
                    self.send_header("Content-Range", content_range)
                self.end_headers()
                if head_only:
                    return
                try:
                    if path in ("/stream.ts", "/broken.ts"):
                        self.wfile.write(payload[:origin.first_chunk])
                        self.wfile.flush()
                        origin.started.set()
                        if path == "/broken.ts":
                            if origin.pause_broken:
                                origin.release.wait(8)
                            self.close_connection = True
                            return
                        if not origin.release.wait(8):
                            self.close_connection = True
                            return
                        self.wfile.write(payload[origin.first_chunk:])
                    else:
                        self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        return OriginHandler


class ApplicationIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global runtime
        cls.app = load_application()
        runtime = cls.app

    def setUp(self):
        self.cleanup_stack = contextlib.ExitStack()
        self.addCleanup(self.cleanup_stack.close)
        self.cleanup_stack.enter_context(patch.dict(os.environ, {
            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}))
        self.origin = LocalOrigin()
        self.upstream = self.cleanup_stack.enter_context(running_server(self.origin.handler()))
        self.base = f"http://127.0.0.1:{self.upstream.server_port}"
        self.proxy = runtime.SharedMediaProxy(
            policy=runtime.URLPolicy(("127.0.0.1",), allow_private=True),
            max_cache_bytes=2 * 1024 * 1024,
            max_inflight_bytes=4 * 1024 * 1024,
            max_downloads=8, timeout=5,
        )
        self.cleanup_stack.callback(self.proxy.close)
        self.cleanup_stack.callback(self.origin.release.set)
        for name, value in (("media_proxy", self.proxy), ("resolver", None),
                            ("CHANNEL_MAP", {}), ("active_backend_channels", set())):
            self.cleanup_stack.enter_context(patch.object(self.app, name, value))
        self.gateway = self.cleanup_stack.enter_context(running_server(self.app.Handler))

    def resource(self, path="/full.ts"):
        token = runtime.register_resource(self.base + path)
        return "/proxy?resource=" + token

    def connection(self):
        return http.client.HTTPConnection("127.0.0.1", self.gateway.server_port, timeout=6)

    def request(self, path, method="GET", headers=None):
        with contextlib.closing(self.connection()) as connection:
            connection.request(method, path, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()

    def test_eight_viewers_share_one_upstream_download(self):
        path = self.resource("/stream.ts")
        barrier = threading.Barrier(8)

        def viewer():
            barrier.wait(timeout=3)
            return self.request(path)

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            futures = [pool.submit(viewer) for _ in range(8)]
            self.assertTrue(self.origin.started.wait(3), "local upstream did not start")
            # A complete first fragment must be deliverable while the origin is paused.
            self.origin.release.set()
            responses = [future.result(timeout=6) for future in futures]
        for status, headers, body in responses:
            self.assertEqual(status, 200)
            self.assertEqual(body, self.origin.payload)
        self.assertEqual(self.origin.counts[("GET", "/stream.ts")], 1)

    def test_first_byte_precedes_complete_download_and_disconnect_is_independent(self):
        path = self.resource("/stream.ts")
        first, second = self.connection(), self.connection()
        try:
            first.request("GET", path)
            first_response = first.getresponse()
            self.assertEqual(first_response.status, 200)
            self.assertTrue(self.origin.started.wait(2))
            self.assertEqual(first_response.read(1), self.origin.payload[:1])
            self.assertFalse(self.origin.release.is_set())
            second.request("GET", path)
            second_response = second.getresponse()
            self.assertEqual(second_response.read(1), self.origin.payload[:1])
            # Close the first subscriber before releasing the origin's remaining bytes.
            first_response.close()
            first.close()
            self.origin.release.set()
            self.assertEqual(second_response.read(), self.origin.payload[1:])
            self.assertEqual(self.origin.counts[("GET", "/stream.ts")], 1)
        finally:
            self.origin.release.set()
            first.close()
            second.close()

    def test_range_status_and_content_range_are_forwarded(self):
        path = self.resource()
        status, headers, body = self.request(path, headers={"Range": "bytes=17-42"})
        self.assertEqual(status, 206)
        self.assertEqual(body, self.origin.payload[17:43])
        self.assertEqual(headers.get("content-range") or headers.get("Content-Range"),
                         f"bytes 17-42/{len(self.origin.payload)}")
        status, headers, body = self.request(path, headers={"Range": "bytes=9999999-"})
        self.assertEqual(status, 416)
        self.assertEqual(body, b"")
        self.assertEqual(headers.get("content-range") or headers.get("Content-Range"),
                         f"bytes */{len(self.origin.payload)}")

    def test_head_fetches_metadata_without_upstream_body(self):
        status, headers, body = self.request(self.resource(), method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(int(headers.get("content-length") or headers["Content-Length"]),
                         len(self.origin.payload))
        self.assertEqual(self.origin.counts[("HEAD", "/full.ts")], 1)
        self.assertEqual(self.origin.counts[("GET", "/full.ts")], 0)
        self.assertEqual(self.proxy.stats()["count"], 0)

    def test_truncated_origin_aborts_without_a_second_http_status_or_cache_entry(self):
        self.origin.pause_broken = True
        path = self.resource("/broken.ts")
        with socket.create_connection(("127.0.0.1", self.gateway.server_port), timeout=5) as connection:
            connection.sendall(f"GET {path} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
            response = bytearray()
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                response.extend(chunk)
                if len(bytes(response).partition(b"\r\n\r\n")[2]) >= self.origin.first_chunk:
                    self.origin.release.set()
        header, _, body = bytes(response).partition(b"\r\n\r\n")
        self.assertTrue(header.startswith(b"HTTP/1.0 200"), header[:120])
        self.assertEqual(body, self.origin.payload[:self.origin.first_chunk])
        self.assertNotIn(b"HTTP/1.0 502", body)
        self.assertNotIn(b"HTTP/1.1 502", body)
        self.assertEqual(self.proxy.stats()["count"], 0)

    def test_zero_cache_really_disables_retention(self):
        self.proxy.max_cache_bytes = 0
        path = self.resource()
        for _ in range(2):
            status, _, body = self.request(path)
            self.assertEqual((status, body), (200, self.origin.payload))
            deadline = time.monotonic() + 2
            while self.proxy.stats()["inflight_count"] and time.monotonic() < deadline:
                time.sleep(0.005)
            self.assertEqual(self.proxy.stats()["inflight_count"], 0)
        self.assertEqual(self.proxy.stats()["count"], 0)
        self.assertEqual(self.origin.counts[("GET", "/full.ts")], 2)

    def test_credentials_are_part_of_shared_download_and_cache_identity(self):
        for identity in ("device-one", "device-two"):
            token = runtime.register_resource(self.base + "/full.ts", {"UID": identity})
            status, _, body = self.request("/proxy?resource=" + token)
            self.assertEqual((status, body), (200, self.origin.payload))
        self.assertEqual(self.origin.counts[("GET", "/full.ts")], 2)

    def test_inflight_capacity_is_rejected_before_sending_success(self):
        self.proxy.max_inflight_bytes = 65536
        status, _, body = self.request(self.resource())
        self.assertEqual(status, 503)
        self.assertNotEqual(body, self.origin.payload)
        self.assertEqual(self.proxy.stats()["count"], 0)

    def test_producer_launch_failure_releases_capacity_for_the_next_request(self):
        self.proxy.slots = threading.BoundedSemaphore(1)
        original_start = threading.Thread.start

        def fail_download_thread(thread, *args, **kwargs):
            if thread.name == "media-download":
                raise RuntimeError("simulated OS thread limit")
            return original_start(thread, *args, **kwargs)

        with patch.object(threading.Thread, "start", fail_download_thread):
            status, _, _ = self.request(self.resource("/full.ts?launch=fails"))
            self.assertIn(status, (500, 502, 503))
        status, _, body = self.request(self.resource("/full.ts?launch=recovers"))
        self.assertEqual(status, 200)
        self.assertEqual(body, self.origin.payload)

    def test_temporary_storage_failure_releases_capacity_for_the_next_request(self):
        self.proxy.slots = threading.BoundedSemaphore(1)
        with patch.object(runtime.tempfile, "TemporaryFile", side_effect=OSError("simulated file limit")):
            status, _, _ = self.request(self.resource("/full.ts?storage=fails"))
            self.assertIn(status, (500, 502, 503))
        status, _, body = self.request(self.resource("/full.ts?storage=recovers"))
        self.assertEqual(status, 200)
        self.assertEqual(body, self.origin.payload)

    def test_cleanup_close_error_does_not_leak_download_capacity(self):
        self.proxy.slots = threading.BoundedSemaphore(1)
        original_start = threading.Thread.start
        original_file = runtime.tempfile.TemporaryFile

        class CloseErrorFile:
            def __init__(self, *args, **kwargs):
                self.file = original_file(*args, **kwargs)

            def __getattr__(self, name):
                return getattr(self.file, name)

            def close(self):
                self.file.close()
                raise OSError("simulated close error during failed startup")

        def fail_download_thread(thread, *args, **kwargs):
            if thread.name == "media-download":
                raise RuntimeError("simulated OS thread limit")
            return original_start(thread, *args, **kwargs)

        with patch.object(runtime.tempfile, "TemporaryFile", CloseErrorFile), \
                patch.object(threading.Thread, "start", fail_download_thread):
            status, _, _ = self.request(self.resource("/full.ts?cleanup=fails"))
            self.assertIn(status, (500, 502, 503))
        status, _, body = self.request(self.resource("/full.ts?cleanup=recovers"))
        self.assertEqual(status, 200)
        self.assertEqual(body, self.origin.payload)

    def test_remote_close_error_does_not_block_completion_or_next_download(self):
        self.proxy.slots = threading.BoundedSemaphore(1)
        original_close = runtime.RemoteResponse.close

        def fail_close(remote):
            original_close(remote)
            raise OSError("simulated remote close error")

        with patch.object(runtime.RemoteResponse, "close", fail_close):
            for method, query in (("HEAD", "metadata"), ("GET", "first"), ("GET", "second")):
                status, _, body = self.request(self.resource("/full.ts?close=" + query), method=method)
                self.assertEqual(status, 200)
                self.assertEqual(body, b"" if method == "HEAD" else self.origin.payload)
                deadline = time.monotonic() + 2
                while self.proxy.stats()["inflight_count"] and time.monotonic() < deadline:
                    time.sleep(0.005)
                self.assertEqual(self.proxy.stats()["inflight_count"], 0)

    def test_shutdown_does_not_repopulate_cache_from_a_finishing_download(self):
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()
        original_store = self.proxy._store_cache

        def paused_store(key, task):
            entered.set()
            try:
                if not release.wait(3):
                    raise TimeoutError("test did not release cache completion")
                original_store(key, task)
            finally:
                finished.set()

        with patch.object(self.proxy, "_store_cache", paused_store), \
                concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            request = pool.submit(self.request, self.resource())
            try:
                self.assertTrue(entered.wait(2))
                self.proxy.close()
            finally:
                release.set()
            self.assertTrue(finished.wait(2))
            status, _, body = request.result(timeout=3)
            self.assertEqual(status, 200)
            self.assertEqual(body, self.origin.payload)
        self.assertEqual(self.proxy.stats()["count"], 0)

    def test_arbitrary_base64_target_is_not_an_authorization_token(self):
        encoded = base64.urlsafe_b64encode((self.base + "/full.ts").encode()).decode().rstrip("=")
        status, _, _ = self.request("/proxy.ts?=" + encoded)
        self.assertIn(status, (400, 403))
        self.assertEqual(self.origin.counts[("GET", "/full.ts")], 0)

    def test_registered_private_target_is_forbidden_by_production_policy(self):
        self.proxy.policy = runtime.URLPolicy()
        status, _, _ = self.request(self.resource())
        self.assertEqual(status, 403)
        self.assertEqual(self.origin.counts[("GET", "/full.ts")], 0)

    def test_malformed_catchup_is_400_and_never_becomes_live(self):
        with patch.object(self.app, "jce_timeshift_url", side_effect=AssertionError("must not fetch")), \
                patch.object(self.app, "ensure_channel", side_effect=AssertionError("must not play live")):
            status, _, _ = self.request("/cctv1.m3u8?start=not-a-time&end=also-invalid")
        self.assertEqual(status, 400)

    def test_catchup_upstream_failure_is_502_and_never_becomes_live(self):
        end = int(time.time()) - 60
        start = end - 600
        with patch.object(self.app, "jce_timeshift_url", side_effect=RuntimeError("local simulated failure")), \
                patch.object(self.app, "ensure_channel", side_effect=AssertionError("must not play live")):
            status, _, body = self.request(f"/cctv1.m3u8?start={start}&end={end}")
        self.assertEqual(status, 502)
        self.assertNotIn(b"#EXTM3U", body)

    def test_liveness_and_readiness_are_distinct_when_no_media_is_available(self):
        status, _, body = self.request("/livez")
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(body)["ok"])
        status, _, body = self.request("/health")
        self.assertEqual(status, 503)
        self.assertFalse(json.loads(body)["ok"])

    def test_redirect_rechecks_destination_policy(self):
        # The only allowed host redirects to an explicitly forbidden hostname.
        class RedirectHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "http://localhost/private.ts")
                self.send_header("Content-Length", "0")
                self.end_headers()

        with running_server(RedirectHandler) as upstream:
            token = runtime.register_resource(f"http://127.0.0.1:{upstream.server_port}/redirect.ts")
            status, _, _ = self.request("/proxy?resource=" + token)
        self.assertEqual(status, 403)


class RuntimeSocketTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("openssl"), "local TLS fixture needs openssl")
    def test_https_redirect_uses_final_playlist_base_for_segments_and_uri_attributes(self):
        origin = LocalOrigin()
        with tempfile.TemporaryDirectory() as temp:
            cert, key = Path(temp) / "cert.pem", Path(temp) / "key.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", str(key), "-out", str(cert), "-days", "1",
                            "-subj", "/CN=localhost"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            with running_server(origin.handler(), tls_context=context) as upstream, \
                    patch.object(runtime, "_TLS_CONTEXT", ssl._create_unverified_context()), \
                    patch.dict(os.environ, {"NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}):
                base = f"https://127.0.0.1:{upstream.server_port}"
                policy = runtime.URLPolicy(("127.0.0.1",), allow_private=True)
                status, _, body, effective = runtime.fetch_bytes(base + "/redirect.m3u8", policy=policy)
                self.assertEqual(status, 200)
                self.assertEqual(effective, base + "/final/list.m3u8")
                rendered = runtime.render_media_playlist(body.decode(), effective)
                resources = []
                for line in rendered.splitlines():
                    if line.startswith("/proxy?resource="):
                        resources.append(line.removeprefix("/proxy?resource="))
                    elif 'URI="/proxy?resource=' in line:
                        resources.append(line.split('URI="/proxy?resource=', 1)[1].split('"', 1)[0])
                self.assertEqual({runtime.resolve_resource(token).url for token in resources},
                                 {base + "/final/segment.ts", base + "/final/key.bin", base + "/final/init.mp4"})
                # A downgrade must fail before contacting the cleartext target.
                clear_origin = LocalOrigin()
                with running_server(clear_origin.handler()) as clear_upstream:
                    origin.redirect_target = f"http://127.0.0.1:{clear_upstream.server_port}/full.ts"
                    with self.assertRaises(runtime.ProxyError) as error:
                        runtime.fetch_bytes(base + "/redirect.m3u8", policy=policy)
                    self.assertEqual(error.exception.status, 502)
                    self.assertEqual(clear_origin.counts[("GET", "/full.ts")], 0)

    def test_fetch_bytes_rejects_incomplete_declared_content_length(self):
        origin = LocalOrigin()
        with running_server(origin.handler()) as upstream, \
                patch.dict(os.environ, {"NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}):
            with self.assertRaises(runtime.ProxyError) as error:
                runtime.fetch_bytes(f"http://127.0.0.1:{upstream.server_port}/broken.ts",
                                    policy=runtime.URLPolicy(("127.0.0.1",), allow_private=True))
        self.assertEqual(error.exception.status, 502)

    def test_http_admission_rejects_excess_connection_and_recovers(self):
        release, entered = threading.Event(), threading.Event()

        class PausedHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                entered.set()
                release.wait(4)
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

        with running_server(PausedHandler, server_class=runtime.BoundedHTTPServer,
                            max_connections=1, client_timeout=3) as server:
            first = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            second = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            try:
                first.request("GET", "/")
                self.assertTrue(entered.wait(2))
                second.request("GET", "/")
                rejected = second.getresponse()
                self.assertEqual(rejected.status, 503)
                self.assertEqual(rejected.read(), b"")
                release.set()
                accepted = first.getresponse()
                self.assertEqual(accepted.status, 200)
                self.assertEqual(accepted.read(), b"")
                self.assertEqual(server.rejected, 1)
            finally:
                release.set()
                first.close()
                second.close()


class StandaloneProcessTests(unittest.TestCase):
    def test_no_engine_no_4k_starts_without_upstream_and_stops_on_sigterm(self):
        with socket.socket() as port_socket:
            port_socket.bind(("127.0.0.1", 0))
            port = port_socket.getsockname()[1]
        with tempfile.TemporaryDirectory() as temp:
            env = dict(os.environ, PYTHONUNBUFFERED="1", NO_PROXY="127.0.0.1,localhost",
                       no_proxy="127.0.0.1,localhost")
            standalone = Path(temp) / "ysp-live-v9.5.4.py"
            shutil.copyfile(ROOT / "ysp-live-v9.5.4.py", standalone)
            process = subprocess.Popen(
                [sys.executable, str(standalone), str(port), "--bind", "127.0.0.1",
                 "--no-engine", "--no-4k", "--cache-mb", "0", "--data-dir", temp],
                cwd=temp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic() + 8
                while True:
                    if process.poll() is not None:
                        self.fail("service exited before binding: " + process.stdout.read())
                    try:
                        with contextlib.closing(http.client.HTTPConnection("127.0.0.1", port, timeout=0.5)) as connection:
                            connection.request("GET", "/livez")
                            response = connection.getresponse()
                            body = response.read()
                            self.assertEqual(response.status, 200)
                            self.assertTrue(json.loads(body)["ok"])
                            break
                    except (OSError, http.client.HTTPException):
                        if time.monotonic() >= deadline:
                            self.fail("service did not bind within 8 seconds")
                        time.sleep(0.05)
                with contextlib.closing(http.client.HTTPConnection("127.0.0.1", port, timeout=2)) as connection:
                    connection.request("GET", "/all.m3u")
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertTrue(response.read().startswith(b"#EXTM3U"))
                process.terminate()
                output, _ = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, output)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
