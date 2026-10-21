"""Boundary-only HTTP reads cannot become playable media or block first-ready."""
from concurrent.futures import ThreadPoolExecutor
import threading
import unittest
from unittest import mock
from test_service import service,arguments,BASE
from test_pes import stream


class TestBoundaryDownload(unittest.TestCase):
    def setUp(self):
        self.channel=service.Channel(arguments(parallel_prepare=True,prefix_lookahead=True))
        self.raw,_=stream(second_pes=True)
        self.prefix,self.analysis=service.inspect_boundary_prefix(self.raw)
        self.ranged=self.raw[:len(self.prefix)+188]
        self.info={'status':206,'content_range':f'bytes 0-{len(self.ranged)-1}/{len(self.raw)}'}

    def test_valid_partial_response_is_strict_boundary_only(self):
        with mock.patch.object(service,'get',return_value=(self.ranged,BASE,self.info)) as get:
            value=self.channel._download_boundary(BASE)
        self.assertIsInstance(value,service.BoundaryPrefix)
        self.assertIs(value.analysis._source,value.data)
        self.assertFalse(value.analysis.nals[-1].complete)
        self.assertTrue(service.boundary_proven_by(value.data,_prepared=value.analysis))
        self.assertEqual(self.channel.boundary_prefix_hits,1)
        self.assertEqual(get.call_args.kwargs['headers']['Range'],'bytes=0-131071')

    def test_ignored_range_reuses_whole_body_without_another_download(self):
        info={'status':200,'content_range':''}
        with mock.patch.object(service,'get',return_value=(self.raw,BASE,info)) as get:
            value=self.channel._download_boundary(BASE)
        self.assertEqual(value[0],self.raw);self.assertIs(value[2]._source,self.raw)
        self.assertEqual(get.call_count,1)
        self.assertEqual(self.channel.boundary_prefix_fallbacks,1)

    def test_bad_range_or_insufficient_boundary_falls_back_to_full_media(self):
        cases=[(self.ranged,{'status':206,'content_range':'bytes 1-20/1000'}),
               (self.ranged,{'status':206,'content_range':f'bytes 0-20/{len(self.raw)}'}),
               (self.ranged,{'status':206,'content_range':f'bytes 0-{len(self.ranged)-1}/{9*1024*1024}'}),
               (self.raw[:188],{'status':206,'content_range':f'bytes 0-187/{len(self.raw)}'})]
        for body,info in cases:
            with self.subTest(info=info),mock.patch.object(service,'get',side_effect=[(body,BASE,info),(self.raw,BASE)]) as get:
                value=self.channel._download_boundary(BASE)
            self.assertEqual(value[0],self.raw);self.assertEqual(get.call_count,2)
            self.assertEqual(value[2].elementary,service.inspect_ts(self.raw).elementary)

    def test_range_unsupported_falls_back_but_auth_failure_propagates(self):
        with mock.patch.object(service,'get',side_effect=[service.HTTPError(BASE,416,'range',{},None),(self.raw,BASE)]) as get:
            self.assertEqual(self.channel._download_boundary(BASE)[0],self.raw)
        self.assertEqual(get.call_count,2)
        with mock.patch.object(service,'get',side_effect=service.HTTPError(BASE,403,'denied',{},None)) as get:
            with self.assertRaises(service.HTTPError):self.channel._download_boundary(BASE)
        self.assertEqual(get.call_count,1)

    def test_full_upgrade_must_match_total_and_all_retained_range_bytes(self):
        boundary=service.BoundaryPrefix(self.prefix,self.analysis,self.ranged,len(self.raw))
        with mock.patch.object(self.channel,'_download_segment',return_value=(self.raw,BASE,None)):
            self.assertEqual(self.channel._upgrade_boundary(BASE,boundary)[0],self.raw)
        changed=bytearray(self.raw);changed[len(self.ranged)-1]^=1
        for raw in (bytes(changed),self.raw+b'x'):
            with mock.patch.object(self.channel,'_download_segment',return_value=(raw,BASE,None)):
                with self.assertRaises(service.SourceEntityChanged):self.channel._upgrade_boundary(BASE,boundary)

    def test_current_input_is_upgraded_only_once(self):
        boundary=service.BoundaryPrefix(self.prefix,self.analysis,self.ranged,len(self.raw))
        from concurrent.futures import Future
        prefix_task=Future();prefix_task.set_result(boundary)
        full_task=Future();full_task.set_result((self.raw,BASE,None))
        entries=[{'seq':0,'url':BASE},{'seq':1,'url':BASE+'1'}]
        cached={0:prefix_task,1:full_task};upgrades={0:full_task}
        with ThreadPoolExecutor(max_workers=1) as pool,mock.patch.object(self.channel,'_upgrade_boundary') as upgrade:
            self.channel._submit_inputs(pool,entries,cached,upgrades=upgrades)
        self.assertIs(cached[0],full_task);upgrade.assert_not_called()

    def test_playlist_can_become_ready_while_background_third_full_download_is_blocked(self):
        entries=[dict(seq=i,duration=4,url=BASE+str(i),discontinuity=False) for i in range(3)]
        background=threading.Event();release=threading.Event();ready=threading.Event();outputs=[]
        calls=[0]
        def transform(values):
            calls[0]+=1
            if calls[0]==2:self.assertTrue(background.wait(1))
            return values
        engine=mock.Mock(transform=mock.Mock(side_effect=transform))
        def get(url,**kwargs):
            if kwargs.get('response_info'):return self.ranged,BASE,self.info
            if url==entries[2]['url']:
                background.set()
                if not release.wait(3):raise AssertionError('background read never released')
            return self.raw,BASE
        original=self.channel.publish
        def publish(body,entry,discontinuity):
            original(body,entry,discontinuity);outputs.append(body)
            if len(outputs)==2:
                self.assertIsNotNone(self.channel.playlist());ready.set();self.channel.stop.set()
        with mock.patch.object(service,'Engine',return_value=engine), \
             mock.patch.object(service,'source_url',return_value=BASE), \
             mock.patch.object(service,'media_playlist',return_value=(entries,BASE)), \
             mock.patch.object(service,'get',side_effect=get), \
             mock.patch.object(self.channel,'publish',side_effect=publish),mock.patch('builtins.print'):
            self.channel.demand()
            try:
                self.assertTrue(ready.wait(2),'first-ready waited for the full third segment')
                self.assertTrue(background.wait(1))
                self.assertEqual(outputs,[self.raw,self.raw])
                self.assertEqual(self.channel.boundary_prefix_hits,1)
                self.assertEqual(engine.transform.call_count,2)
            finally:
                release.set();self.channel.stop.set();self.channel.thread.join(3)
        self.assertFalse(self.channel.thread.is_alive());self.assertEqual(self.channel.error,'')

    def test_changed_entity_refreshes_official_source_and_marks_discontinuity(self):
        channel=service.Channel(arguments(parallel_prepare=True,prefix_lookahead=True))
        first='https://media.cntv.cn/a';second='https://media.cntv.cn/b'
        calls=[0];published=[];original=channel.publish
        def playlist(url):
            calls[0]+=1
            start=10 if url==second else 0 if calls[0]==1 else 2
            return ([dict(seq=i,duration=4,url=url+'/'+str(i),discontinuity=False)
                     for i in range(start,start+3)],url)
        changed=bytearray(self.raw);changed[0]^=1
        def get(url,**kwargs):
            if kwargs.get('response_info'):return self.ranged,first,self.info
            return (bytes(changed) if url==first+'/2' else self.raw),url
        def publish(body,entry,discontinuity):
            original(body,entry,discontinuity);published.append((entry['seq'],discontinuity))
            if len(published)==4:channel.stop.set()
        engine=mock.Mock(transform=mock.Mock(side_effect=lambda values:values))
        channel.started_at=channel.last_request=service.time.monotonic()
        with mock.patch.object(service,'Engine',return_value=engine), \
             mock.patch.object(service,'source_url',side_effect=[first,second]) as source, \
             mock.patch.object(service,'media_playlist',side_effect=playlist), \
             mock.patch.object(service,'get',side_effect=get), \
             mock.patch.object(channel,'publish',side_effect=publish), \
             mock.patch.object(channel.stop,'wait',return_value=False),mock.patch('builtins.print'):
            channel.run()
        self.assertEqual(channel.error,'')
        self.assertEqual(source.call_count,2);self.assertEqual(channel.source_gaps,1)
        self.assertEqual(published,[(0,False),(1,False),(10,True),(11,False)])

    def test_single_segment_ready_does_not_wait_for_second_segment_boundary(self):
        channel=service.Channel(arguments(parallel_prepare=True,prefix_lookahead=True,startup_segments=1))
        entries=[dict(seq=i,duration=4,url=BASE+str(i),discontinuity=False) for i in range(3)]
        blocked=threading.Event();release=threading.Event();ready=threading.Event()
        def get(url,**kwargs):
            if kwargs.get('response_info'):
                blocked.set();release.wait(3);return self.ranged,BASE,self.info
            return self.raw,BASE
        original=channel.publish
        def publish(body,entry,discontinuity):
            original(body,entry,discontinuity)
            self.assertEqual(body,self.raw)
            self.assertEqual(channel.playlist().count('#EXTINF:'),1)
            ready.set();channel.stop.set()
        with mock.patch.object(service,'Engine',return_value=mock.Mock(transform=lambda values:values)), \
             mock.patch.object(service,'source_url',return_value=BASE), \
             mock.patch.object(service,'media_playlist',return_value=(entries,BASE)), \
             mock.patch.object(service,'get',side_effect=get), \
             mock.patch.object(channel,'publish',side_effect=publish),mock.patch('builtins.print'):
            channel.demand()
            try:
                self.assertTrue(blocked.wait(1))
                self.assertTrue(ready.wait(1))
                self.assertEqual(channel.counter,1)
            finally:
                release.set();channel.stop.set();channel.thread.join(3)
        self.assertFalse(channel.thread.is_alive());self.assertEqual(channel.error,'')
