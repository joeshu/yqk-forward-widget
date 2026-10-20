import json
import threading
import unittest
from datetime import datetime, timedelta
from unittest import mock
import xml.etree.ElementTree as ET
from test_jscore_service import load_service


class TestOfficialEPG(unittest.TestCase):
    def setUp(self):
        self.m = load_service()
        self.day = self.m.epg_day()
        self.start = int(datetime.combine(self.day, datetime.min.time(), self.m.EPG_CHINA).timestamp())

    def payload(self, rows=None):
        return json.dumps({'cctv2':{'program':rows if rows is not None else [
            {'t':'财经 & <新闻>', 'st':self.start, 'et':self.start+3600}]}}).encode()

    def test_parse_and_xml_match_playlist_ids_and_beijing_time(self):
        rows = self.m.parse_epg(self.payload(), {'cctv2':'财经'}, self.day)
        body = self.m.render_epg({'cctv2':'财经'}, {(self.day,'cctv2'):rows['cctv2']})
        root = ET.fromstring(body);p = root.find('programme')
        self.assertEqual(p.get('channel'),root.find('channel').get('id'))
        self.assertEqual(p.get('start'),self.day.strftime('%Y%m%d')+'000000 +0800')
        self.assertEqual(p.findtext('title'),'财经 & <新闻>')

    def test_bad_dates_titles_types_and_duplicates(self):
        good={'t':'节目','st':self.start,'et':self.start+60}
        bad=[dict(good,t='\x00'),dict(good,st=True),dict(good,et=self.start),
             dict(good,st=self.start-60),dict(good,et=float('inf')),dict(good,t='x'*513)]
        parsed=self.m.parse_epg(self.payload([good,good]+bad),['cctv2'],self.day)
        self.assertEqual(len(parsed['cctv2']),1)
        self.assertNotIn('cctv2',self.m.parse_epg(self.payload(bad),['cctv2'],self.day))
        self.assertEqual(self.m.parse_epg(self.payload([]),['cctv2'],self.day),{'cctv2':()})

    def test_refresh_is_batched_cached_and_does_not_activate_video(self):
        store=self.m.OfficialEPG({'cctv2':'财经'})
        with mock.patch.object(self.m,'get',return_value=(self.payload(),'')) as get:
            self.assertIsNotNone(store.document())
            store.worker.join(2)
            self.assertEqual(get.call_count,3)
            store.document();self.assertEqual(get.call_count,3)
        self.assertEqual(store.snapshot()['missing_channels'],[])
        store.close()

    def test_failed_refresh_retains_good_data_and_reports_missing(self):
        store=self.m.OfficialEPG({'cctv2':'财经','cctv1':'综合'})
        with mock.patch.object(self.m,'get',return_value=(self.payload(),'')):
            store.document();store.worker.join(2)
        old=store.body;store.next_refresh=0
        with mock.patch.object(self.m,'get',side_effect=OSError('private upstream detail')):
            store.refresh();store.worker.join(2)
        self.assertEqual(store.body,old)
        self.assertEqual(store.snapshot()['missing_channels'],['cctv1'])
        self.assertEqual(store.snapshot()['error'],'epg-upstream-partial')
        store.close()

    def test_single_flight_and_shutdown(self):
        store=self.m.OfficialEPG({'cctv2':'财经'});entered=threading.Event();release=threading.Event()
        def fetch(*a,**k):
            entered.set();release.wait(2);return self.payload(),''
        with mock.patch.object(self.m,'get',side_effect=fetch) as get:
            store.refresh();self.assertTrue(entered.wait(1))
            for _ in range(10):store.refresh()
            self.assertEqual(get.call_count,1)
            store.close();release.set();store.worker.join(2)
            self.assertEqual(get.call_count,1)
            self.assertIsNone(store.body)

    def test_midnight_forces_refresh_despite_monotonic_ttl(self):
        store=self.m.OfficialEPG({'cctv2':'财经'})
        with mock.patch.object(self.m,'get',return_value=(self.payload(),'')):
            store.document();store.worker.join(2)
        with mock.patch.object(self.m,'epg_day',return_value=self.day+timedelta(days=1)),mock.patch.object(self.m,'get',return_value=(b'{}','')) as get:
            store.refresh();store.worker.join(2);self.assertEqual(get.call_count,3)
        store.close()

    def test_today_is_published_while_other_days_are_still_downloading(self):
        store=self.m.OfficialEPG({'cctv2':'财经'});entered=threading.Event();release=threading.Event()
        calls=[]
        def fetch(*a,**k):
            calls.append(1)
            if len(calls)==2:
                entered.set();release.wait(2)
            return self.payload(),''
        with mock.patch.object(self.m,'get',side_effect=fetch):
            store.refresh();self.assertTrue(entered.wait(1))
            self.assertTrue(store.ready.is_set())
            self.assertIsNotNone(store.document())
            self.assertTrue(store.worker.is_alive())
            release.set();store.worker.join(2)
        store.close()
