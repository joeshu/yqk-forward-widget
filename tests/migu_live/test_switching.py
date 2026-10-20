from concurrent.futures import ThreadPoolExecutor
import threading
import unittest
from unittest.mock import Mock,patch
from migu import android as a,core as m


class SwitchingTests(unittest.TestCase):
    def test_transient_error_recovers_after_three_seconds_but_rights_denial_stays_cached(self):
        now=[0.0];resolver=Mock(side_effect=[m.FetchError('NETWORK_ERROR'),'url',a.MiguApiError('MIGU_COPYRIGHT_SHIELD')])
        store=a.AndroidStore(a.AndroidSettings(),resolver,clock=lambda:now[0]);self.addCleanup(store.close)
        for _ in range(2):
            with self.assertRaisesRegex(m.FetchError,'NETWORK_ERROR'):store.resolve('p608807420')
        self.assertEqual(resolver.call_count,1)
        now[0]=3.1;self.assertEqual(store.resolve('p608807420'),'url')
        with self.assertRaisesRegex(m.FetchError,'COPYRIGHT_SHIELD'):store.resolve('p631780532')
        now[0]=7
        with self.assertRaisesRegex(m.FetchError,'COPYRIGHT_SHIELD'):store.resolve('p631780532')
        self.assertEqual(resolver.call_count,3)

    def test_busy_workers_queue_new_requests_and_start_latest_pending_first(self):
        ids=[row[0] for row in a.BUILTIN_CHANNELS[:10]]
        gates={pid:threading.Event() for pid in ids[:8]};condition=threading.Condition();started=[];queued=[]
        def resolver(pid):
            with condition:started.append(pid);condition.notify_all()
            if pid in gates:gates[pid].wait(5)
            return 'url-'+pid
        store=a.AndroidStore(a.AndroidSettings(),resolver);pool=ThreadPoolExecutor(max_workers=10)
        submit=store.pool.submit
        def tracked(*args,**kwargs):
            result=submit(*args,**kwargs)
            with condition:queued.append(args[1]);condition.notify_all()
            return result
        try:
            with patch.object(store.pool,'submit',side_effect=tracked):
                active=[pool.submit(store.resolve,'p'+pid) for pid in ids[:8]]
                with condition:self.assertTrue(condition.wait_for(lambda:len(started)==8,3))
                older=pool.submit(store.resolve,'p'+ids[8])
                with condition:self.assertTrue(condition.wait_for(lambda:ids[8] in queued,3))
                latest=pool.submit(store.resolve,'p'+ids[9])
                with condition:self.assertTrue(condition.wait_for(lambda:ids[9] in queued,3))
                self.assertEqual(store.status()['active_resolves'],8)
                self.assertEqual(store.status()['pending_resolves'],2)
                gates[ids[0]].set()
                self.assertEqual(latest.result(3),'url-'+ids[9])
                self.assertEqual(older.result(3),'url-'+ids[8])
                self.assertEqual(started[8:10],[ids[9],ids[8]])
        finally:
            for gate in gates.values():gate.set()
            pool.shutdown(wait=True);store.close()

    def test_queued_request_with_no_remaining_waiter_is_cancelled_without_upstream_call(self):
        ids=[row[0] for row in a.BUILTIN_CHANNELS[:9]]
        gate=threading.Event();condition=threading.Condition();started=[]
        def resolver(pid):
            with condition:started.append(pid);condition.notify_all()
            gate.wait(5);return 'url'
        store=a.AndroidStore(a.AndroidSettings(),resolver);pool=ThreadPoolExecutor(max_workers=8)
        try:
            active=[pool.submit(store.resolve,'p'+pid) for pid in ids[:8]]
            with condition:self.assertTrue(condition.wait_for(lambda:len(started)==8,3))
            with self.assertRaisesRegex(m.FetchError,'MIGU_API_LOADING'):store.resolve('p'+ids[8],wait=.02)
            self.assertNotIn('p'+ids[8],store.flights)
            self.assertNotIn('p'+ids[8],store.entries)
            gate.set()
            for future in active:self.assertEqual(future.result(3),'url')
            self.assertNotIn(ids[8],started)
            self.assertEqual(store.fetches,8)
        finally:
            gate.set();pool.shutdown(wait=True);store.close()

    def test_one_waiter_timing_out_does_not_cancel_shared_resolution(self):
        gate,entered,long_waiter=threading.Event(),threading.Event(),threading.Event()
        resolver=Mock(side_effect=lambda pid:(entered.set(),gate.wait(3),'url')[-1])
        store=a.AndroidStore(a.AndroidSettings(),resolver);pool=ThreadPoolExecutor(max_workers=2)
        try:
            short=pool.submit(store.resolve,'p608807420',.15)
            self.assertTrue(entered.wait(2))
            with store.lock:flight=store.flights['p608807420']
            result=flight.result
            def tracked(*args,**kwargs):long_waiter.set();return result(*args,**kwargs)
            with patch.object(flight,'result',side_effect=tracked):
                long=pool.submit(store.resolve,'p608807420',2)
                self.assertTrue(long_waiter.wait(2))
                with self.assertRaisesRegex(m.FetchError,'MIGU_API_LOADING'):short.result(2)
                self.assertFalse(flight.cancelled())
                gate.set();self.assertEqual(long.result(2),'url')
            self.assertEqual(resolver.call_count,1)
        finally:
            gate.set();pool.shutdown(wait=True);store.close()
