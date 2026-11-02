"""Real HTTP coverage for file-backed media larger than the JSON/bytes limit."""
import builtins
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
import host_media_runtime as media

SPEC = importlib.util.spec_from_file_location('media_proxy_streaming_service', PLUGINS / 'media-service.py')
transport = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transport)


def write_fixture(path):
    block = bytes(range(256)) * 4096
    digest = hashlib.sha256()
    with path.open('wb') as stream:
        for _ in range(20):
            stream.write(block)
            digest.update(block)
        tail = b'last-frame-marker' * 17
        stream.write(tail)
        digest.update(tail)
    return path.stat().st_size, digest.hexdigest()


def request(port, method='GET', byte_range=None, collect=True, path='/proxy?url=cenc%3A%2F%2Ffixture'):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        client.request(method, path, headers={'Range': byte_range} if byte_range else {})
        response = client.getresponse()
        headers = {key.lower(): value for key, value in response.getheaders()}
        digest, size, chunks = hashlib.sha256(), 0, []
        while True:
            chunk = response.read(64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            digest.update(chunk)
            if collect:
                chunks.append(chunk)
        return response.status, headers, b''.join(chunks), size, digest.hexdigest()
    finally:
        client.close()


class FileEngine:
    def __init__(self, path, size):
        self.path, self.size = str(path), size
        self.override = None
        self.calls = []

    def capabilities(self):
        return {'capabilities': ['proxy']}

    def call(self, operation, args):
        if operation != 'proxy':
            return {}
        self.calls.append(args)
        if self.override is not None:
            return self.override
        start, end, status = 0, self.size - 1, 200
        value = args.get('range', '')
        if value:
            first, last = value.removeprefix('bytes=').split('-', 1)
            if first:
                start = int(first)
                end = min(int(last), end) if last else end
            else:
                start = max(0, self.size - int(last))
            status = 206
        headers = {'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes',
                   'Content-Length': str(end - start + 1)}
        if status == 206:
            headers['Content-Range'] = f'bytes {start}-{end}/{self.size}'
        return [status, headers, {'__cctvhostFileResponse': True, 'path': self.path,
                                 'offset': start, 'length': end - start + 1}]

    def close(self):
        pass


class TrackedFile:
    def __init__(self, stream, reads):
        self.stream, self.reads = stream, reads

    def __getattr__(self, name):
        return getattr(self.stream, name)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return self.stream.__exit__(*args)

    def read(self, size=-1):
        self.reads.append(size)
        return self.stream.read(size)


class MediaProxyStreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        cls.data = cls.root / 'data'
        cls.data.mkdir()
        cls.path = cls.data / 'video.mp4'
        cls.size, cls.digest = write_fixture(cls.path)
        cls.outside = cls.root / 'outside.mp4'
        cls.outside.write_bytes(b'outside-source-data')
        cls.symlink = cls.data / 'escape.mp4'
        cls.symlink.symlink_to(cls.outside)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.engine = FileEngine(self.path, self.size)
        self.runtime = media.MediaRuntime(self.engine)
        self.server = transport.Server(('127.0.0.1', 0), self.runtime)
        self.server.proxy_file_root = str(self.data)
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=.01), daemon=True)
        self.thread.start()
        self.log_patch = mock.patch.object(transport, 'print', create=True)
        self.log_patch.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.runtime.close()
        self.thread.join(2)
        self.log_patch.stop()

    def ref(self, path=None, offset=0, length=None):
        return {'__cctvhostFileResponse': True, 'path': str(path or self.path),
                'offset': offset, 'length': self.size if length is None else length}

    def test_large_full_get_and_open_range_preserve_entire_file_in_bounded_reads(self):
        self.assertGreater(self.size, 20 * 1024 * 1024)
        for byte_range, expected_status in ((None, 200), ('bytes=0-', 206)):
            with self.subTest(range=byte_range):
                reads = []
                def tracked_open(*args, **kwargs):
                    return TrackedFile(builtins.open(*args, **kwargs), reads)
                with mock.patch.object(transport, 'open', tracked_open, create=True):
                    status, headers, _, size, digest = request(self.server.server_port,
                        byte_range=byte_range, collect=False)
                self.assertEqual((status, size, digest), (expected_status, self.size, self.digest))
                self.assertEqual(headers['content-length'], str(self.size))
                self.assertEqual(headers['content-type'], 'video/mp4')
                self.assertEqual(headers['accept-ranges'], 'bytes')
                if byte_range:
                    self.assertEqual(headers['content-range'], f'bytes 0-{self.size - 1}/{self.size}')
                self.assertTrue(reads)
                self.assertTrue(all(0 < size <= 256 * 1024 for size in reads), reads)
                self.assertEqual(sum(reads), self.size)

    def test_head_uses_full_reference_length_without_reading_file(self):
        self.engine.override = [200, {'Content-Type': 'video/mp4', 'Content-Length': '1'}, self.ref()]
        reads = []
        with mock.patch.object(transport, 'open', lambda *a, **kw: TrackedFile(builtins.open(*a, **kw), reads), create=True):
            status, headers, body, size, _ = request(self.server.server_port, method='HEAD')
        self.assertEqual((status, body, size), (200, b'', 0))
        self.assertEqual(headers['content-length'], str(self.size))
        self.assertEqual(reads, [])
        self.assertEqual(self.engine.calls[-1]['method'], 'HEAD')

    def test_normal_and_suffix_ranges_deliver_selected_bytes(self):
        for value, start, length in (('bytes=253-1032', 253, 780), ('bytes=-117', self.size - 117, 117)):
            with self.subTest(range=value):
                status, headers, body, size, _ = request(self.server.server_port, byte_range=value)
                with self.path.open('rb') as stream:
                    stream.seek(start)
                    expected = stream.read(length)
                self.assertEqual((status, body, size), (206, expected, length))
                self.assertEqual(headers['content-range'], f'bytes {start}-{start + length - 1}/{self.size}')
                self.assertEqual(headers['content-length'], str(length))
                self.assertEqual(self.engine.calls[-1]['range'], value)
                self.assertEqual(self.engine.calls[-1]['headers']['Range'], value)

    def test_unconfigured_outside_and_symlink_references_are_rejected(self):
        for name, root, path in (('unconfigured', None, self.path),
                                 ('outside', str(self.data), self.outside),
                                 ('symlink', str(self.data), self.symlink)):
            with self.subTest(case=name):
                self.server.proxy_file_root = root
                self.engine.override = [200, 'video/mp4', self.ref(path=path, length=1)]
                status, _, body, _, _ = request(self.server.server_port)
                self.assertEqual(status, 502)
                self.assertEqual(json.loads(body)['error']['code'], 'INVALID_PROXY')
                self.assertNotIn(b'outside-source-data', body)

    def test_invalid_integer_ranges_and_file_bounds_are_rejected(self):
        cases = [(-1, 1), (True, 1), (1.5, 1), ('0', 1), (2 ** 63, 0),
                 (0, -1), (0, True), (0, 1.5), (0, '1'), (0, 2 ** 63),
                 (self.size + 1, 0), (self.size, 1), (1, self.size)]
        for offset, length in cases:
            with self.subTest(offset=offset, length=length):
                self.engine.override = [200, 'video/mp4', self.ref(offset=offset, length=length)]
                status, _, body, _, _ = request(self.server.server_port)
                self.assertEqual(status, 502)
                self.assertEqual(json.loads(body)['error']['code'], 'INVALID_PROXY')

    def test_plain_bytes_responses_retain_the_16_mib_limit(self):
        self.engine.override = [200, 'video/mp4', b'x' * (16 * 1024 * 1024 + 1)]
        status, _, body, _, _ = request(self.server.server_port)
        self.assertEqual(status, 502)
        self.assertEqual(json.loads(body)['error']['code'], 'RESULT_TOO_LARGE')


