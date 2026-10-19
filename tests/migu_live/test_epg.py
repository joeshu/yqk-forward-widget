from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import json
import threading
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit, parse_qs
import xml.etree.ElementTree as ET

from migu import core as m, epg as e, native as n
import live_fixture


def payload(pid='608807420', title='节目 & <测试>', start=None):
    start=start or m.utcnow()-timedelta(minutes=5)
    return json.dumps({'code':200,'body':{'program':[{'content':[{'pID':pid,'contName':title,'startTime':int(start.timestamp()*1000),'endTime':int((start+timedelta(hours=2)).timestamp()*1000)}]}]}},ensure_ascii=False).encode()


class EpgTests(unittest.TestCase):
    def store(self, factory=None, **kwargs):
        client=Mock()
        client.get.side_effect=lambda url, **k: (payload(urlsplit(url).path.split('/')[-2]),{})
        store=e.EpgStore(client_factory=factory or Mock(return_value=client), **kwargs)
        self.addCleanup(store.close)
        return store,client

    def finish(self,store):
        with store.lock: future=store.future
        if future: future.result(5)

    def test_official_json_to_xmltv_matches_stable_ids_timezone_and_escaping(self):
        rows=e.official_programmes('608807420',payload())
        raw,details,_=e.render_epg({'608807420':rows})
        tree=ET.fromstring(raw)
        programme=tree.find('programme')
        self.assertEqual(programme.get('channel'),'p608807420')
        self.assertEqual(programme.findtext('title'),'节目 & <测试>')
        self.assertTrue(programme.get('start').endswith(' +0800'))
        self.assertEqual(details['matched_channels'],1)
        self.assertEqual(len(tree.findall('channel')),len(n.BUILTIN_CHANNELS))

    def test_bad_json_and_wrong_channel_do_not_publish_invented_or_expired_epg(self):
        with self.assertRaisesRegex(m.FetchError,'FORMAT_CHANGED'): e.official_programmes('608807420',b'<html/>')
        with self.assertRaisesRegex(m.FetchError,'REJECTED'): e.official_programmes('608807420',b'{"code":403}')
        self.assertEqual(e.official_programmes('608807420',payload(pid='999999999')),())
        expired=e.official_programmes('608807420',payload(start=m.utcnow()-timedelta(days=2)))
        with self.assertRaisesRegex(m.FetchError,'EMPTY_OR_EXPIRED'): e.render_epg({'608807420':expired})
        with self.assertRaises(m.FetchError): e.official_programmes('608807420',b'x'*(512*1024+1))

    def test_epg_role_allows_only_official_fixed_programme_paths(self):
        m.validate_url('https://program-sc.miguvideo.com/live/v2/tv-programs-data/608807420/20261019','epg')
        for url in ['http://program-sc.miguvideo.com/live/v2/tv-programs-data/608807420/20261019','https://program-sc.miguvideo.com/other','https://127.0.0.1/live/v2/tv-programs-data/608807420/20261019','https://program-sc.miguvideo.com/live/v2/tv-programs-data/608807420/20261019?x=1']:
            with self.assertRaises(m.UpdateError): m.validate_url(url,'epg')

    def test_parallel_viewers_share_bounded_refresh_and_six_hour_channel_cache(self):
        store,client=self.store()
        entered,release=threading.Event(),threading.Event()
        original=client.get.side_effect
        active=[0,0]; lock=threading.Lock()
        def get(*args,**kwargs):
            with lock: active[0]+=1; active[1]=max(active)
            entered.set(); release.wait(2)
            try: return original(*args,**kwargs)
            finally:
                with lock: active[0]-=1
        client.get.side_effect=get
        with ThreadPoolExecutor(max_workers=8) as pool:
            futures=[pool.submit(store.get,3) for _ in range(8)]
            self.assertTrue(entered.wait(1)); release.set()
            for future in futures: self.assertIn(b'<programme',future.result(4))
        self.finish(store)
        self.assertEqual(client.get.call_count,len(n.BUILTIN_CHANNELS))
        self.assertLessEqual(active[1],8)
        store.get(); self.assertEqual(client.get.call_count,len(n.BUILTIN_CHANNELS))
        self.assertEqual(store.status()['matched_channels'],len(n.BUILTIN_CHANNELS))

    def test_partial_data_is_published_without_waiting_for_all_channels(self):
        release=threading.Event(); store,client=self.store()
        self.addCleanup(release.set)
        original=client.get.side_effect
        def get(url,**kwargs):
            if urlsplit(url).path.split('/')[-2] not in {x[0] for x in n.BUILTIN_CHANNELS[:8]}:
                release.wait(2)
            return original(url,**kwargs)
        client.get.side_effect=get
        data=store.get(1)
        self.assertIn(b'<programme',data)
        self.assertTrue(store.status()['refreshing'])
        self.assertLess(store.status()['matched_channels'],len(n.BUILTIN_CHANNELS))
        release.set(); self.finish(store)

    def test_slow_first_channel_does_not_hide_other_completed_programmes(self):
        release=threading.Event(); store,client=self.store()
        self.addCleanup(release.set)
        original=client.get.side_effect
        def get(url,**kwargs):
            if urlsplit(url).path.split('/')[-2] == n.BUILTIN_CHANNELS[0][0]:
                release.wait(2)
            return original(url,**kwargs)
        client.get.side_effect=get
        self.assertIn(b'<programme',store.get(.2))
        self.assertTrue(store.status()['refreshing'])
        release.set(); self.finish(store)

    def test_empty_upstream_cools_down_without_blocking_channel_catalogue(self):
        client=Mock(); client.get.side_effect=m.FetchError('HTTP_503')
        store,_=self.store(Mock(return_value=client))
        for _ in range(2):
            with self.assertRaises(m.FetchError): store.get(2)
        self.finish(store)
        self.assertEqual(client.get.call_count,len(n.BUILTIN_CHANNELS))
        self.assertFalse(store.status()['ready'])
        self.assertEqual(len(n.NativeStore().get().channels),len(n.BUILTIN_CHANNELS))

    def test_stale_success_survives_failed_refresh_and_expired_schedules_are_rejected(self):
        now=[0]; store,client=self.store(clock=lambda:now[0])
        store.get(2); self.finish(store); old=store.get()
        now[0]=6*3600+1; client.get.side_effect=m.FetchError('HTTP_503')
        self.assertEqual(store.get(),old); self.finish(store)
        self.assertTrue(store.status()['ready'])
        with patch.object(m,'utcnow',return_value=m.utcnow()+timedelta(days=3)):
            self.assertFalse(store.status()['ready'])
            with self.assertRaises(m.FetchError): store.get(.001)

    def test_midnight_invalidates_date_even_before_refresh_interval(self):
        store,client=self.store(); store.get(2); self.finish(store)
        today=m.utcnow(); tomorrow=(today.astimezone(m.CHINA)+timedelta(days=1)).replace(hour=0,minute=0,second=1)
        with patch.object(m,'utcnow',return_value=tomorrow):
            try: store.get(2)
            except m.FetchError: pass
            self.finish(store)
            self.assertEqual(store.day,tomorrow.strftime('%Y%m%d'))
            self.assertTrue(any(tomorrow.strftime('%Y%m%d') in call.args[0] for call in client.get.call_args_list))


