import http.client
import json
import threading
from types import SimpleNamespace
import unittest
from unittest import mock
from test_jscore_service import load_service


class TestMultiChannelHTTP(unittest.TestCase):
    def setUp(self):
        self.m = load_service()
        self.args = SimpleNamespace(warmup=False,buffer_mb=16,idle_timeout=120)
        self.manager = self.m.ChannelManager(self.args)
        self.manager.epg.refresh = mock.Mock()
        self.server = self.m.ThreadingHTTPServer(('127.0.0.1',0),self.m.MultiChannelHandler)
        self.server.daemon_threads=True
        self.server.args,self.server.manager=self.args,self.manager
        self.thread=threading.Thread(target=lambda:self.server.serve_forever(poll_interval=.01),daemon=True)
        self.thread.start()

    def tearDown(self):
        self.manager.close()
        self.server.shutdown();self.server.server_close();self.thread.join(2)

    def request(self,path,method='GET',host=None):
        conn=http.client.HTTPConnection(*self.server.server_address,timeout=2)
        conn.request(method,path,headers={'Host':host} if host else {})
        response=conn.getresponse();body=response.read();status=response.status
        conn.close()
        return status,body

    def test_subscription_contains_only_validated_official_channels_without_starting_all(self):
        status,body=self.request('/all.m3u')
        self.assertEqual(status,200)
        self.assertEqual(body.count(b'#EXTINF:'),14)
        self.assertIn(b'/cctvjilu.m3u8',body)
        self.assertIn(b'/cctvchild.m3u8',body)
        self.assertNotIn(b'/cctv5.m3u8',body)
        self.assertNotIn(b'/cctv9.m3u8',body)
        self.assertIsNone(self.manager.current)
        self.assertEqual(self.request('/all.m3u',host='invalid@host')[0],400)

    def test_playlist_and_media_routes_keep_channel_and_generation_isolated(self):
        channel=self.manager.activate('cctv1')
        channel.generation='a'*32
        channel.started_at=channel.last_request=self.m.time.monotonic()
        channel.publish(b'first-channel',{'duration':4},False)
        channel.publish(b'next-chunk',{'duration':4},False)
        with mock.patch.object(self.m.ManagedChannel,'demand'):
            status,body=self.request('/cctv1.m3u8')
            self.assertEqual(status,200)
            self.assertIn(('media/cctv1/'+'a'*32+'/0.ts').encode(),body)
            self.assertEqual(self.request('/media/cctv1/'+'a'*32+'/0.ts'),(200,b'first-channel'))
            self.assertEqual(self.request('/media/cctv2/'+'a'*32+'/0.ts')[0],410)
        self.assertEqual(self.manager.current,'cctv1')
        self.assertEqual(self.request('/cctv3.m3u8')[0],404)

    def test_head_checks_do_not_switch_or_initialize_channels(self):
        self.assertEqual(self.request('/cctv1.m3u8','HEAD')[0],200)
        self.assertIsNone(self.manager.current)
        self.args.warmup=True
        with mock.patch.object(self.m.ManagedChannel,'demand') as demand:
            self.request('/all.m3u','HEAD');demand.assert_not_called()
            self.request('/all.m3u');self.assertEqual(demand.call_count,1)
            self.assertEqual(self.manager.current,'cctv2')
            self.manager.activate('cctv13')
            self.request('/all.m3u');self.assertEqual(demand.call_count,1)
            self.assertEqual(self.manager.current,'cctv13')

    def test_switch_stops_previous_worker_and_status_has_current_channel(self):
        first=self.manager.activate('cctv2')
        second=self.manager.activate('cctv13')
        self.assertTrue(first.stop.is_set())
        self.assertFalse(second.stop.is_set())
        status,value=self.request('/status')
        value=json.loads(value)
        self.assertEqual(value['current_channel'],'cctv13')
        self.assertEqual(value['native_context_limit'],2)
        self.assertEqual(value['channel_count'],14)
        self.manager.close()
        with self.assertRaises(self.m.NativeError):self.manager.activate('cctv1')


    def test_epg_http_uses_same_ids_and_head_has_no_refresh(self):
        self.assertEqual(self.request('/epg.xml',method='HEAD'),(200,b''))
        self.manager.epg.refresh.assert_not_called()
        self.manager.epg.document = mock.Mock(return_value=b'<?xml version="1.0"?><tv/>')
        self.assertEqual(self.request('/epg.xml'),(200,b'<?xml version="1.0"?><tv/>'))
        self.assertIsNone(self.manager.current)
        self.manager.epg.document.return_value=None
        self.assertEqual(self.request('/epg.xml')[0],503)
        status,body=self.request('/all.m3u')
        self.assertIn(b'x-tvg-url="http://127.0.0.1:',body)
        self.assertIn(b'/epg.xml"',body)


class TestNativeContextBound(unittest.TestCase):
    def test_rapid_demands_cannot_run_more_than_two_native_workers(self):
        m=load_service();slots=threading.BoundedSemaphore(2)
        channels=[m.ManagedChannel(SimpleNamespace(channel_id=cid),slots)
                  for cid in ('cctv1','cctv2','cctv13')]
        condition=threading.Condition();release=threading.Event()
        counts={'active':0,'peak':0,'total':0}
        def work(_self):
            with condition:
                counts['active']+=1;counts['total']+=1
                counts['peak']=max(counts['peak'],counts['active']);condition.notify_all()
            release.wait(2)
            with condition:counts['active']-=1
        with mock.patch.object(m.Channel,'run',work):
            threads=[threading.Thread(target=c.run) for c in channels]
            for thread in threads:thread.start()
            try:
                with condition:self.assertTrue(condition.wait_for(lambda:counts['active']==2,timeout=2))
            finally:
                release.set()
                for thread in threads:thread.join(3)
        self.assertEqual(counts['peak'],2)
        self.assertEqual(counts['total'],3)