class MediaProxyStartupTests(unittest.TestCase):
    def test_real_python_main_configures_file_root_and_capability_flag(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package, data = root / 'package', root / 'data'
            package.mkdir()
            data.mkdir()
            size, digest = write_fixture(data / 'video.mp4')
            (package / 'spider.py').write_text('''
import os
class Spider:
    def localProxy(self, args):
        if not getattr(self, '_cctvhost_file_proxy_supported', False):
            raise RuntimeError('file proxy capability missing')
        path = os.path.join(self._cctvhost_data_dir, 'video.mp4')
        return [200, {'Content-Type': 'video/mp4'},
                {'__cctvhostFileResponse': True, 'path': path,
                 'offset': 0, 'length': os.path.getsize(path)}]
''', encoding='utf-8')
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            manifest = json.dumps({'runtime': 'python', 'entry': 'spider.py'})
            process = subprocess.Popen([sys.executable, '-u', str(PLUGINS / 'media-service.py'), str(port),
                '--package', str(package), '--manifest', manifest, '--data-dir', str(data)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic() + 10
                ready = False
                while time.monotonic() < deadline:
                    self.assertIsNone(process.poll(), 'media-service exited before readiness')
                    try:
                        status, _, body, _, _ = request(port, path='/health')
                        ready = status == 200 and json.loads(body).get('runtime_ready') is True
                        if ready:
                            break
                    except (ConnectionError, OSError):
                        pass
                    time.sleep(.02)
                self.assertTrue(ready, 'Python media-service did not become ready')
                status, headers, _, received, actual_digest = request(port, collect=False)
                self.assertEqual((status, received, actual_digest), (200, size, digest))
                self.assertEqual(headers['content-length'], str(size))
            finally:
                process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main()
