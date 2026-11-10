#!/usr/bin/env python3
"""Measure duplicate-HLS bootstrap under a controlled serial loopback origin.

The origin delay is synthetic. This measures request coalescing, not iOS first
frame, decoder speed, CDN throughput, or a production performance percentage.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import http.server
import json
from pathlib import Path
import statistics
import sys
import threading
import time
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Tests'))
from test_relay_manifest_coalescing import ManifestCoalescingTests


def measure(requests, delay, coalesce):
    fixture = ManifestCoalescingTests()
    fixture.upstream_server_class = http.server.HTTPServer
    fixture.upstream_delay = delay
    fixture.setUp()
    fixture.release.set()
    gate = threading.Barrier(requests)

    def fetch(token):
        gate.wait(timeout=5)
        return fixture.fetch(token)

    try:
        token = fixture.token()
        bypass = (mock.patch.object(fixture.relay, '_join_manifest_fetch', return_value=(None, True))
                  if not coalesce else mock.patch.object(fixture.relay, '_join_manifest_fetch',
                                                         wraps=fixture.relay._join_manifest_fetch))
        with bypass, ThreadPoolExecutor(max_workers=requests) as executor:
            started = time.perf_counter()
            responses = list(executor.map(fetch, [token] * requests))
            elapsed_ms = (time.perf_counter() - started) * 1000
        if any(status != 200 for status, _, _ in responses):
            raise RuntimeError('fixture HTTP request failed')
        return {'elapsed_ms': round(elapsed_ms, 2), 'upstream_gets': len(fixture.upstream_calls)}
    finally:
        fixture.tearDown()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--requests', type=int, default=4, choices=range(2, 9))
    parser.add_argument('--delay-ms', type=int, default=150, choices=range(20, 1001))
    parser.add_argument('--repeats', type=int, default=3, choices=range(1, 11))
    args = parser.parse_args()
    results = {}
    for name, coalesce in (('independent_fetches', False), ('inflight_coalescing', True)):
        runs = [measure(args.requests, args.delay_ms / 1000, coalesce) for _ in range(args.repeats)]
        results[name] = {'median_elapsed_ms': round(statistics.median(r['elapsed_ms'] for r in runs), 2),
                         'runs': runs}
    print(json.dumps({'scope': 'synthetic serial loopback origin; not device first-frame performance',
                      'parallel_requests': args.requests, 'upstream_delay_ms': args.delay_ms,
                      'results': results}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
