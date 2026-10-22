"""EPG timezone, channel identity, disk failure and stale-data behaviour."""
import gzip,json,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
import xml.etree.ElementTree as ET
from test_bridge import standalone,service
import epg_store as epg

class EpgTests(unittest.TestCase):
 def store(self,catalog=None):
  directory=tempfile.TemporaryDirectory();self.addCleanup(directory.cleanup)
  store=epg.EpgStore(catalog or {'cctv1':{'name':'CCTV-1 综合','logo':'https://example.test/logo?a=1&b=2'}},directory.name);self.addCleanup(store.close);return store
 def test_normalize_dedup_ms_channel_filter_and_xml_safety(self):
  now=int(time.time());row={'startTime':now*1000,'endTime':(now+60)*1000,'title':'新闻 &amp; 专题\x01','channelId':'cctv1'}
  rows=epg.normalize([row,row,{**row,'channelId':'cctv2'},{**row,'endTime':now-1}], 'cctv1',now)
  self.assertEqual(len(rows),1);self.assertEqual(rows[0]['start'],now);self.assertEqual(rows[0]['title'],'新闻 & 专题')
  store=self.store();store.rows={'cctv1':rows};store.updated=store.full_updated=time.time()
  plain=store.xml();self.assertEqual(gzip.decompress(store.xml(True)),plain)
  tree=ET.fromstring(plain);program=tree.find('programme');self.assertEqual(program.attrib['channel'],'cctv1')
  self.assertTrue(program.attrib['start'].endswith(' +0800'));self.assertEqual(program.findtext('title'),'新闻 & 专题')
 def test_now_next_uses_same_logical_id(self):
  now=int(time.time());store=self.store();store.rows={'cctv1':[{'start':now-30,'end':now+30,'title':'当前'},{'start':now+30,'end':now+90,'title':'随后'}]};store.updated=store.full_updated=time.time()
  result=store.now_next()['cctv1'];self.assertEqual(result['now']['title'],'当前');self.assertEqual(result['next']['title'],'随后')
 def test_readonly_cache_logs_once_and_keeps_rows(self):
  store=self.store();store.rows={'cctv1':[{'start':1,'end':2,'title':'cache'}]}
  with patch.object(Path,'mkdir',side_effect=PermissionError('readonly')) as mkdir:
   store._save();store._save()
  self.assertEqual(mkdir.call_count,1);self.assertFalse(store.disk);self.assertTrue(store.rows)
 def test_failed_update_keeps_previous_programs(self):
  store=self.store();now=int(time.time());old=[{'start':now-30,'end':now+60,'title':'已有'}];store.rows={'cctv1':old};store.busy=True
  with patch.object(store,'_fetch_one',side_effect=OSError('offline')):store._refresh(['cctv1'])
  self.assertEqual(store.rows['cctv1'],old);self.assertIn('cctv1',store.errors);self.assertFalse(store.busy)
 def test_corrupt_cache_does_not_break_initialization(self):
  with tempfile.TemporaryDirectory() as directory:
   (Path(directory)/'epg-v1.json').write_text('[]')
   store=epg.EpgStore({'cctv1':{'name':'test'}},directory);self.assertFalse(store.rows);store.close()
 def test_alias_channel_ids_are_allowed_without_cross_channel_data(self):
  now=int(time.time());rows=[{'startTime':now,'endTime':now+60,'title':'纪录','channelId':'cctv9'}]
  self.assertEqual(len(epg.normalize(rows,'cctvjilu')),1);self.assertEqual(len(epg.normalize(rows,'cctvchild')),0)

if __name__=='__main__':unittest.main()
