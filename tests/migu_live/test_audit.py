from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import runpy
import threading
import unittest
from unittest.mock import Mock
from migu import android as a, core as m
from migu.workers import BoundedExecutor


class AuditTests(unittest.TestCase):
    def test_cancelled_jobs_release_capacity_without_changing_fifo_or_lifo_order(self):
        for lifo,expected in [(False,['a','c','d']),(True,['d','c','a'])]:
            with self.subTest(lifo=lifo):
                gate,started=threading.Event(),threading.Event();order=[]
                pool=BoundedExecutor(1,max_pending=3,lifo=lifo)
                def blocked():started.set();gate.wait(3)
                def job(label):order.append(label);return label
                try:
                    active=pool.submit(blocked);self.assertTrue(started.wait(2))
                    fa=pool.submit(job,'a');fb=pool.submit(job,'b');fc=pool.submit(job,'c')
                    self.assertTrue(fb.cancel())
                    fd=pool.submit(job,'d')
                    gate.set();active.result(3)
                    for future in (fa,fc,fd):future.result(3)
                    self.assertEqual(order,expected)
                finally:gate.set();pool.shutdown(wait=True)

    def test_repeated_abandoned_switches_do_not_leave_a_full_queue(self):
        ids=[row[0] for row in a.BUILTIN_CHANNELS[:17]]
        gate=threading.Event();condition=threading.Condition();started=[]
        def resolver(pid):
            with condition:started.append(pid);condition.notify_all()
            gate.wait(3);return 'url'
        store=a.AndroidStore(a.AndroidSettings(),resolver);pool=ThreadPoolExecutor(max_workers=8)
        try:
            running=[pool.submit(store.resolve,'p'+pid) for pid in ids[:8]]
            with condition:self.assertTrue(condition.wait_for(lambda:len(started)==8,2))
            for pid in ids[8:]:
                with self.assertRaisesRegex(m.FetchError,'MIGU_API_LOADING'):store.resolve('p'+pid,wait=.01)
                self.assertEqual(store.pool.queue.qsize(),0)
            self.assertEqual(store.fetches,8)
        finally:
            gate.set();pool.shutdown(wait=True);store.close()

    def test_missing_login_state_preserves_previous_rejection_until_positive_recovery(self):
        now=[0];settings=a.AndroidSettings(user_id='123456789',token='synthetic-token')
        url='http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=test'
        def payload(logged):return {'code':'200','rid':'SUCCESS','body':{'auth':{'logined':logged},'urlInfo':{'url':url,'rateType':2},'content':{'contId':'631780532'}}}
        client=Mock();client.get.side_effect=[(json.dumps(payload(False)).encode(),{}),(b'{"code":403,"rid":"COPYRIGHT_AREA_INVALID"}',{}),(json.dumps(payload(True)).encode(),{})]
        def resolve(pid):return a.android_play_url(pid,settings,Mock(return_value=client),observer=store._observe)
        store=a.AndroidStore(settings,resolve,clock=lambda:now[0]);self.addCleanup(store.close)
        store.resolve('p631780532');self.assertEqual(store.status()['credential_state'],'not_recognized')
        now[0]=301
        with self.assertRaises(a.MiguApiError):store.resolve('p631780532')
        self.assertEqual(store.status()['credential_state'],'not_recognized')
        now[0]=362;store.resolve('p631780532')
        self.assertEqual(store.status()['credential_state'],'accepted')

    def test_non_string_reason_is_classified_as_format_change(self):
        client=Mock();client.get.return_value=(b'{"rid":[],"body":{}}',{})
        with self.assertRaisesRegex(m.UpdateError,'MIGU_API_FORMAT_CHANGED'):
            a.android_play_url('631780532',a.AndroidSettings(),Mock(return_value=client))

    def test_standalone_respects_removed_catalogue_urls_and_fails_explicitly(self):
        data=Path('migu-live.py').read_bytes()
        for endpoint in (b'http://www.52top.com.cn:678/downloads/migu.txt',b'https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu.m3u8'):
            self.assertNotIn(endpoint,data)
        api=runpy.run_path('migu-live.py',run_name='migu_audit_library')
        self.assertEqual(api['DEFAULT_PORT'],28768)
        with self.assertRaisesRegex(api['FetchError'],'LIST_PROVIDER_DISABLED'):api['ListStore']()
