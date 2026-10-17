"""Deterministic DNS tests; all hostname resolution is mocked."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ysp_dns


def records(address='8.8.8.8'):
    return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, '', (address, 443))]


def eventually(condition, timeout=1.0):
    deadline =time.monotonic() +timeout
    while not condition():
        if time.monotonic() >=deadline:
            return False
        time.sleep(0.002)
    return True


class DNSTests(unittest.TestCase):
    def resolver(self, **kwargs):
        resolver =ysp_dns.DNSResolver(**kwargs)
        self.addCleanup(resolver.close)
        return resolver

    def test_start_failure_cleans_inflight_and_same_query_recovers(self):
        lookup =mock.Mock(return_value=records())
        resolver =self.resolver(lookup=lookup)
        with mock.patch('ysp_dns.threading.Thread.start', side_effect=RuntimeError('thread limit')):
            with self.assertRaises(ysp_dns.DNSLookupError) as error:
                resolver.resolve('retry.example', 443)
            self.assertEqual(error.exception.status, 503)
        self.assertEqual(resolver.stats()['workers'], 0)
        self.assertEqual(resolver.stats()['inflight'], 0)
        self.assertEqual(resolver.stats()['queued'], 0)
        self.assertEqual(resolver.resolve('retry.example', 443), ['8.8.8.8'])
        self.assertEqual(lookup.call_count, 1)

    def test_ip_literals_bypass_dns_and_create_no_workers(self):
        lookup =mock.Mock(side_effect=AssertionError('literal must not query DNS'))
        resolver =self.resolver(lookup=lookup)
        self.assertEqual(resolver.resolve('8.8.8.8', 443), ['8.8.8.8'])
        self.assertEqual(resolver.resolve('2001:4860:4860::8888', 443), ['2001:4860:4860::8888'])
        self.assertEqual(resolver.resolve('[::1]', 443), ['::1'])
        lookup.assert_not_called()
        self.assertEqual(resolver.stats()['workers'], 0)

    def test_same_host_and_port_share_one_lookup(self):
        entered, release =threading.Event(), threading.Event()
        def lookup(*args, **kwargs):
            entered.set()
            self.assertTrue(release.wait(2.0))
            return records() +records()
        lookup =mock.Mock(side_effect=lookup)
        resolver =self.resolver(lookup=lookup)
        try:
            with ThreadPoolExecutor(max_workers=8) as pool:
                tasks =[pool.submit(resolver.resolve, 'MEDIA.EXAMPLE.', 443) for _ in range(8)]
                self.assertTrue(entered.wait(1.0))
                self.assertTrue(eventually(lambda: resolver.stats()['shared'] ==7))
                release.set()
                self.assertEqual([task.result(timeout=1.0) for task in tasks], [['8.8.8.8']] *8)
        finally:
            release.set()
        self.assertEqual(lookup.call_count, 1)
        self.assertEqual(resolver.stats()['workers'], 1)
        lookup.assert_called_once_with('media.example', 443, type=socket.SOCK_STREAM)

    def test_positive_cache_uses_ttl_and_returns_independent_lists(self):
        now =[100.0]
        lookup =mock.Mock(return_value=records())
        resolver =self.resolver(lookup=lookup, clock=lambda: now[0])
        first =resolver.resolve('media.example', 443)
        first.append('1.1.1.1')
        now[0] =159.9
        self.assertEqual(resolver.resolve('MEDIA.EXAMPLE.', '443'), ['8.8.8.8'])
        self.assertEqual(lookup.call_count, 1)
        now[0] =160.1
        self.assertEqual(resolver.resolve('media.example', 443), ['8.8.8.8'])
        self.assertEqual(lookup.call_count, 2)
        resolver.resolve('media.example', 80)
        self.assertEqual(lookup.call_count, 3)

    def test_failures_are_shared_for_short_ttl(self):
        now =[10.0]
        lookup =mock.Mock(side_effect=socket.gaierror('simulated DNS failure'))
        resolver =self.resolver(lookup=lookup, clock=lambda: now[0])
        for _ in range(2):
            with self.assertRaises(ysp_dns.DNSLookupError) as error:
                resolver.resolve('missing.example', 443)
            self.assertEqual(error.exception.status, 502)
        self.assertEqual(lookup.call_count, 1)
        now[0] =12.1
        with self.assertRaises(ysp_dns.DNSLookupError):
            resolver.resolve('missing.example', 443)
        self.assertEqual(lookup.call_count, 2)

    def test_timeout_does_not_spawn_replacement_lookups(self):
        entered, release =threading.Event(), threading.Event()
        def lookup(*args, **kwargs):
            entered.set()
            release.wait(2.0)
            return records()
        lookup =mock.Mock(side_effect=lookup)
        resolver =self.resolver(lookup=lookup)
        try:
            started =time.monotonic()
            for _ in range(4):
                with self.assertRaises(ysp_dns.DNSLookupError) as error:
                    resolver.resolve('slow.example', 443, timeout=0.015)
                self.assertEqual(error.exception.status, 504)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() -started, 0.3)
            self.assertEqual(lookup.call_count, 1)
            self.assertEqual(resolver.stats()['workers'], 1)
            self.assertEqual(resolver.stats()['inflight'], 1)
            release.set()
            self.assertTrue(eventually(lambda: resolver.stats()['cached'] ==1))
            self.assertEqual(resolver.resolve('slow.example', 443), ['8.8.8.8'])
            self.assertEqual(lookup.call_count, 1)
        finally:
            release.set()

    def test_running_and_queued_capacity_remain_bounded(self):
        release =threading.Event()
        def lookup(*args, **kwargs):
            release.wait(2.0)
            return records()
        resolver =self.resolver(lookup=lookup, max_workers=2, max_queue=3)
        try:
            for index in range(2):
                with self.assertRaises(ysp_dns.DNSLookupError) as error:
                    resolver.resolve(f'running{index}.example', 443, timeout=0.015)
                self.assertEqual(error.exception.status, 504)
                self.assertTrue(eventually(lambda: resolver.stats()['active'] ==index +1))
            for index in range(3):
                with self.assertRaises(ysp_dns.DNSLookupError) as error:
                    resolver.resolve(f'queued{index}.example', 443, timeout=0.005)
                self.assertEqual(error.exception.status, 504)
            state =resolver.stats()
            self.assertEqual((state['active'], state['queued'], state['inflight']), (2, 3, 5))
            with self.assertRaises(ysp_dns.DNSLookupError) as error:
                resolver.resolve('overload.example', 443, timeout=1.0)
            self.assertEqual(error.exception.status, 503)
            # The same queued query still joins its existing Future at capacity.
            with self.assertRaises(ysp_dns.DNSLookupError) as error:
                resolver.resolve('queued0.example', 443, timeout=0.005)
            self.assertEqual(error.exception.status, 504)
            self.assertEqual(resolver.stats()['workers'], 2)
            self.assertTrue(all(worker.daemon for worker in resolver._workers))
        finally:
            release.set()

    def test_cache_is_bounded_and_uses_lru(self):
        lookup =mock.Mock(return_value=records())
        resolver =self.resolver(lookup=lookup, max_records=3)
        for host in ('a.example', 'b.example', 'c.example'):
            resolver.resolve(host, 443)
        resolver.resolve('a.example', 443)
        resolver.resolve('d.example', 443)
        self.assertEqual(resolver.stats()['cached'], 3)
        resolver.resolve('a.example', 443)
        self.assertEqual(lookup.call_count, 4)
        resolver.resolve('b.example', 443)
        self.assertEqual(lookup.call_count, 5)
        self.assertEqual(resolver.stats()['cached'], 3)
        limits =self.resolver(max_workers=999, max_queue=999, max_records=999)
        self.assertEqual((limits.max_workers, limits.max_queue, limits.max_records), (4, 16, 512))

    def test_close_wakes_waiters_without_waiting_for_system_dns(self):
        entered, release =threading.Event(), threading.Event()
        def lookup(*args, **kwargs):
            entered.set()
            release.wait(2.0)
            return records()
        resolver =self.resolver(lookup=lookup)
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                task =pool.submit(resolver.resolve, 'stuck.example', 443, 10.0)
                self.assertTrue(entered.wait(1.0))
                started =time.monotonic()
                resolver.close()
                with self.assertRaises(ysp_dns.DNSLookupError) as error:
                    task.result(timeout=0.3)
                self.assertEqual(error.exception.status, 503)
                self.assertLess(time.monotonic() -started, 0.3)
        finally:
            release.set()

    def test_module_singleton_starts_workers_lazily(self):
        lookup =mock.Mock(return_value=records())
        with mock.patch.object(ysp_dns, '_default_resolver', None), mock.patch.object(ysp_dns.socket, 'getaddrinfo', lookup):
            try:
                self.assertEqual(ysp_dns.bounded_dns_addresses('8.8.8.8', 443), ['8.8.8.8'])
                self.assertEqual(ysp_dns._default_resolver.stats()['workers'], 0)
                self.assertEqual(ysp_dns.bounded_dns_addresses('media.example', 443), ['8.8.8.8'])
                self.assertEqual(ysp_dns.bounded_dns_addresses('media.example', 443), ['8.8.8.8'])
                self.assertEqual(lookup.call_count, 1)
            finally:
                if ysp_dns._default_resolver is not None:
                    ysp_dns._default_resolver.close()


if __name__ =='__main__':
    unittest.main()
