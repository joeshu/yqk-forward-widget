"""Repeatable CPU/loopback comparison, using no real live upstream.

Run from this repository:
  python ysp-live/tests/benchmark_playlists.py --output ysp-live/benchmark-9.5.4.json
An isolated worker process is used for each version. RSS includes the Python runtime,
local HTTP server and local benchmark clients, not only the playlist cache.
"""
import argparse
import concurrent.futures
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import platform
import resource
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


def fixture():
    lines = ['#EXTM3U', '#EXT-X-TARGETDURATION:6', '#EXT-X-MEDIA-SEQUENCE:100']
    for index in range(15):
        lines += ['#EXTINF:6,', f'https://media.cctv.cn/{index}.ts?sig=fixture']
    return '\n'.join(lines) + '\n'


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))]


def worker(module_path, per_client=150):
    spec = importlib.util.spec_from_file_location('ysp_benchmark_application', module_path)
    app = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = app
    # Force the same import path: candidate .pyc files must not bias baseline RSS.
    exec(compile(Path(module_path).read_bytes(), str(module_path), 'exec'), app.__dict__)
    text = fixture()
    count = [0]
    if not hasattr(app, 'playlist_analysis_cache'):
        original = app.parse_media
        def counted(body):
            count[0] += 1
            return original(body)
        app.parse_media = counted
    iterations, repeats = 3000, 3
    micro = []
    for _ in range(repeats):
        channel = app.Channel('cctv1', 'Fixture', 'sid', 'pid', 'best')
        selector = app.SourceSelector()
        # Warm exactly the same path once; measured calls use the same live window.
        selector.success('device', text, .001)
        app.publish_channel_playlist(channel, text, 'device')
        started, cpu = time.perf_counter(), time.process_time()
        for _ in range(iterations):
            selector.success('device', text, .001)
            app.publish_channel_playlist(channel, text, 'device')
        micro.append({'wall_ms_per_1000': (time.perf_counter() - started) * 1000 / iterations * 1000,
                      'cpu_ms_per_1000': (time.process_time() - cpu) * 1000 / iterations * 1000})
    app.source_loaders = lambda ch, origin, head_only=False: {'device': lambda: (text, 'device', {})}
    app.CHANNEL_MAP = {}
    http_rows = []
    for clients in (1, 8, 20):
        rounds = []
        for _ in range(repeats):
            app.CHANNEL_MAP['cctv1'] = app.Channel('cctv1', 'Fixture', 'sid', 'pid', 'best')
            server = app.BoundedHTTPServer(('127.0.0.1', 0), app.Handler, max_connections=64)
            server.access_token = ''
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
            thread.start()
            try:
                barrier = threading.Barrier(clients)
                def client(_):
                    latencies, success, errors = [], 0, 0
                    connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=10)
                    barrier.wait()
                    try:
                        for _ in range(per_client):
                            start = time.perf_counter()
                            connection.request('GET', '/cctv1.m3u8')
                            response = connection.getresponse()
                            body = response.read()
                            success += response.status == 200 and body.startswith(b'#EXTM3U')
                            errors += response.status != 200
                            latencies.append((time.perf_counter() - start) * 1000)
                    finally:
                        connection.close()
                    return latencies, success, errors
                started, cpu = time.perf_counter(), time.process_time()
                with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
                    rows = list(pool.map(client, range(clients)))
                elapsed, cpu_used = time.perf_counter() - started, time.process_time() - cpu
                latencies = [value for row in rows for value in row[0]]
                success, errors = sum(row[1] for row in rows), sum(row[2] for row in rows)
                rounds.append({'requests': len(latencies), 'successes': success, 'errors': errors,
                               'requests_per_second': success / elapsed,
                               'p50_ms': percentile(latencies, .5), 'p95_ms': percentile(latencies, .95),
                               'p99_ms': percentile(latencies, .99), 'max_ms': max(latencies),
                               'cpu_ms_per_1000': cpu_used / len(latencies) * 1000000})
            finally:
                server.shutdown()
                server.server_close()
                thread.join(2)
        http_rows.append({'clients': clients, 'rounds': rounds,
            'median': {key: statistics.median(row[key] for row in rounds)
                       for key in ('requests_per_second', 'p50_ms', 'p95_ms', 'p99_ms', 'max_ms', 'cpu_ms_per_1000')},
            'total_requests': sum(row['requests'] for row in rounds),
            'total_successes': sum(row['successes'] for row in rounds),
            'total_errors': sum(row['errors'] for row in rounds)})
    analysis = app.playlist_analysis_cache.stats() if hasattr(app, 'playlist_analysis_cache') else {'parses': count[0]}
    result = {'version': app.__version__, 'source_sha256': hashlib.sha256(Path(module_path).read_bytes()).hexdigest(),
              'micro_iterations_per_round': iterations, 'repeats': repeats, 'http_requests_per_client': per_client,
              'micro_rounds': micro, 'micro_median': {key: statistics.median(row[key] for row in micro) for key in micro[0]},
              'http': http_rows, 'peak_rss_kib': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
              'analysis': analysis, 'upstream_requests': 0}
    print(json.dumps(result))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-ref', default='b6bd093')
    parser.add_argument('--baseline-file', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'benchmark-9.5.4.json')
    parser.add_argument('--worker', type=Path)
    parser.add_argument('--requests-per-client', type=int, default=150, help='HTTP请求数/客户端/轮，默认150；复现9.5.3历史短突发结果时指定30')
    args = parser.parse_args()
    if not 1 <= args.requests_per_client <= 500:
        parser.error('requests-per-client must be between 1 and 500')
    if args.worker:
        worker(args.worker, args.requests_per_client)
        return
    with tempfile.TemporaryDirectory() as temp:
        baseline = Path(temp) / 'ysp-baseline.py'
        if args.baseline_file:
            baseline.write_bytes(args.baseline_file.read_bytes())
        else:
            baseline.write_bytes(subprocess.check_output(['git', 'show', args.baseline_ref + ':ysp-live/ysp-live.py'], cwd=ROOT.parent))
        results = {}
        for name, path in [('before', baseline), ('after', ROOT / 'ysp-live-v9.5.16.py')]:
            output = subprocess.check_output([sys.executable, __file__, '--worker', str(path), '--requests-per-client', str(args.requests_per_client)], text=True, cwd=ROOT)
            results[name] = json.loads(output)
        report = {'environment': {'python': platform.python_version(), 'platform': platform.platform(),
                                  'cpu_count': os.cpu_count()},
                  'baseline_ref': args.baseline_ref, 'import_mode': 'compile-source-for-both',
                  'scope': '15-segment repeated live-window analysis/publication, then loopback playlist HTTP; median of 3 rounds',
                  'limits': ['No real channel, device registration, CDN, telemetry or EPG requests.',
                             'No claim about first video frame, decoding, public network throughput or video quality.',
                             'Background media probes are not started: this isolates the cached playlist path.',
                             'Peak RSS is for the entire isolated worker including source compilation and its local HTTP clients.',
                             'Both versions are compiled from source; candidate bytecode cache reuse is bypassed.'],
                  **results}
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        summary = {'output': str(args.output),
                   'micro_cpu_before': results['before']['micro_median']['cpu_ms_per_1000'],
                   'micro_cpu_after': results['after']['micro_median']['cpu_ms_per_1000'],
                   'http': [{'clients': a['clients'], 'before': b['median'], 'after': a['median'],
                             'errors': a['total_errors'] + b['total_errors']}
                            for b, a in zip(results['before']['http'], results['after']['http'])]}
        print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
