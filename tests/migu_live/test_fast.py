from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import http.server
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

from migu import core as m, epg as e, native as n, service as s
from test_epg import payload


class CacheTests(unittest.TestCase):
    def store(self,path=None,clock=time.monotonic,client=None):
        client=client or Mock()
        if client.get.side_effect is None:
            client.get.side_effect=lambda url,**k:(payload(urlsplit(url).path.split('/')[-2]),{})
        store=e.EpgStore(cache_path=path,clock=clock,client_factory=Mock(return_value=client))
        self.addCleanup(store.close)
        return store,client

    def finish(self,store):
        with store.lock: future=store.future
        if future:future.result(4)

    def test_restart_reuses_valid_private_cache_without_refetch_or_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'epg.json'
            first,client=self.store(path);first.get(3);self.finish(first)
            self.assertTrue(path.exists());self.assertEqual(path.stat().st_mode&0o777,0o600)
            old=path.stat().st_mtime_ns
            second,network=self.store(path)
            self.assertTrue(second.status()['ready']);self.assertIn(b'<programme',second.get(0));self.finish(second)
            network.get.assert_not_called();self.assertEqual(path.stat().st_mtime_ns,old)
            self.assertEqual(second.status()['matched_channels'],len(n.BUILTIN_CHANNELS))

    def test_invalid_expired_and_symlink_cache_never_block_memory_service(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'epg.json';first,_=self.store(path);first.get(3);self.finish(first)
            saved=json.loads(path.read_text());saved['saved_at']-=37*3600;path.write_text(json.dumps(saved))
            expired,_=self.store(path);self.assertFalse(expired.status()['ready'])
            path.write_text('{broken');broken,_=self.store(path);self.assertFalse(broken.status()['ready'])
            target=Path(directory)/'keep';target.write_text('unchanged');path.unlink();path.symlink_to(target)
            linked,_=self.store(path);linked.get(3);self.finish(linked)
            self.assertTrue(linked.status()['ready']);self.assertEqual(target.read_text(),'unchanged')
            self.assertEqual(linked.status()['storage'],'memory-fallback')

    def test_disk_failure_falls_back_to_memory_and_preserves_previous_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'epg.json';path.write_text('previous')
            store,_=self.store(path)
            with patch.object(e.tempfile,'NamedTemporaryFile',side_effect=PermissionError('readonly')):
                self.assertIn(b'<programme',store.get(3));self.finish(store)
            self.assertEqual(path.read_text(),'previous');self.assertEqual(store.status()['storage'],'memory-fallback')

    def test_failed_channels_back_off_progressively_instead_of_every_refresh(self):
        now=[0];client=Mock();client.get.side_effect=m.FetchError('HTTP_503')
        store,_=self.store(clock=lambda:now[0],client=client)
        for tick in [0,901]:
            now[0]=tick
            with self.assertRaises(m.FetchError):store.get(3)
            self.finish(store)
        calls=client.get.call_count
        self.assertEqual(calls,2*len(n.BUILTIN_CHANNELS))
        now[0]=1802
        with self.assertRaises(m.FetchError):store.get(3)
        self.finish(store);self.assertEqual(client.get.call_count,calls)

    def test_missing_channels_are_refreshed_before_old_successful_rows(self):
        store,client=self.store();store.get(3);self.finish(store)
        pid=n.BUILTIN_CHANNELS[-1][0]
        store.rows.pop(pid);store.attempts={};store.fresh_until=0;store.retry_at=0
        client.get.reset_mock();store.get(0);self.finish(store)
        self.assertIn('/'+pid+'/',client.get.call_args_list[0].args[0])


class EightWayTests(unittest.TestCase):
    def test_each_download_pool_supports_eight_and_network_total_is_bounded_to_eight(self):
        store=n.NativeStore();manifest=s.ManifestCache();epg=e.EpgStore()
        try:
            self.assertEqual(store.pool.max_workers,8)
            self.assertEqual(manifest.pool.max_workers,8)
            self.assertEqual(epg.downloads.max_workers,8)
            self.assertEqual(m.network_workers().max_workers,8)
        finally:store.close();manifest.close();epg.close()

    def test_eight_distinct_channel_fetches_run_together_and_ninth_is_rejected(self):
        full,release=threading.Event(),threading.Event();count=[0];lock=threading.Lock()
        def resolve(pid):
            with lock:
                count[0]+=1
                if count[0]==8:full.set()
            release.wait(3);return 'url'
        store=n.NativeStore(resolver=resolve)
        try:
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures=[pool.submit(store.resolve,'p'+x[0]) for x in n.BUILTIN_CHANNELS[:8]]
                self.assertTrue(full.wait(2))
                with self.assertRaisesRegex(m.FetchError,'CAPACITY'):store.resolve('p'+n.BUILTIN_CHANNELS[8][0])
                release.set();self.assertEqual([f.result(3) for f in futures],['url']*8)
        finally:release.set();store.close()


class SlowHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        try:
            if self.path=='/redirect':
                self.send_response(302);self.send_header('Location','/body');self.end_headers();return
            if self.path=='/headers':
                self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: 100\r\nX-Slow: ');self.wfile.flush()
            else:
                self.send_response(200);self.send_header('Content-Length','100');self.end_headers()
            for _ in range(100):
                self.wfile.write(b'a');self.wfile.flush();time.sleep(.04)
        except OSError:self.server.aborted.set()


class BudgetTests(unittest.TestCase):
    def test_total_deadline_covers_slow_headers_body_and_redirects_and_closes_socket(self):
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),SlowHandler);server.daemon_threads=True
        thread=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.01},daemon=True);thread.start()
        try:
            for path in ['/headers','/body','/redirect']:
                with self.subTest(path=path):
                    server.aborted=threading.Event()
                    client=m.HttpClient('api',attempts=1,timeout=3,budget=.25)
                    with patch.object(m,'validate_url',side_effect=lambda url,role:urlsplit(url)):
                        start=time.monotonic()
                        with self.assertRaisesRegex(m.FetchError,'FETCH_BUDGET_EXCEEDED'):
                            client.get(f'http://127.0.0.1:{server.server_port}'+path)
                        self.assertLess(time.monotonic()-start,1.2)
                    self.assertTrue(server.aborted.wait(1))
        finally:server.shutdown();server.server_close();thread.join(1)

    def test_blocked_connection_setup_is_bounded_for_caller_and_remains_in_limited_daemon_pool(self):
        client=m.HttpClient('api',attempts=1,budget=.1)
        release=threading.Event()
        def blocked(*args,**kwargs):release.wait(1);raise m.FetchError('NETWORK_ERROR')
        try:
            with patch.object(m,'validate_url',side_effect=lambda url,role:urlsplit(url)),patch.object(m.BoundedTransport,'get',side_effect=blocked):
                start=time.monotonic()
                with self.assertRaisesRegex(m.FetchError,'FETCH_BUDGET_EXCEEDED'):client.get('https://play.miguvideo.com/playurl/v1/play/playurl')
                self.assertLess(time.monotonic()-start,.8)
                self.assertTrue(all(t.daemon for t in m.network_workers().threads))
        finally:release.set()
