import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest import mock
from test_jscore_service import load_service


class TestInputCancellation(unittest.TestCase):
    def setUp(self):
        self.m=load_service()
        self.args=SimpleNamespace(buffer_mb=32,idle_timeout=120,startup_segments=1,
                                  channel_cache_size=6,recent_channel_seconds=60)

    def test_retire_cancels_queued_reads_before_network_and_cleans_tracking(self):
        manager=self.m.ChannelManager(self.args);channel=manager.activate('cctv2')
        entered=threading.Event();release=threading.Event();network=mock.Mock()
        with ThreadPoolExecutor(max_workers=1) as pool:
            def busy():entered.set();release.wait(2)
            blocker=pool.submit(busy);self.assertTrue(entered.wait(1))
            tasks=[channel._submit_input(pool,network) for _ in range(12)]
            self.assertEqual(len(channel.input_tasks),12)
            channel.retire()
            self.assertTrue(all(task.cancelled() for task in tasks))
            self.assertEqual(len(channel.input_tasks),0)
            release.set();blocker.result(1)
        network.assert_not_called();manager.close()

    def test_running_read_is_not_closed_cross_thread_but_queued_read_is_cancelled(self):
        manager=self.m.ChannelManager(self.args);channel=manager.activate('cctv2')
        entered=threading.Event();release=threading.Event();queued=mock.Mock()
        def read():entered.set();release.wait(2);return b'completed'
        with ThreadPoolExecutor(max_workers=1) as pool:
            running=channel._submit_input(pool,read);self.assertTrue(entered.wait(1))
            waiting=channel._submit_input(pool,queued);channel.retire()
            self.assertFalse(running.cancelled());self.assertTrue(waiting.cancelled())
            release.set();self.assertEqual(running.result(1),b'completed')
        self.assertEqual(len(channel.input_tasks),0);queued.assert_not_called();manager.close()

    def test_park_cancels_prefetch_and_owner_resume_remains_usable(self):
        manager=self.m.ChannelManager(self.args);channel=manager.activate('cctv2')
        channel.thread=mock.Mock(is_alive=mock.Mock(return_value=True))
        channel.started_at=self.m.time.monotonic();channel.publish(b'complete',{'duration':4},False)
        entered=threading.Event();release=threading.Event();network=mock.Mock()
        with ThreadPoolExecutor(max_workers=1) as pool:
            blocker=pool.submit(lambda:(entered.set(),release.wait(2)))
            self.assertTrue(entered.wait(1));waiting=channel._submit_input(pool,network)
            channel.park();self.assertTrue(waiting.cancelled())
            self.assertTrue(channel.resume())
            with self.assertRaises(self.m.ResumePreparation):channel.checkpoint()
            release.set();blocker.result(1)
            channel._submit_input(pool,lambda:b'new-input').result(1)
        self.assertEqual(len(channel.input_tasks),0);network.assert_not_called();manager.close()

    def test_completed_and_failed_tasks_leave_no_tracking_references(self):
        channel=self.m.Channel(self.args)
        with ThreadPoolExecutor(max_workers=1) as pool:
            channel._submit_input(pool,lambda:42).result(1)
            def fail():raise TimeoutError()
            with self.assertRaises(TimeoutError):channel._submit_input(pool,fail).result(1)
        self.assertEqual(len(channel.input_tasks),0)

    def test_transient_failure_cooldown_is_short_but_official_denial_is_not(self):
        for error,should_restart in [('source-media-stalled',True),('TimeoutError',True),
                                     ('official-playback-not-permitted',False),('transport-stream-unsupported',False)]:
            channel=self.m.Channel(self.args);channel.state='error';channel.error=error
            channel.failed_at=self.m.time.monotonic()-4
            with mock.patch.object(self.m.threading,'Thread') as thread:
                channel.demand()
                self.assertEqual(thread.called,should_restart)
            if not should_restart:self.assertGreater(channel.snapshot()['retry_after_seconds'],20)


    def test_transient_retry_still_has_a_cooldown_before_three_seconds(self):
        channel=self.m.Channel(self.args);channel.state='error';channel.error='source-media-stalled'
        channel.failed_at=self.m.time.monotonic()-1
        with mock.patch.object(self.m.threading,'Thread') as thread:
            channel.demand();thread.assert_not_called()
        self.assertGreater(channel.snapshot()['retry_after_seconds'],1)
