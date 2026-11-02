#!/usr/bin/env python3
"""Serve media fixtures over loopback HTTP with byte ranges and request evidence."""

import argparse
import json
import mimetypes
import os
from pathlib import Path
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, directory, request_log):
        self.directory = directory.resolve(strict=True)
        self.request_log = request_log
        self.log_lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), FixtureHandler)

    def record(self, record):
        with self.log_lock:
            with self.request_log.open('a', encoding='utf-8') as stream:
                stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + '\n')


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.serve_file(head=True)

    def do_GET(self):
        self.serve_file(head=False)

    def serve_file(self, head):
        record = {'method': self.command, 'path': '', 'range': self.headers.get('Range', ''),
                  'status': 500, 'start': None, 'end': None, 'total': None, 'bytes_sent': 0}
        try:
            relative = unquote(urlsplit(self.path).path, errors='strict').lstrip('/')
            record['path'] = relative
            path = (self.server.directory / relative).resolve(strict=True)
            if not path.is_relative_to(self.server.directory) or not path.is_file():
                raise FileNotFoundError()
            with path.open('rb') as source:
                total = os.fstat(source.fileno()).st_size
                record['total'] = total
                start, end, status = 0, total - 1, 200
                requested = self.headers.get('Range')
                if requested:
                    match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested.strip())
                    if not match or not any(match.groups()) or total == 0:
                        self.range_unsatisfied(record, total)
                        return
                    first, last = match.groups()
                    if not first:
                        suffix = int(last)
                        if suffix == 0:
                            self.range_unsatisfied(record, total)
                            return
                        start = max(0, total - suffix)
                    else:
                        start = int(first)
                        end = min(int(last), total - 1) if last else total - 1
                    if start >= total or start > end:
                        self.range_unsatisfied(record, total)
                        return
                    status = 206
                length = max(0, end - start + 1)
                record.update(status=status, start=start, end=end)
                self.send_response(status)
                mime = 'video/mp4' if path.suffix.lower() == '.mp4' else (
                    mimetypes.guess_type(path.name)[0] or 'application/octet-stream')
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(length))
                self.send_header('Accept-Ranges', 'bytes')
                if status == 206:
                    self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
                self.send_header('Connection', 'close')
                self.end_headers()
                if not head:
                    source.seek(start)
                    remaining = length
                    while remaining:
                        chunk = source.read(min(256 * 1024, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        record['bytes_sent'] += len(chunk)
                        remaining -= len(chunk)
        except (FileNotFoundError, IsADirectoryError, PermissionError, UnicodeError, ValueError):
            record['status'] = 404
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.send_header('Connection', 'close')
            self.end_headers()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            record['disconnected'] = True
        finally:
            self.close_connection = True
            self.server.record(record)

    def range_unsatisfied(self, record, total):
        record['status'] = 416
        self.send_response(416)
        self.send_header('Content-Range', f'bytes */{total}')
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', '0')
        self.send_header('Connection', 'close')
        self.end_headers()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--port-file', type=Path, required=True)
    parser.add_argument('--request-log', type=Path, required=True)
    args = parser.parse_args()
    if not args.directory.is_dir():
        parser.error('--directory must be an existing directory')
    args.port_file.parent.mkdir(parents=True, exist_ok=True)
    args.request_log.parent.mkdir(parents=True, exist_ok=True)
    args.request_log.write_text('', encoding='utf-8')
    with FixtureServer(args.directory, args.request_log) as server:
        pending = args.port_file.with_name(args.port_file.name + '.tmp')
        pending.write_text(str(server.server_port) + '\n', encoding='ascii')
        os.replace(pending, args.port_file)
        print(f'Listening on http://127.0.0.1:{server.server_port}', flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
