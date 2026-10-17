"""Lifecycle regressions for the bounded daemon worker pool."""
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

ROOT =Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ysp_resolver_support import ThreadPoolExecutor


class DaemonPoolTests(unittest.TestCase):
    def test_start_failure_rolls_back_task_and_pool_recovers(self):
        pool =ThreadPoolExecutor(max_workers=2)
        try:
            with mock.patch('ysp_resolver_support.threading.Thread.start', side_effect=RuntimeError('thread limit')):
                with self.assertRaisesRegex(RuntimeError, 'cannot start worker'):
                    pool.submit(lambda: 'rejected')
            self.assertEqual(len(pool._tasks), 0)
            self.assertEqual(len(pool._threads), 0)
            self.assertEqual(pool.submit(lambda: 'recovered').result(timeout=1.0), 'recovered')
        finally:
            pool.shutdown(wait=True)

    def test_shutdown_without_wait_does_not_delay_interpreter_exit(self):
        code ='''
import threading
from ysp_resolver_support import ThreadPoolExecutor
entered = threading.Event()
blocked = threading.Event()
pool = ThreadPoolExecutor(max_workers=1)
pool.submit(lambda: (entered.set(), blocked.wait(3600)))
assert entered.wait(1)
assert all(worker.daemon for worker in pool._threads)
pool.shutdown(wait=False)
print('shutdown returned', flush=True)
'''
        result =subprocess.run([sys.executable, '-c', code], cwd=ROOT,
                              capture_output=True, text=True, timeout=3.0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('shutdown returned', result.stdout)

    def test_cancel_futures_cancels_queued_work_only(self):
        started, release =threading.Event(), threading.Event()
        pool =ThreadPoolExecutor(max_workers=1)
        def blocked():
            started.set()
            release.wait(2.0)
            return 'finished'
        try:
            running =pool.submit(blocked)
            self.assertTrue(started.wait(1.0))
            queued =pool.submit(lambda: 'must not execute')
            before =time.monotonic()
            pool.shutdown(wait=False, cancel_futures=True)
            self.assertLess(time.monotonic() -before, 0.1)
            self.assertTrue(queued.cancelled())
            self.assertTrue(running.running())
            self.assertFalse(running.cancelled())
            with self.assertRaises(RuntimeError):
                pool.submit(lambda: None)
            release.set()
            self.assertEqual(running.result(timeout=1.0), 'finished')
        finally:
            release.set()
            pool.shutdown(wait=True, cancel_futures=True)

    def test_non_cancelled_queue_finishes_during_shutdown(self):
        started, release =threading.Event(), threading.Event()
        pool =ThreadPoolExecutor(max_workers=1)
        def blocked():
            started.set()
            release.wait(2.0)
        try:
            running =pool.submit(blocked)
            self.assertTrue(started.wait(1.0))
            queued =pool.submit(lambda value: value +1, 41)
            pool.shutdown(wait=False, cancel_futures=False)
            self.assertFalse(queued.done())
            release.set()
            self.assertIsNone(running.result(timeout=1.0))
            self.assertEqual(queued.result(timeout=1.0), 42)
        finally:
            release.set()
            pool.shutdown(wait=True)

    def test_pending_queue_is_bounded_and_failure_does_not_kill_worker(self):
        started, release =threading.Event(), threading.Event()
        pool =ThreadPoolExecutor(max_workers=1, max_queue=2)
        def blocked():
            started.set()
            release.wait(2.0)
        try:
            pool.submit(blocked)
            self.assertTrue(started.wait(1.0))
            failed =pool.submit(lambda: 1 /0)
            success =pool.submit(lambda: 'alive')
            with self.assertRaisesRegex(RuntimeError, 'capacity'):
                pool.submit(lambda: None)
            release.set()
            with self.assertRaises(ZeroDivisionError):
                failed.result(timeout=1.0)
            self.assertEqual(success.result(timeout=1.0), 'alive')
        finally:
            release.set()
            pool.shutdown(wait=True)

    def test_pending_cancellation_skips_function_and_context_waits(self):
        started, release =threading.Event(), threading.Event()
        called =[]
        with ThreadPoolExecutor(max_workers=1) as pool:
            running =pool.submit(lambda: (started.set(), release.wait(2.0)))
            self.assertTrue(started.wait(1.0))
            cancelled =pool.submit(lambda: called.append(True))
            self.assertTrue(cancelled.cancel())
            release.set()
            running.result(timeout=1.0)
        self.assertEqual(called, [])
        self.assertTrue(cancelled.cancelled())
        self.assertTrue(all(not worker.is_alive() for worker in pool._threads))


if __name__ =='__main__':
    unittest.main()
