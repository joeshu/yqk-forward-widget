#!/usr/bin/env python3
"""Explicit native JavaScriptCore/WASM diagnostic; NOT a streaming service.

Uses Apple's system framework on iOS/macOS. No subprocess, downloads, package
installation, native callbacks, or CCTV SDK. Native framework calls are opt-in
by choosing this diagnostic instead of the non-native aptv-probe.py.
"""
import json
import sys

APPLE_FRAMEWORK = '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore'
# Minimal standards-format module: exported ans() returns integer 42.
WASM = [0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127,
        3, 2, 1, 0, 7, 7, 1, 3, 97, 110, 115, 0, 0,
        10, 6, 1, 4, 0, 65, 42, 11]
SCRIPT = '''(function () {
    var result = {javascript: 6 * 7, wasm_available: typeof WebAssembly === 'object'};
    if (result.wasm_available) {
        try {
            var module = new WebAssembly.Module(new Uint8Array(%s));
            result.wasm = new WebAssembly.Instance(module).exports.ans();
        } catch (e) { result.wasm_error = 'compile-or-execution-failed'; }
    }
    return JSON.stringify(result);
})()''' % json.dumps(WASM)


def evaluate(library_path, script):
    import ctypes as c
    library = c.CDLL(library_path)
    pointer = c.c_void_p

    def bind(name, result, *arguments):
        fn = getattr(library, name)
        fn.restype, fn.argtypes = result, list(arguments)
        return fn

    create = bind('JSGlobalContextCreate', pointer, pointer)
    release = bind('JSGlobalContextRelease', None, pointer)
    string_new = bind('JSStringCreateWithUTF8CString', pointer, c.c_char_p)
    string_release = bind('JSStringRelease', None, pointer)
    evaluate_js = bind('JSEvaluateScript', pointer, pointer, pointer, pointer,
                       pointer, c.c_int, c.POINTER(pointer))
    to_string = bind('JSValueToStringCopy', pointer, pointer, pointer, c.POINTER(pointer))
    string_size = bind('JSStringGetMaximumUTF8CStringSize', c.c_size_t, pointer)
    string_copy = bind('JSStringGetUTF8CString', c.c_size_t, pointer, pointer, c.c_size_t)
    context = create(None)
    if not context:
        raise RuntimeError('context-creation-failed')
    source = output = None
    try:
        source = string_new(script.encode('utf-8'))
        if not source:
            raise RuntimeError('source-creation-failed')
        exception = pointer()
        value = evaluate_js(context, source, None, None, 1, c.byref(exception))
        if exception.value or not value:
            raise RuntimeError('javascript-evaluation-failed')
        output = to_string(context, value, c.byref(exception))
        if exception.value or not output:
            raise RuntimeError('result-conversion-failed')
        size = string_size(output)
        if not 1 <= size <= 65536:
            raise RuntimeError('result-size-invalid')
        buffer = c.create_string_buffer(size)
        copied = string_copy(output, buffer, size)
        if not copied:
            raise RuntimeError('result-copy-failed')
        return json.loads(buffer.value.decode('utf-8'))
    finally:
        if output:
            string_release(output)
        if source:
            string_release(source)
        release(context)


def report():
    result = {'purpose': 'native-engine-diagnostic-only',
              'python': '.'.join(str(x) for x in sys.version_info[:3]),
              'platform': sys.platform, 'subprocess_required': False,
              'external_requests': False, 'playback_verified': False}
    if sys.platform not in ('darwin', 'ios'):
        result['status'] = 'apple-platform-required'
        return result
    try:
        engine = evaluate(APPLE_FRAMEWORK, SCRIPT)
        result['engine'] = engine
        result['status'] = ('wasm-test-passed' if engine.get('javascript') == 42
                            and engine.get('wasm') == 42 else 'wasm-test-failed')
    except (ImportError, OSError, AttributeError, RuntimeError, ValueError, TypeError) as exc:
        # Only the exception class, never arbitrary native/SDK response content.
        result['status'] = 'native-engine-unavailable'
        result['error_type'] = type(exc).__name__
    return result


def main(argv=None):
    import argparse
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    parser = argparse.ArgumentParser(description='JavaScriptCore 原生检测；不是播放服务')
    parser.add_argument('port', nargs='?', type=int, default=18770)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error('invalid port')
    print('JavaScriptCore 原生检测：不是频道服务，不提供 all.m3u。', flush=True)
    print('开始调用系统 JavaScriptCore；若服务中止，请保留日志。', flush=True)
    result = report()
    print('原生引擎检测结果：'+json.dumps(result, ensure_ascii=False), flush=True)
    print('wasm-test-passed 仅证明基础运行能力，尚不证明央视可播放。', flush=True)
    if args.once:
        return

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = self.path.split('?', 1)[0]
            status = 200 if path in ('/', '/status') else 503 if path == '/all.m3u' else 404
            value = result if status == 200 else {'error': 'diagnostic-only-no-playlist'}
            body = json.dumps(value, ensure_ascii=False).encode('utf-8')
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

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.daemon_threads = True
    print(f'检测报告监听：http://127.0.0.1:{args.port}/status', flush=True)
    try:
        server.serve_forever(poll_interval=.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
