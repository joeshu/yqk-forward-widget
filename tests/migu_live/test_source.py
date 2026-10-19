from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import threading
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

from migu import core as m, source as p, service as s
from test_service import catalogue
import live_fixture


class SourceTests(unittest.TestCase):
    def store(self,client=None,**kwargs):
        client=client or Mock();client.get.return_value=(catalogue(),{})
        store=p.ListStore(client_factory=Mock(return_value=client),min_channels=1,**kwargs)
        self.addCleanup(store.close)
        return store,client

    def finish(self,store):
        with store.lock:future=store.future
        if future:future.result(3)

    def test_explicit_list_entrypoint_never_instantiates_native_resolver(self):
        store,client=self.store()
        server=Mock();server.serve_forever.side_effect=KeyboardInterrupt
        with patch.object(s,'ListStore',return_value=store) as selected, patch.object(s,'NativeStore',side_effect=AssertionError('anonymous API selected')), patch.object(s,'BoundedServer',return_value=server):
            self.assertEqual(s.main(["--provider","list"]),0)
        selected.assert_called_once_with('auto')
        client.get.assert_not_called()

    def test_published_list_urls_are_preserved_without_anonymous_api(self):
        store,client=self.store()
        snapshot=store.get(2)
        self.assertEqual(store.resolve('p100'),snapshot.channels['p100'].url)
        self.assertIn('token=source-private',store.resolve('p100'))
        self.assertEqual(client.get.call_args.args[0],p.LIST_SOURCES[0])
        self.assertEqual(client.get.call_count,1)
        self.assertEqual(store.status()['source'],'github')

    def test_stale_github_snapshot_falls_back_to_fresh_original_source(self):
        client=Mock();client.get.side_effect=[(catalogue(signed_at=m.utcnow()-timedelta(hours=13)),{}),(catalogue(),{})]
        store=p.ListStore(client_factory=Mock(return_value=client),min_channels=1);self.addCleanup(store.close)
        self.assertEqual(len(store.get(2).channels),2)
        self.assertEqual(store.status()['source'],'upstream-http')
        self.assertEqual([call.args[0] for call in client.get.call_args_list],list(p.LIST_SOURCES))

    def test_parallel_subscriptions_share_one_fetch_and_refresh_failure_keeps_good_snapshot(self):
        now=[0];store,client=self.store(clock=lambda:now[0]);gate=threading.Event();entered=threading.Event()
        def fetch(*args,**kwargs):entered.set();gate.wait(2);return catalogue(),{}
        client.get.side_effect=fetch
        with ThreadPoolExecutor(max_workers=8) as workers:
            futures=[workers.submit(store.get,3) for _ in range(8)]
            self.assertTrue(entered.wait(1));gate.set();snapshots=[f.result(3) for f in futures]
        self.assertTrue(all(x is snapshots[0] for x in snapshots));self.assertEqual(client.get.call_count,1)
        now[0]=61;client.get.side_effect=m.FetchError('HTTP_503')
        self.assertIs(store.get(0),snapshots[0]);self.finish(store)
        self.assertIs(store.get(0),snapshots[0]);self.assertEqual(store.status()['last_error'],'HTTP_503')
        with patch.object(p,'utcnow',return_value=m.utcnow()+timedelta(hours=13)):
            self.assertFalse(store.status()['catalogue_ready'])

    def test_catalogue_hosts_are_exactly_the_two_known_endpoints(self):
        for url in p.LIST_SOURCES:m.validate_url(url,'catalogue')
        for url in ['http://127.0.0.1/list','https://raw.githubusercontent.com/other/repo/main/file','http://www.52top.com.cn:678/private','https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu.m3u8?x=1']:
            with self.assertRaises(m.UpdateError):m.validate_url(url,'catalogue')

    def test_metadata_directive_injection_and_private_streams_are_rejected(self):
        for raw in [catalogue().replace(b'#EXTINF:',b'#EXTVLCOPT:http-referrer=bad\n#EXTINF:',1),catalogue().replace(b'gslbmgsplive.miguvideo.com',b'127.0.0.1')]:
            with self.assertRaises(m.UpdateError):p.parse_source_list(raw)


class SourceHttpTests(unittest.TestCase):
    request=live_fixture.request

    def test_local_playlist_redirect_and_catchup_use_source_urls_not_anonymous_api(self):
        client=Mock();client.get.return_value=(catalogue(catchup=True),{})
        store=p.ListStore(client_factory=Mock(return_value=client),min_channels=1)
        service=s.Service(store,'','http://127.0.0.1:0',require_token=False)
        server=s.BoundedServer(('127.0.0.1',0),service);service.public_base=f'http://127.0.0.1:{server.server_address[1]}'
        thread=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.01},daemon=True);thread.start()
        try:
            code,_,body=self.request(server,'/all.m3u');self.assertEqual(code,200)
            self.assertIn(b'/epg.xml',body);self.assertIn(b'catchup-source="?playbackbegin=',body)
            code,headers,_=self.request(server,'/live/p100.m3u8')
            self.assertEqual(code,302);self.assertEqual(headers['Location'],store.resolve('p100'))
            end=m.utcnow().astimezone(m.CHINA)-timedelta(minutes=1);begin=end-timedelta(minutes=30)
            query='playbackbegin='+begin.strftime('%Y%m%d%H%M%S')+'&playbackend='+end.strftime('%Y%m%d%H%M%S')
            code,headers,_=self.request(server,'/live/p100.m3u8?'+query)
            self.assertEqual(code,302);self.assertEqual(headers['Location'],store.resolve('p100')+'&'+query)
            self.assertEqual(self.request(server,'/live/p100.m3u8?playbackbegin=bad')[0],400)
            self.assertEqual(client.get.call_count,1)
        finally:server.shutdown();server.server_close();service.close();thread.join(1)