class EpgHttpTests(unittest.TestCase):
    server=live_fixture.server
    request=live_fixture.request

    def epg(self):
        client=Mock(); client.get.side_effect=lambda url,**k:(payload(urlsplit(url).path.split('/')[-2]),{})
        return e.EpgStore(client_factory=Mock(return_value=client)),client

    def test_subscription_declares_local_xmltv_and_channel_ids_match(self):
        epg,client=self.epg()
        with self.server(epg=epg) as (host,service):
            code,_,body=self.request(host,'/all.m3u')
            self.assertEqual(code,200)
            self.assertIn((f'x-tvg-url="{service.public_base}/epg.xml"').encode(),body)
            client.get.assert_not_called()
            code,headers,xml=self.request(host,'/epg.xml')
            self.assertEqual(code,200); self.assertIn('application/xml',headers['Content-Type'])
            self.assertEqual({c.get('id') for c in ET.fromstring(xml).findall('channel')},set(service.store.get().channels))
            code,_,body=self.request(host,'/status'); self.assertIn('python',json.loads(body)['runtime'])

    def test_epg_token_and_origin_guards_and_disable_option(self):
        epg,client=self.epg()
        with self.server(epg=epg,require_token=True) as (host,service):
            self.assertEqual(self.request(host,'/epg.xml')[0],401)
            code,_,body=self.request(host,'/all.m3u?token='+live_fixture.TOKEN)
            self.assertIn(('/epg.xml?token='+live_fixture.TOKEN).encode(),body)
            self.assertEqual(self.request(host,'/epg.xml?token='+live_fixture.TOKEN)[0],200)
        with self.server(epg=e.EpgStore(enabled=False)) as (host,service):
            self.assertNotIn(b'x-tvg-url',self.request(host,'/all.m3u')[2])
            self.assertEqual(self.request(host,'/epg.xml')[0],404)
            self.assertEqual(self.request(host,'/epg.xml',headers={'Host':'evil.example'})[0],403)
