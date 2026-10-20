import threading
import time
import unittest
from unittest import mock
from test_service import service,arguments,BASE
from test_pes import stream


class TestParallelPrepare(unittest.TestCase):
    def setUp(self):
        self.raw,_=stream()
        self.channel=service.Channel(arguments(parallel_prepare=True))
        self.channel.started_at=self.channel.last_request=time.monotonic()
        self.engine=mock.Mock(transform=mock.Mock(side_effect=lambda values:values))
        self.entries=self.window(0)
        self.published=[]
        original=self.channel.publish
        def publish(body,entry,discontinuity):
            original(body,entry,discontinuity)
            self.published.append(entry['seq'])
            if len(self.published)==2:self.channel.stop.set()
        self.publish=publish

    def window(self,start):
        return [dict(seq=i,duration=4,url=BASE+str(i),discontinuity=False) for i in range(start,start+3)]

    def test_segments_download_while_sdk_initializes_and_are_not_downloaded_twice(self):
        first_download=threading.Event();sdk_ready=threading.Event()
        owner=threading.get_ident()
        def initialize(_args):
            self.assertEqual(threading.get_ident(),owner)
            self.assertTrue(first_download.wait(2),'first download did not overlap SDK startup')
            sdk_ready.set()
            return self.engine
        def download(_url):
            first_download.set()
            if not sdk_ready.wait(2):raise AssertionError('SDK startup blocked by prefetch')
            return self.raw,BASE
        with mock.patch.object(service,'Engine',side_effect=initialize), \
             mock.patch.object(service,'source_url',return_value=BASE) as source, \
             mock.patch.object(service,'media_playlist',return_value=(self.entries,BASE)) as playlist, \
             mock.patch.object(service,'get',side_effect=download) as get, \
             mock.patch.object(self.channel,'publish',side_effect=self.publish),mock.patch('builtins.print'):
            self.channel.run()
        self.assertEqual(self.channel.error,'')
        self.assertEqual(self.published,[0,1])
        source.assert_called_once();playlist.assert_called_once()
        self.assertEqual(get.call_count,3)
        self.engine.close.assert_called_once()

    def test_failed_initial_future_is_consumed_once_and_normal_network_retry_recovers(self):
        with mock.patch.object(service,'Engine',return_value=self.engine), \
             mock.patch.object(service,'source_url',side_effect=[service.URLError('private-source'),BASE]) as source, \
             mock.patch.object(service,'media_playlist',return_value=(self.entries,BASE)), \
             mock.patch.object(service,'get',return_value=(self.raw,BASE)), \
             mock.patch.object(self.channel,'publish',side_effect=self.publish), \
             mock.patch.object(self.channel.stop,'wait',return_value=False),mock.patch('builtins.print') as logged:
            self.channel.run()
        self.assertEqual(source.call_count,2)
        self.assertEqual(self.channel.transport_retries,1)
        self.assertEqual(self.channel.error,'')
        self.assertEqual(self.published,[0,1])
        self.assertNotIn('private-source',str(logged.call_args_list))

    def test_api_denial_does_not_download_media(self):
        with mock.patch.object(service,'Engine',return_value=self.engine), \
             mock.patch.object(service,'source_url',side_effect=service.NativeError('official-playback-not-permitted')), \
             mock.patch.object(service,'media_playlist') as playlist, \
             mock.patch.object(service,'get') as get,mock.patch('builtins.print'):
            self.channel.run()
        self.assertEqual(self.channel.error,'official-playback-not-permitted')
        playlist.assert_not_called();get.assert_not_called()
        self.engine.close.assert_called_once()

    def test_stale_prepared_playlist_is_refreshed_before_publishing(self):
        original=self.channel._prepare_initial
        def stale(pool,cancel):
            values=original(pool,cancel)
            return (*values[:-1],values[-1]-9)
        with mock.patch.object(service,'Engine',return_value=self.engine), \
             mock.patch.object(service,'source_url',return_value=BASE), \
             mock.patch.object(service,'media_playlist',side_effect=[(self.window(0),BASE),(self.window(10),BASE)]) as playlist, \
             mock.patch.object(service,'get',return_value=(self.raw,BASE)), \
             mock.patch.object(self.channel,'_prepare_initial',side_effect=stale), \
             mock.patch.object(self.channel,'publish',side_effect=self.publish),mock.patch('builtins.print'):
            self.channel.run()
        self.assertEqual(playlist.call_count,2)
        self.assertEqual(self.published,[10,11])
        self.assertEqual(self.channel.error,'')

    def test_switch_during_initialization_cancels_further_preparation(self):
        release=threading.Event()
        def source():
            if not release.wait(2):raise AssertionError('source never released')
            return BASE
        def initialize(_args):
            self.channel.stop.set();release.set()
            return self.engine
        with mock.patch.object(service,'Engine',side_effect=initialize), \
             mock.patch.object(service,'source_url',side_effect=source), \
             mock.patch.object(service,'media_playlist') as playlist, \
             mock.patch.object(service,'get') as get,mock.patch('builtins.print'):
            self.channel.run()
        playlist.assert_not_called();get.assert_not_called()
        self.engine.close.assert_called_once()
