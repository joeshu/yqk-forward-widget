#!/usr/bin/env python3
"""Standard-library-only runtime capability report; this is NOT a TV service."""
import argparse
import importlib.util
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = '1.0.0'
CANDIDATES = (
    'ctypes', '_ctypes', 'quickjs', '_quickjs', 'js2py', 'pythonmonkey',
    'wasmtime', 'wasmer', 'pywasm', 'objc', 'objc_util', 'rubicon',
    'JavaScriptCore', 'javascript', 'js', 'aptv',
)


def report():
    modules = {}
    for name in CANDIDATES:
        if name in sys.modules:
            modules[name] = 'loaded'
            continue
        try:
            modules[name] = 'visible' if importlib.util.find_spec(name) is not None else 'absent'
        except Exception:
            modules[name] = 'unknown'
    return {
        'probe_version': VERSION,
        'purpose': 'environment-report-only-not-a-tv-playlist',
        'python': '.'.join(str(x) for x in sys.version_info[:3]),
        'implementation': sys.implementation.name,
        'platform': sys.platform,
        'candidate_modules': modules,
        'note': 'visible/loaded means discoverable only, not proven usable or WebAssembly-capable',
        'subprocess_required': False,
        'external_requests': False,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = 'APTVRuntimeProbe/1.0'

    def log_message(self, *_args):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        status = 200 if path in ('/', '/status') else (503 if path == '/all.m3u' else 404)
        value = self.server.report if status == 200 else {
            'error': 'diagnostics-only-no-playlist' if status == 503 else 'not-found'}
        body = json.dumps(value, ensure_ascii=False, indent=2).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            try:
                self.wfile.write(body)
            except OSError:
                pass


def main(argv=None):
    parser = argparse.ArgumentParser(description='APTV Python 环境检测；不提供频道订阅')
    parser.add_argument('port', nargs='?', type=int, default=18770)
    parser.add_argument('--once', action='store_true', help='仅打印报告后退出')
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error('port must be 1..65535')
    value = report()
    print('APTV环境检测：仅检测，不提供频道订阅。', flush=True)
    print('Python版本：'+value['python']+'；平台：'+value['platform'], flush=True)
    print('可见候选模块：'+(', '.join(name for name, state in value['candidate_modules'].items()
                                  if state in ('loaded', 'visible')) or '无'), flush=True)
    print(json.dumps(value, ensure_ascii=False), flush=True)
    if args.once:
        return
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.daemon_threads = True
    server.report = value
    print(f'完整报告：http://127.0.0.1:{args.port}/status', flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
