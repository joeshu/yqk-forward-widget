import argparse
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from test_gateway import g


def resolver(interval=0.02):
    return g.Resolver(argparse.Namespace(
        timeout=1, insecure_tls=False, meta_json='/nonexistent/ysp-r3-cache',
        device_json='/nonexistent/ysp-r3-device', refresh_interval=interval,
        control_step_jitter_min_ms=0, control_step_jitter_max_ms=0,
        session_ttl=7200,
    ))


class ConcurrencyTests(unittest.TestCase):
    def test_control_slot_serializes_entire_request_and_interval(self):
        r = resolver()
        barrier = threading.Barrier(3)
        active = 0
        peak = 0
        starts = []
        guard = threading.Lock()

        def worker():
            nonlocal active, peak
            barrier.wait()
            with r.control_request_slot('test'):
                with guard:
                    active += 1
                    peak = max(peak, active)
                    starts.append(time.monotonic())
                time.sleep(0.04)
                with guard:
                    active -= 1

        threads = [threading.Thread(target=worker) for _ in range(2)]
        for t in threads: t.start()
        barrier.wait()
        for t in threads: t.join(2)
        self.assertTrue(all(not t.is_alive() for t in threads))
        self.assertEqual(peak, 1)
        self.assertGreaterEqual(min(abs(starts[1] - starts[0]), 10), 0.02)
        self.assertGreaterEqual(max(starts) - min(starts), 0.055)

    def test_parallel_expired_session_requests_share_one_bootstrap(self):
        r = resolver()
        entered = threading.Event()
        release = threading.Event()
        calls = []
        sentinel = SimpleNamespace(created_at=g.now_f64(), generation=1)

        def bootstrap(*args, **kwargs):
            calls.append(1)
            entered.set()
            release.wait(1)
            return sentinel

        results = []
        with patch.object(r, 'bootstrap_session', side_effect=bootstrap):
            first = threading.Thread(target=lambda: results.append(r.ensure_slot_session(0)))
            second = threading.Thread(target=lambda: results.append(r.ensure_slot_session(0)))
            first.start()
            self.assertTrue(entered.wait(1))
            second.start()
            time.sleep(0.03)
            release.set()
            first.join(2); second.join(2)
        self.assertFalse(first.is_alive() or second.is_alive())
        self.assertEqual(len(calls), 1)
        self.assertEqual(results, [sentinel, sentinel])


if __name__ == '__main__':
    unittest.main()
