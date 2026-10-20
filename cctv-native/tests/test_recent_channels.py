"""Warm return behavior, freshness and owner-thread resource accounting."""
import threading
import time
import unittest
from concurrent.futures import Future
from types import SimpleNamespace
from unittest import mock
from test_jscore_service import load_service
from test_pes import stream


class TestRecentChannels(unittest.TestCase):
    def setUp(self):
        self.m=load_service()
        self.args=SimpleNamespace(warmup=False,buffer_mb=16,idle_timeout=120,
                                  parallel_prepare=True,recent_channel_seconds=15)
        self.manager=self.m.ChannelManager(self.args)
        self.raw,_=stream()
        self.workers=[]

    def tearDown(self):
        self.manager.close()
        for c in self.workers:
            if c.thread:c.thread.join(3)

    def ready(self,cid):
        c=self.manager.activate(cid)
        c.thread=mock.Mock(is_alive=mock.Mock(return_value=True))
        c.generation='a'*32
        c.started_at=c.last_request=time.monotonic()
        for _ in range(4):c.publish(b'valid-'+cid.encode(),{'duration':4},False)
        return c

    def test_return_reuses_latest_two_outputs_and_generation(self):
        a=self.ready('cctv2');generation=a.generation
        b=self.manager.activate('cctv4')
        self.assertTrue(a.parked_at)
        self.assertFalse(a.stop.is_set())
        self.assertEqual(len(a.ring),2)
        self.assertIs(self.manager.activate('cctv2'),a)
        self.assertTrue(b.stop.is_set()) # unfinished channels aren't cached
        self.assertEqual(a.generation,generation)
        self.assertIsNotNone(a.playlist())
        self.assertEqual(a.cache_buffer_hits,1)
        with self.assertRaises(self.m.ResumePreparation):a.checkpoint()
        self.assertTrue(a.checkpoint())

    def test_stale_outputs_are_not_served_but_vm_can_be_reused(self):
        a=self.ready('cctv2');self.manager.activate('cctv4')
        generation=a.generation;a.last_published_at=time.monotonic()-9
        self.assertIs(self.manager.activate('cctv2'),a)
        self.assertIsNone(a.playlist())
        self.assertNotEqual(a.generation,generation)
        self.assertEqual(a.cache_hits,1);self.assertEqual(a.cache_buffer_hits,0)
        with self.assertRaises(self.m.ResumePreparation) as resumed:a.checkpoint()
        self.assertTrue(resumed.exception.reset_sequence)

    def test_expired_channel_is_replaced_and_third_selection_evicts_oldest(self):
        a=self.ready('cctv2');b=self.ready('cctv4')
        self.assertTrue(a.parked_at)
        self.manager.activate('cctv7')
        self.assertTrue(a.stop.is_set());self.assertTrue(b.parked_at)
        b.parked_at=time.monotonic()-16
        self.assertIsNot(self.manager.activate('cctv4'),b)
        self.assertTrue(b.stop.is_set())

    def test_cache_can_be_disabled(self):
        self.args.recent_channel_seconds=0
        a=self.ready('cctv2');self.manager.activate('cctv4')
        self.assertTrue(a.stop.is_set());self.assertFalse(a.parked_at)

    def test_owner_waits_while_parked_and_expires_without_a_new_request(self):
        a=self.ready('cctv2');a.cache_ttl=.04
        self.manager.activate('cctv4')
        done=threading.Event();result=[]
        worker=threading.Thread(target=lambda:(result.append(a.checkpoint()),done.set()))
        worker.start()
        try:self.assertTrue(done.wait(1))
        finally:worker.join(1)
        self.assertEqual(result,[False]);self.assertTrue(a.stop.is_set())

    def test_retire_interrupts_pending_download_and_releases_vm_before_io_join(self):
        channel=self.manager.activate('cctv2');self.workers.append(channel)
        blocked=threading.Event();download_started=threading.Event();closed=threading.Event()
        engine=mock.Mock(transform=mock.Mock(side_effect=lambda v:v))
        engine.close.side_effect=closed.set
        entries=[dict(seq=i,duration=4,url='https://media.cntv.cn/'+str(i),discontinuity=False) for i in range(3)]
        def get(_url):
            download_started.set();blocked.wait(3);return self.raw,'https://media.cntv.cn/a'
        with mock.patch.object(self.m,'Engine',return_value=engine), \
             mock.patch.object(self.m,'source_url',return_value='https://media.cntv.cn/a'), \
             mock.patch.object(self.m,'media_playlist',return_value=(entries,'https://media.cntv.cn/a')), \
             mock.patch.object(self.m,'get',side_effect=get),mock.patch('builtins.print'):
            channel.demand()
            try:
                self.assertTrue(download_started.wait(2))
                channel.retire()
                self.assertTrue(closed.wait(1),'VM waited for the blocked HTTP read')
                self.assertTrue(channel.thread.is_alive(),'test did not retain a running HTTP read')
                self.assertFalse(channel.slot_held)
                self.assertTrue(self.manager.slots.acquire(False))
                self.assertTrue(self.manager.slots.acquire(False))
                self.manager.slots.release();self.manager.slots.release()
            finally:
                blocked.set();channel.thread.join(3)

    def test_real_worker_returns_to_same_engine_and_resumes_at_current_window(self):
        engines={};closed=[]
        def engine(args):
            owner=threading.get_ident()
            value=mock.Mock(transform=mock.Mock(side_effect=lambda v:v))
            def close():
                self.assertEqual(threading.get_ident(),owner);closed.append(args.channel_id)
            value.close.side_effect=close
            engines.setdefault(args.channel_id,[]).append(value)
            return value
        windows={}
        def playlist(url):
            start=windows.get(url,0);windows[url]=start+2
            return ([dict(seq=i,duration=4,url=url+'/'+str(i),discontinuity=False)
                     for i in range(start,start+3)],url)
        with mock.patch.object(self.m,'Engine',side_effect=engine), \
             mock.patch.object(self.m,'source_url',side_effect=lambda cid='cctv2':'https://media.cntv.cn/'+cid), \
             mock.patch.object(self.m,'media_playlist',side_effect=playlist), \
             mock.patch.object(self.m,'get',return_value=(self.raw,'https://media.cntv.cn/a')),mock.patch('builtins.print'):
            a=self.manager.activate('cctv2');self.workers.append(a);a.demand()
            with a.condition:self.assertTrue(a.condition.wait_for(lambda:a.playlist() is not None,2))
            b=self.manager.activate('cctv4');self.workers.append(b);b.demand()
            with b.condition:self.assertTrue(b.condition.wait_for(lambda:b.playlist() is not None,2))
            self.assertIs(self.manager.activate('cctv2'),a)
            self.assertIsNotNone(a.playlist())
            self.assertEqual(len(engines['cctv2']),1)
            self.assertEqual(a.cache_buffer_hits,1)
            before=a.processed
            with a.condition:self.assertTrue(a.condition.wait_for(lambda:a.processed>before,2))
            self.assertEqual(len(engines['cctv2']),1)
            self.assertEqual(a.error,'')
            self.manager.close()
            for c in self.workers:c.thread.join(2)
        self.assertCountEqual(closed,['cctv2','cctv4'])

    def test_future_socket_timeout_is_preserved(self):
        a=self.manager.activate('cctv2');task=Future();task.set_exception(TimeoutError('network'))
        with self.assertRaises(TimeoutError):a._await_future(task)
