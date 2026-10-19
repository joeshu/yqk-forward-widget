#!/usr/bin/env python3
"""Experimental local HLS service using the actual CCTV mobile webpage.

Requires Python 3.10+, Playwright, Chromium and FFmpeg (libx264/AAC).
The official webpage plays normally; MediaRecorder captures its media stream.
This is browser capture/transcoding, not a direct stream or a Node DRM adapter.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import concurrent.futures
import importlib.util
import json
import math
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import uuid

CHANNELS = {"cctv2": "CCTV-2 财经"}
UA = ("Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 "
      "Chrome/130.0.0.0 Mobile Safari/537.36")
RECORDER = r"""() => {
  const video = document.querySelector('video');
  if (!video || typeof video.captureStream !== 'function') throw Error('capture-unsupported');
  const stream = video.captureStream();
  if (!stream.getVideoTracks().length) throw Error('video-track-missing');
  const mime = 'video/webm;codecs=vp8,opus';
  if (!MediaRecorder.isTypeSupported(mime)) throw Error('recorder-unsupported');
  const recorder = new MediaRecorder(stream, {mimeType:mime, videoBitsPerSecond:2500000});
  window.__cctvRecorder = recorder;
  let chain = Promise.resolve();
  recorder.ondataavailable = event => {
    if (!event.data.size) return;
    chain = chain.then(async () => {
      if (event.data.size > 8*1024*1024) throw Error('capture-too-large');
      const bytes = new Uint8Array(await event.data.arrayBuffer());
      let text = '';
      for (let i=0; i<bytes.length; i+=16384)
        text += String.fromCharCode(...bytes.subarray(i,i+16384));
      await window.__cctvChunk(btoa(text));
    }).catch(() => { recorder.stop(); window.__cctvCaptureFailed = true; });
  };
  recorder.onerror = () => { window.__cctvCaptureFailed = true; };
  recorder.start(1000);
  return stream.getTracks().map(track => track.kind);
}"""


def public_base(host: str, configured: str = "") -> str:
    if configured:
        parsed = urlsplit(configured)
        if (parsed.scheme not in ("http", "https") or not parsed.hostname
                or parsed.username or parsed.password or parsed.query or parsed.fragment
                or (parsed.port is not None and not 1 <= parsed.port <= 65535)
                or re.search(r'[\s"<>\\]', configured)):
            raise ValueError("invalid-public-base")
        return configured.rstrip("/")
    if not re.fullmatch(r"(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::\d{1,5})?", host):
        raise ValueError("invalid-host")
    parsed = urlsplit("http://" + host)
    if parsed.port is not None and not 1 <= parsed.port <= 65535:
        raise ValueError("invalid-host")
    return "http://" + host


def ffmpeg_command(executable: str, folder: Path) -> list[str]:
    return [executable, "-hide_banner", "-loglevel", "warning", "-y",
            "-fflags", "+genpts", "-analyzeduration", "1000000", "-probesize", "2000000",
            "-f", "webm", "-i", "pipe:0", "-map", "0:v:0", "-map", "0:a:0?",
            "-vf", "fps=25,scale=w='min(1280,iw)':h=-2,format=yuv420p",
            "-c:v", "libx264", "-threads", "2", "-preset", "ultrafast", "-tune", "zerolatency",
            "-crf", "23", "-g", "50", "-keyint_min", "50", "-sc_threshold", "0",
            "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "6",
            "-hls_delete_threshold", "3", "-hls_flags", "delete_segments+independent_segments+temp_file",
            "-hls_segment_filename", str(folder / "segment_%09d.ts"), str(folder / "index.m3u8")]


def valid_playlist(folder: Path) -> str | None:
    try:
        path = folder / "index.m3u8"
        if time.time() - path.stat().st_mtime > 15:
            return None
        body = path.read_text(encoding="utf-8")
        if not body.startswith("#EXTM3U\n") or body.count("#EXTINF:") < 2:
            return None
        files = [line for line in body.splitlines() if line and not line.startswith("#")]
        if not files or not all(re.fullmatch(r"segment_\d{9}\.ts", name) and (folder / name).is_file()
                                for name in files):
            return None
        return body
    except (OSError, UnicodeError):
        return None


class Channel:
    def __init__(self, app: "App", name: str):
        self.app, self.name = app, name
        self.lock = threading.RLock()
        self.state, self.error = "idle", ""
        self.generation = ""
        self.folder: Path | None = None
        self.future: concurrent.futures.Future | None = None
        self.last_request = 0.0
        self.failed_at = 0.0
        self.stop = threading.Event()
        self.chunks = 0
        self.waiters = 0
        self.tracks: list[str] = []

    def request(self, start: bool = True) -> None:
        with self.lock:
            self.last_request = time.monotonic()
            if not start or self.app.closing:
                return
            if self.future is not None and not self.future.done():
                return
            if self.state == "error" and time.monotonic() - self.failed_at < 30:
                return
            self.stop = threading.Event()
            self.generation = uuid.uuid4().hex
            self.folder = self.app.folder / self.name / self.generation
            self.folder.mkdir(parents=True, mode=0o700)
            self.state, self.error, self.chunks, self.tracks = "opening", "", 0, []
            self.future = asyncio.run_coroutine_threadsafe(self.run(), self.app.loop)

    def snapshot(self) -> dict:
        with self.lock:
            return {"channel": self.name, "state": self.state, "error": self.error,
                    "chunks": self.chunks, "tracks": list(self.tracks),
                    "media_ready": self.state == "ready" and self.folder is not None
                    and valid_playlist(self.folder) is not None}

    async def run(self) -> None:
        context = process = writer = None
        feeder_stop = threading.Event()
        failure = threading.Event()
        pending: queue.Queue[bytes] = queue.Queue(maxsize=8)
        folder = self.folder
        assert folder is not None
        try:
            browser = await self.app.get_browser()
            context = await browser.new_context(viewport={"width": 430, "height": 932},
                                                is_mobile=True, has_touch=True, user_agent=UA)
            page = await context.new_page()

            async def chunk(_source, encoded):
                if self.stop.is_set() or failure.is_set():
                    raise RuntimeError("capture-stopped")
                if not isinstance(encoded, str) or len(encoded) > 12 * 1024 * 1024:
                    failure.set()
                    raise RuntimeError("capture-too-large")
                data = base64.b64decode(encoded, validate=True)
                if len(data) > 8 * 1024 * 1024:
                    failure.set()
                    raise RuntimeError("capture-too-large")
                try:
                    pending.put_nowait(data)
                except queue.Full:
                    failure.set()
                    raise RuntimeError("encoder-backpressure")
                with self.lock:
                    self.chunks += 1

            await page.expose_binding("__cctvChunk", chunk)
            response = await page.goto("https://tv.cctv.com/live/" + self.name + "/m/index.shtml",
                                       wait_until="domcontentloaded", timeout=30000)
            if response is None or response.status != 200:
                raise RuntimeError("official-page-failed")
            self.state = "waiting-video"
            await page.wait_for_function("document.querySelector('video')?.readyState>=3 && "
                                         "document.querySelector('video').videoWidth>0", timeout=45000)
            stderr = open(folder / "encoder.log", "wb")
            try:
                process = subprocess.Popen(ffmpeg_command(self.app.args.ffmpeg, folder), stdin=subprocess.PIPE,
                                           stdout=subprocess.DEVNULL, stderr=stderr)
            finally:
                stderr.close()

            def feed():
                try:
                    while not feeder_stop.is_set():
                        try:
                            data = pending.get(timeout=0.2)
                        except queue.Empty:
                            continue
                        process.stdin.write(data)
                        process.stdin.flush()
                except (OSError, ValueError):
                    failure.set()

            writer = threading.Thread(target=feed, daemon=True, name="cctv-encoder-feed")
            writer.start()
            self.tracks = await page.evaluate(RECORDER)
            self.state = "buffering"
            started = time.monotonic()
            last_media = started
            while not self.stop.is_set():
                if failure.is_set() or process.poll() is not None:
                    raise RuntimeError("encoder-failed")
                if valid_playlist(folder) is not None:
                    self.state = "ready"
                    last_media = time.monotonic()
                elif time.monotonic() - last_media > 35:
                    raise RuntimeError("media-stalled")
                if self.waiters == 0 and time.monotonic() - self.last_request > self.app.args.idle_timeout:
                    self.state = "idle"
                    break
                if await page.evaluate("Boolean(window.__cctvCaptureFailed)"):
                    raise RuntimeError("capture-failed")
                await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            self.state = "stopped"
            raise
        except Exception as error:
            # Do not publish browser exception strings, which may contain signed URLs.
            known = {"official-page-failed", "encoder-failed", "media-stalled", "capture-failed"}
            self.error = str(error) if str(error) in known else "browser-or-capture-failed"
            if "Executable doesn't exist" in str(error):
                self.error = "browser-missing"
            elif type(error).__name__ == "TimeoutError" and self.state == "waiting-video":
                self.error = "official-video-timeout"
            self.state, self.failed_at = "error", time.monotonic()
            print(f"[{self.name}] {self.error} ({type(error).__name__})", flush=True)
        finally:
            feeder_stop.set()
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                    try:
                        await asyncio.to_thread(process.wait, 3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        await asyncio.to_thread(process.wait)
                if writer is not None:
                    await asyncio.to_thread(writer.join, 3)
                process.stdin.close()
            if context is not None:
                try:
                    await context.close()
                except Exception:
                    pass
            # Generation URLs stop resolving immediately when their worker ends.
            shutil.rmtree(folder, ignore_errors=True)


class App:
    def __init__(self, args):
        self.args, self.closing = args, False
        parent = Path(args.data_dir).expanduser().resolve() if args.data_dir else Path(tempfile.gettempdir())
        parent.mkdir(parents=True, exist_ok=True)
        self.folder = Path(tempfile.mkdtemp(prefix="cctv-web-", dir=parent))
        os.chmod(self.folder, 0o700)
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.browser = self.playwright = None
        self.browser_lock = None
        self.channel = Channel(self, "cctv2")

    async def get_browser(self):
        from playwright.async_api import async_playwright
        if self.browser_lock is None:
            self.browser_lock = asyncio.Lock()
        async with self.browser_lock:
            if self.browser is None or not self.browser.is_connected():
                if self.playwright is None:
                    self.playwright = await async_playwright().start()
                kwargs = {"headless": True, "args": ["--autoplay-policy=no-user-gesture-required"]}
                if hasattr(os, "geteuid") and os.geteuid() == 0:
                    kwargs["args"].append("--no-sandbox")
                if self.args.browser:
                    kwargs["executable_path"] = self.args.browser
                proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or os.environ.get("HTTP_PROXY")
                if proxy:
                    kwargs["proxy"] = {"server": proxy}
                self.browser = await self.playwright.chromium.launch(**kwargs)
            return self.browser

    def close(self):
        self.closing = True
        self.channel.stop.set()
        if self.channel.future is not None:
            try:
                self.channel.future.result(timeout=8)
            except (concurrent.futures.TimeoutError, concurrent.futures.CancelledError):
                self.channel.future.cancel()
            except Exception:
                pass

        async def close_browser():
            if self.browser is not None:
                await self.browser.close()
            if self.playwright is not None:
                await self.playwright.stop()

        try:
            asyncio.run_coroutine_threadsafe(close_browser(), self.loop).result(timeout=10)
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
            self.thread.join(3)
            if not self.thread.is_alive():
                self.loop.close()
            shutil.rmtree(self.folder, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "CCTVWeb/0.1-experimental"

    @property
    def app(self) -> App:
        return self.server.app

    def log_message(self, _format, *_args):
        pass

    def send(self, status, body=b"", content_type="text/plain; charset=utf-8", cache=False):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=10" if cache else "no-store")
        if status == 503:
            self.send_header("Retry-After", "3")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                pass

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self.send(405, "GET/HEAD only")

    def do_GET(self):
        self.connection.settimeout(self.app.args.startup_timeout + 10)
        path = urlsplit(self.path).path
        channel = self.app.channel
        if path in ("/", "/all.m3u"):
            try:
                base = public_base(self.headers.get("Host", ""), self.app.args.public_base_url)
            except ValueError:
                return self.send(400, "invalid-host")
            return self.send(200, '#EXTM3U\n#EXTINF:-1 tvg-id="CCTV2" group-title="央视网页·实验",'
                             + CHANNELS["cctv2"] + '\n' + base + '/cctv2.m3u8\n',
                             "audio/x-mpegurl; charset=utf-8")
        if path == "/status":
            return self.send(200, json.dumps(channel.snapshot(), ensure_ascii=False),
                             "application/json; charset=utf-8")
        if path == "/livez":
            return self.send(200, "ok\n")
        if path == "/cctv2.m3u8":
            if self.command == "HEAD":
                return self.send(200, content_type="application/vnd.apple.mpegurl")
            return self.playlist(channel)
        match = re.fullmatch(r"/media/cctv2/([0-9a-f]{32})/(segment_\d{9}\.ts)", path)
        if match:
            with channel.lock:
                if (match[1] != channel.generation or channel.state != "ready" or channel.folder is None):
                    return self.send(410, "expired-media")
                try:
                    body = (channel.folder / match[2]).read_bytes()
                except OSError:
                    return self.send(410, "expired-media")
            if self.command != "HEAD":
                channel.request(start=False)
            return self.send(200, body, "video/mp2t", cache=True)
        self.send(404, "not-found")

    def playlist(self, channel):
        with channel.lock:
            channel.waiters += 1
        try:
            channel.request()
            deadline = time.monotonic() + self.app.args.startup_timeout
            while time.monotonic() < deadline:
                with channel.lock:
                    folder, generation, state = channel.folder, channel.generation, channel.state
                    body = valid_playlist(folder) if folder and state == "ready" else None
                if body:
                    lines = [line if line.startswith("#") or not line else
                             f"media/cctv2/{generation}/{line}" for line in body.splitlines()]
                    return self.send(200, "\n".join(lines) + "\n", "application/vnd.apple.mpegurl")
                if state in ("error", "stopped"):
                    break
                if state == "idle":
                    # A viewer can arrive while the previous idle worker is closing.
                    channel.request()
                time.sleep(0.2)
            return self.send(503, json.dumps(channel.snapshot(), ensure_ascii=False),
                             "application/json; charset=utf-8")
        finally:
            with channel.lock:
                channel.waiters -= 1
                channel.last_request = time.monotonic()


def main(argv=None):
    parser = argparse.ArgumentParser(description="CCTV-2 官方网页采集转码订阅实验版（需要电脑/服务器）")
    parser.add_argument("port", nargs="?", type=int, default=18768)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--browser", default=shutil.which("chromium") or shutil.which("google-chrome"))
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    parser.add_argument("--data-dir", help="临时媒体目录的父目录，退出时删除本次生成内容")
    parser.add_argument("--public-base-url", default="")
    parser.add_argument("--startup-timeout", type=float, default=75)
    parser.add_argument("--idle-timeout", type=float, default=120)
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535 or not all(math.isfinite(x) for x in (args.startup_timeout, args.idle_timeout)):
        parser.error("invalid port or timeout")
    if not 5 <= args.startup_timeout <= 120 or not 30 <= args.idle_timeout <= 3600:
        parser.error("startup timeout must be 5–120; idle timeout must be 30–3600")
    if args.public_base_url:
        try:
            public_base("", args.public_base_url)
        except ValueError:
            parser.error("invalid public base URL")
    if importlib.util.find_spec("playwright") is None:
        parser.error("先安装依赖：python -m pip install playwright；python -m playwright install chromium")
    if not shutil.which(args.ffmpeg):
        parser.error("未找到 FFmpeg，请安装包含 libx264/AAC 编码器的 FFmpeg")
    app = App(args)
    server = None
    try:
        server = ThreadingHTTPServer((args.bind, args.port), Handler)
        server.daemon_threads = True
        server.app = app
        def stop(_signum, _frame):
            threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)
        print(f"CCTV 网页采集转码实验版：仅 CCTV-2；订阅 http://127.0.0.1:{args.port}/all.m3u", flush=True)
        print("首次选台会启动完整官方网页，可能等待数十秒；状态：/status。", flush=True)
        server.serve_forever(poll_interval=0.2)
    finally:
        if server:
            server.server_close()
        app.close()


if __name__ == "__main__":
    main()
