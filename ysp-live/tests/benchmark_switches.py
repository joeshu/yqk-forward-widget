"""Offline playlist GET latency comparison, not first-frame video decoding.
Uses real HTTP handlers, real refresh coalescing, real bounded device pool and
real debounce. Only upstream fetch actions and long-lived loops are stubbed.
"""
import argparse, collections, concurrent.futures, contextlib, hashlib, http.client, importlib.util, json, pathlib, platform, re, sys, threading, time, types
from http.server import ThreadingHTTPServer
from unittest import mock

PL = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:{sequence}\n#EXTINF:6,\nhttps://media.example.test/{sequence}.ts\n'

def load(name, path):
    spec = importlib.util.spec_from_file_location('latency_' + name.replace('.', '_'), path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

def run(module, current, scenario):
    ch = module.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'fhd')
    ch.thread = types.SimpleNamespace(is_alive=lambda: True)
    if scenario['warm']:
        age = scenario.get('backup_age', 0)
        ch.mode, ch.bk_playlist = 'bk', PL.format(sequence=1)
        ch.last_built_playlist, ch.last_built_time = ch.bk_playlist, time.time() - age
        ch.last_ok = time.time() - age
        if current:
            ch.last_built_source, ch.last_fetch_success_at = 'backup:bk', time.time() - age
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=4)
    release = threading.Event()
    if current and scenario.get('pool_busy'):
        for _ in range(4):
            entered = threading.Event()
            pool.submit(lambda event=entered: (event.set(), release.wait(15)))
            assert entered.wait(1)
    resolver = module.Resolver.__new__(module.Resolver)
    resolver.state_lock = threading.Lock()
    resolver.state = module.ResolverState()
    resolver.args = types.SimpleNamespace(foreground_wait=2.0, zap_debounce=scenario.get('zap',10))
    resolver.stop_event = threading.Event()
    resolver._foreground_pool, resolver._foreground_flights = pool, {}
    resolver._stats, resolver._zap_interest = collections.Counter(), {}
    resolver._playlist_raw = {}
    resolver.is_channel_in_cooldown = lambda channel: False
    resolver._zap_resolve_worker = lambda *args: None
    times = {}
    def device(channel, host, proto='http', **kwargs):
        times['device_enter_ms'] = round((time.monotonic()-started)*1000, 1)
        if resolver.zap_debounced(channel):
            times['device_debounced'] = True
            return None
        time.sleep(scenario['device_delay'])
        return None
    resolver.fetch_channel_playlist = device
    def backup(channel):
        times['backup_enter_ms'] = round((time.monotonic()-started)*1000, 1)
        times['backup_fetches'] = times.get('backup_fetches',0) + 1
        time.sleep(scenario['backup_delay'])
        with ch.lock:
            ch.mode, ch.bk_playlist = 'bk', PL.format(sequence=2)
            ch.last_ok = time.time()
            if current: ch.last_fetch_success_at = time.time()
        return True
    stack = contextlib.ExitStack()
    replacements = {'CHANNEL_MAP': {'cctv1': ch}, 'resolver': resolver, 'resolver_ready': lambda: not scenario.get('backup_only'), 'active_backend_channels': {'cctv1'}, 'refresh_once': backup, 'refresh_loop':lambda ch:None, 'fetch_upstream_engine_playlist': lambda *args: None, 'log':lambda *args,**kwargs:None}
    if current:
        replacements.update({'engine_enabled':False,'media_probe_manager':None,'schedule_source_probe':lambda *args:None,'epg_manager':None})
    for key,value in replacements.items():
        stack.enter_context(mock.patch.object(module,key,value))
    klass = module.BoundedHTTPServer if current else ThreadingHTTPServer
    server = klass(('127.0.0.1', 0), module.Handler)
    server.access_token = ''
    serving = threading.Thread(target=server.serve_forever, kwargs={'poll_interval':0.01}, daemon=True)
    serving.start()
    started = time.monotonic()
    try:
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=10)
        conn.request('GET','/cctv1.m3u8')
        response = conn.getresponse()
        body = response.read()
        elapsed = round((time.monotonic()-started)*1000,1)
        conn.close()
        match = re.search(rb'media\.example\.test/(\d+)\.ts', body)
        return {'status':response.status,'elapsed_ms':elapsed,'playlist':body.startswith(b'#EXTM3U'),'upstream_segment':int(match[1]) if match else None,**times,'foreground_timeouts':resolver._stats['foreground_timeout']}
    finally:
        release.set()
        resolver.stop_event.set()
        server.shutdown()
        server.server_close()
        serving.join(1)
        pool.shutdown(wait=True)
        with module._inflight_lock:
            task = module._inflight_refresh.get(ch.slug)
        if task:
            (task.event if current else task).wait(5)
        stack.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original', type=pathlib.Path, required=True, help='original ysp-live-v9.5.py source')
    parser.add_argument('--output', type=pathlib.Path, required=True)
    options = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    PATHS = {'original': options.original, 'v9.5.14': root / 'ysp-live-v9.5.14.py', 'v9.5.15': root / 'ysp-live-v9.5.15.py'}
    modules = {key:load(key,path) for key,path in PATHS.items()}
    scenarios = {
        'device_debounced_cold_backup_50ms':dict(warm=False,device_delay=0,backup_delay=.05),
        'device_debounced_warm_backup':dict(warm=True,device_delay=0,backup_delay=.05),
        'device_slow_3s_cold_backup_300ms':dict(warm=False,device_delay=3,backup_delay=.3,zap=0),
        'device_debounced_pool_busy_cold_backup_300ms':dict(warm=False,device_delay=0,backup_delay=.3,pool_busy=True),
        'device_debounced_pool_busy_warm_backup':dict(warm=True,device_delay=0,backup_delay=.05,pool_busy=True),
        'device_slow_pool_busy_cold_backup_300ms':dict(warm=False,device_delay=3,backup_delay=.3,pool_busy=True,zap=0),
        'expired_backup_180s_backup_only_300ms':dict(warm=True,device_delay=0,backup_delay=.3,backup_age=180,backup_only=True),
    }
    results = {name:{version:run(modules[version],version!='original',scenario) for version in modules} for name,scenario in scenarios.items()}
    results['_meta'] = {'python': platform.python_version(), 'platform': platform.platform(),
        'measurement': 'offline HTTP playlist response; one sample per scenario; not video first frame',
        'source_sha256': {name: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() for name,path in PATHS.items()}}
    options.output.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(results,ensure_ascii=False,indent=2))
