"""Fault and slow-reader regressions; local fakes only, no DNS or network I/O."""
from __future__ import annotations

import io
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import ysp_runtime as runtime


class _Policy:
    def resolve(self, target):
        return None, ['127.0.0.1']


class _Connection:
    def __init__(self):
        self.timeout = 20

    def gettimeout(self):
        return self.timeout

    def settimeout(self, value):
        self.timeout = value


class _Handler:
    def __init__(self, writer=None):
        self.headers = {}
        self.connection = _Connection()
        self.wfile = writer if writer is not None else io.BytesIO()
        self.close_connection = False
        self.status = None
        self.response_headers = {}

    def send_response(self, status):
        self.status = status

    def send_header(self, name, value):
        self.response_headers[name.lower()] = value

    def end_headers(self):
        pass


class _CloseFailureResponse:
    status = 200
    headers = {'content-length': '1', 'content-type': 'video/mp2t'}
    effective_url = 'https://media.cctv.com/segment.ts'

    def __init__(self):
        self.reads = 0

    def read(self, size):
        self.reads += 1
        return b'x' if self.reads == 1 else b''

    def close(self):
        raise OSError('simulated upstream close failure')


class RuntimeEdgeTests(unittest.TestCase):
    def _cache_segment(self, proxy, target, payload):
        """Seed a successful transfer without doing any network work."""
        with tempfile.TemporaryFile() as buffer:
            buffer.write(payload)
            buffer.flush()
            task = runtime._Transfer(target, {}, file=buffer, status=200,
                                     headers={'content-length': str(len(payload)),
                                              'content-type': 'video/mp2t'}, size=len(payload))
            proxy._store_cache(proxy._key(target, {}), task)

    def test_close_exception_cannot_leak_producer_or_direct_request_capacity(self):
        proxy = runtime.SharedMediaProxy(policy=_Policy(), max_cache_bytes=0, max_downloads=1)
        self.addCleanup(proxy.close)
        target = _CloseFailureResponse.effective_url
        key = proxy._key(target, {})
        task = runtime._Transfer(target, {})
        self.addCleanup(task.file.close)
        proxy.tasks[key] = task
        self.assertTrue(proxy.slots.acquire(blocking=False))
        with patch.object(runtime, 'open_remote', return_value=_CloseFailureResponse()):
            proxy._produce(key, task)
        self.assertTrue(task.done)
        self.assertTrue(task.closed)
        self.assertIsNone(task.error)
        self.assertFalse(proxy.tasks)
        self.assertEqual(proxy.inflight_bytes, 0)
        self.assertTrue(proxy.slots.acquire(blocking=False))
        proxy.slots.release()

        handler = _Handler()
        with patch.object(runtime, 'open_remote', return_value=_CloseFailureResponse()):
            self.assertEqual(proxy._serve_direct(handler, target, {}, head_only=True), 200)
        self.assertEqual(handler.status, 200)
        self.assertTrue(proxy.slots.acquire(blocking=False))
        proxy.slots.release()

    def test_evicted_cache_pinned_by_slow_reader_still_consumes_memory_budget(self):
        proxy = runtime.SharedMediaProxy(policy=_Policy(), max_cache_bytes=64, timeout=2)
        self.addCleanup(proxy.close)
        first_url = 'https://media.cctv.com/first.ts'
        second_url = 'https://media.cctv.com/second.ts'
        first, second = b'a' * 48, b'b' * 48
        self._cache_segment(proxy, first_url, first)
        started, release = threading.Event(), threading.Event()
        received, failures = [], []

        class BlockedWriter:
            def write(self, data):
                started.set()
                if not release.wait(2):
                    raise TimeoutError('test did not release the reader')
                received.append(data)

        handler = _Handler(BlockedWriter())

        def consume():
            try:
                proxy.serve(handler, first_url)
            except BaseException as exc:
                failures.append(exc)

        worker = threading.Thread(target=consume)
        worker.start()
        try:
            self.assertTrue(started.wait(1), 'reader did not pin the cache entry')
            self._cache_segment(proxy, second_url, second)
            self.assertEqual(len(proxy.cache), 0, 'a retired pinned entry must block allocation beyond the budget')
            self.assertEqual(proxy.cache_bytes, len(first))
        finally:
            release.set()
            worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertFalse(failures)
        self.assertEqual(b''.join(received), first)
        self.assertEqual(proxy.cache_bytes, 0)
        self._cache_segment(proxy, second_url, second)
        self.assertEqual(proxy.cache_bytes, len(second))
        self.assertEqual(len(proxy.cache), 1)
        proxy.close()
        self.assertEqual(proxy.cache_bytes, 0)

    def test_buffered_cache_reader_obeys_total_deadline_between_writes(self):
        proxy = runtime.SharedMediaProxy(policy=_Policy(), max_cache_bytes=300000, timeout=1)
        self.addCleanup(proxy.close)
        target = 'https://media.cctv.com/large.ts'
        self._cache_segment(proxy, target, b'x' * (3 * 65536))
        current = [time.monotonic()]
        received = []

        class AdvancingWriter:
            def write(self, data):
                received.append(data)
                current[0] += 10

        handler = _Handler(AdvancingWriter())
        with patch.object(runtime.time, 'monotonic', side_effect=lambda: current[0]):
            proxy.serve(handler, target)
        self.assertEqual(len(received), 1, 'completed buffers must not bypass the request deadline')
        self.assertTrue(handler.close_connection)
        self.assertLessEqual(handler.connection.timeout, 2)
        self.assertEqual(next(iter(proxy.cache.values())).readers, 0)


if __name__ == '__main__':
    unittest.main()
