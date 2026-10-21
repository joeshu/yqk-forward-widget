import threading
import time
import unittest
from concurrent.futures import Future
from types import SimpleNamespace
from unittest import mock
from test_jscore_service import load_service
from test_pes import stream


class TestRecentPrefetch(unittest.TestCase):
    def setUp(self):
        self.m=load_service()
        self.args=SimpleNamespace(warmup=False,buffer_mb=16,idle_timeout=120,parallel_prepare=True,
                                  recent_channel_seconds=60,channel_cache_size=6,startup_segments=1,
                                  recent_prefetch=0,cache_memory_mb=32)
        self.manager=self.m.ChannelManager(self.args)
        self.raw,_=stream()
        self.base='https://media.cntv.cn/live'
        self.entries=[dict(seq=i,duration=4,url=self.base+'/'+str(i),discontinuity=False) for i in range(3)]
        self.workers=[]

    def tearDown(self):
        self.manager.close()
        for c in self.workers:
            if c.thread:c.thread.join(3)

    def ready(self,cid):
        c=self.manager.activate(cid);c.thread=mock.Mock(is_alive=lambda:True)
        c.started_at=time.monotonic()
        for _ in range(2):c.publish(b'valid',{'duration':4},False)
        return c

    def setup_targets(self):
        a=self.ready('cctv2');b=self.ready('cctv4');self.manager.prefetch.limit=1
        return a,b

    def test_only_most_recent_watched_channel_and_foreground_must_have_buffer(self):
        self.assertIsNone(self.manager.prefetch.thread)
        a,b=self.setup_targets();c=self.ready('cctv7')
        self.assertEqual(self.manager.prefetch_targets(),[b])
        self.manager.prefetch.limit=2;self.assertEqual(self.manager.prefetch_targets(),[b,a])
        with c.condition:c.ring.popitem()
        self.assertEqual(self.manager.prefetch_targets(),[])

    def test_prefetch_does_not_process_video_and_reuses_identical_segment_urls(self):
        a,b=self.setup_targets()
        with mock.patch.object(self.m,'source_url',return_value=self.base) as source, \
             mock.patch.object(self.m,'media_playlist',return_value=(self.entries,self.base+'/index.m3u8')) as playlist, \
             mock.patch.object(self.m,'get',return_value=(self.raw,self.base)) as get, \
             mock.patch.object(self.m,'Engine',side_effect=AssertionError('background VM')), \
             mock.patch.object(self.m,'inspect_ts',side_effect=AssertionError('background TS processing')):
            self.manager.prefetch.cycle()
            self.assertEqual(get.call_count,2);self.assertEqual(source.call_count,1)
            self.assertEqual(a.recent_preparation_bytes,2*len(self.raw))
            self.manager.prefetch.attempts.clear();self.manager.prefetch.cycle()
            self.assertEqual(get.call_count,2);self.assertEqual(source.call_count,1)
            self.assertEqual(self.manager.prefetch.reused_segments,2)
            self.assertEqual([call.args[0] for call in playlist.call_args_list],
                             [self.base,self.base+'/index.m3u8'])
        a.last_published_at=time.monotonic()-10
        self.assertIs(self.manager.activate('cctv2'),a)
        prepared=a.take_recent_preparation()
        self.assertIsNotNone(prepared);self.assertEqual(a.prefetch_hits,1)
        self.assertEqual(prepared[2][0].result()[0],self.raw)
        self.assertEqual(a.recent_preparation_bytes,0)

    def test_denial_never_fetches_media_or_changes_foreground_state(self):
        a,b=self.setup_targets()
        with mock.patch.object(self.m,'source_url',side_effect=self.m.NativeError('official-playback-not-permitted')), \
             mock.patch.object(self.m,'get') as get:
            self.manager.prefetch.cycle();get.assert_not_called()
        self.assertIsNone(a.recent_preparation)
        self.assertEqual(b.error,'');self.assertEqual(b.state,'ready')
        self.assertEqual(self.manager.prefetch.snapshot()['last_error'],'official-playback-not-permitted')

    def test_inflight_prefetch_is_discarded_if_channel_is_selected(self):
        a,b=self.setup_targets();entered=threading.Event();release=threading.Event()
        def get(*args,**kwargs):entered.set();release.wait(2);return self.raw,self.base
        with mock.patch.object(self.m,'source_url',return_value=self.base), \
             mock.patch.object(self.m,'media_playlist',return_value=(self.entries,self.base)), \
             mock.patch.object(self.m,'get',side_effect=get) as fetch:
            worker=threading.Thread(target=self.manager.prefetch.cycle);worker.start()
            try:
                self.assertTrue(entered.wait(1));self.manager.activate('cctv2')
            finally:release.set();worker.join(2)
            self.assertEqual(fetch.call_count,1)
        self.assertIsNone(a.recent_preparation);self.assertEqual(a.recent_preparation_bytes,0)

    def test_stale_preparation_rejected_and_fresh_video_hit_discards_unused_input(self):
        a,b=self.setup_targets()
        a.recent_preparation=([],self.base,{},time.monotonic(),time.monotonic()-7)
        a.recent_preparation_bytes=5
        self.assertIsNone(a.take_recent_preparation())
        a.recent_preparation=([],self.base,{},time.monotonic(),time.monotonic())
        a.recent_preparation_bytes=5
        self.manager.activate('cctv2')
        self.assertEqual(a.cache_buffer_hits,1);self.assertIsNone(a.recent_preparation)

    def test_media_budget_protects_current_and_drops_older_parked_bytes(self):
        a,b=self.setup_targets();self.manager.cache_bytes=b.size
        before=b.size;self.manager.enforce_budget()
        self.assertEqual(b.size,before);self.assertEqual(a.size,0)
        self.assertFalse(a.stop.is_set());self.assertEqual(self.manager.budget_evictions,1)
        self.assertLessEqual(self.manager.snapshot()['accounted_cache_bytes'],self.manager.cache_bytes)

    def test_expired_parked_media_and_prefetched_data_are_released(self):
        a,b=self.setup_targets();a.last_published_at=time.monotonic()-9
        a.recent_preparation=([],self.base,{},time.monotonic(),time.monotonic()-7)
        a.recent_preparation_bytes=5;self.manager.enforce_budget()
        self.assertEqual(a.size,0);self.assertEqual(a.recent_preparation_bytes,0)
        self.assertFalse(a.stop.is_set())

    def test_invalid_http_body_does_not_enter_prefetch_cache(self):
        a,b=self.setup_targets()
        with mock.patch.object(self.m,'source_url',return_value=self.base), \
             mock.patch.object(self.m,'media_playlist',return_value=(self.entries,self.base)), \
             mock.patch.object(self.m,'get',return_value=(b'<html>error</html>',self.base)):
            self.manager.prefetch.cycle()
        self.assertIsNone(a.recent_preparation)
        self.assertEqual(self.manager.prefetch.last_error,'prefetch-invalid-media')
        self.assertEqual(b.error,'')

    def test_owner_consumes_prefetch_without_redownloading_its_two_inputs(self):
        self.args.parallel_prepare=False
        windows={};downloads=[]
        def playlist(url,**kwargs):
            start=windows.get(url,0);windows[url]=start+2
            return ([dict(seq=i,duration=4,url=url+'/'+str(i),discontinuity=False)
                     for i in range(start,start+3)],url)
        def get(url,**kwargs):
            downloads.append(url);return self.raw,url
        engines={}
        def engine(args):
            engines[args.channel_id]=engines.get(args.channel_id,0)+1
            return mock.Mock(transform=lambda units:units)
        with mock.patch.object(self.m,'Engine',side_effect=engine), \
             mock.patch.object(self.m,'source_url',side_effect=lambda cid='cctv2',**kwargs:self.base+'/'+cid), \
             mock.patch.object(self.m,'media_playlist',side_effect=playlist), \
             mock.patch.object(self.m,'get',side_effect=get),mock.patch('builtins.print'):
            a=self.manager.activate('cctv2');self.workers.append(a);a.demand()
            with a.condition:self.assertTrue(a.condition.wait_for(lambda:a.playlist() is not None,2))
            b=self.manager.activate('cctv4');self.workers.append(b);b.demand()
            with b.condition:self.assertTrue(b.condition.wait_for(lambda:b.playlist() is not None,2))
            entries=[dict(seq=i,duration=4,url=self.base+'/prefetched/'+str(i),discontinuity=False) for i in (10,11)]
            tasks={}
            for entry in entries:
                task=Future();task.set_result((self.raw,entry['url'],None));tasks[entry['seq']]=task
            with a.condition:
                a.last_published_at=time.monotonic()-9
                a.recent_preparation=(entries,self.base+'/cctv2',tasks,time.monotonic(),time.monotonic())
                a.recent_preparation_bytes=2*len(self.raw)
            self.manager.activate('cctv2')
            with a.condition:self.assertTrue(a.condition.wait_for(lambda:a.playlist() is not None,2))
            self.assertEqual(a.prefetch_hits,1);self.assertEqual(engines['cctv2'],1)
            self.assertFalse(any('/prefetched/' in url for url in downloads))
            self.assertEqual(a.error,'')
            self.manager.close()
            for c in self.workers:c.thread.join(2)

    def test_two_target_limit_uses_one_serial_worker_and_no_other_channel(self):
        a,b=self.setup_targets();c=self.ready('cctv7');self.manager.prefetch.limit=2
        with mock.patch.object(self.m,'source_url',return_value=self.base) as source, \
             mock.patch.object(self.m,'media_playlist',return_value=(self.entries,self.base)), \
             mock.patch.object(self.m,'get',return_value=(self.raw,self.base)) as get:
            self.manager.prefetch.cycle()
        self.assertEqual([call.args[0] for call in source.call_args_list],['cctv4','cctv2'])
        self.assertEqual(get.call_count,4)
        self.assertIsNotNone(a.recent_preparation);self.assertIsNotNone(b.recent_preparation)
        self.assertIsNone(c.recent_preparation)

    def test_slow_download_is_not_presented_as_fresh_input(self):
        a,b=self.setup_targets();now=[time.monotonic()];calls=[0]
        def fetch(*args,**kwargs):
            calls[0]+=1
            if calls[0]==2:now[0]+=7
            return self.raw,self.base
        with mock.patch.object(self.m.time,'monotonic',side_effect=lambda:now[0]), \
             mock.patch.object(self.m,'source_url',return_value=self.base), \
             mock.patch.object(self.m,'media_playlist',return_value=(self.entries,self.base)), \
             mock.patch.object(self.m,'get',side_effect=fetch):
            self.manager.prefetch.cycle()
        self.assertEqual(calls[0],2);self.assertIsNone(a.recent_preparation)
        self.assertEqual(b.error,'')
