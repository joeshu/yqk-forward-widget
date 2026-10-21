"""Bound cache retention, cancel obsolete waits, and publish without tail download."""
import threading,time,unittest
from unittest.mock import Mock,patch
from test_bridge import service,Builder

class MemorySwitchTests(unittest.TestCase):
 def make(self,count=2):
  channels={str(i):service.Channel(str(i),str(i),'https://example.test/main.m3u8') for i in range(count)}
  live=service.LiveService({},channels);live.stopping.set();live.worker.join();self.addCleanup(live.close)
  return live,channels
 def test_inactive_raw_is_removed_and_recent_cache_keeps_two(self):
  live,channels=self.make(5);live.active_channel='0';before=0
  for ch in channels.values():
   ch.last_active=time.monotonic()
   for n in range(8):
    entry=service.Entry(n,4,f'https://example.test/{n}.ts');key=live.token(ch,entry)
    ch.cache[key]=b'x'*(1024*1024);ch.raw[key]=b'y'*(1024*1024);ch.history[n]=(entry,0)
   ch.playlist=service.Playlist(tuple(v[0] for v in ch.history.values()),4,0,False)
   before+=sum(map(len,ch.cache.values()))+sum(map(len,ch.raw.values()))
  live._trim_memory()
  for key,ch in channels.items():
   if key!='0':self.assertEqual(len(ch.cache),2);self.assertEqual(len(ch.raw),0);self.assertEqual(len(ch.playlist.entries),2)
  after=sum(sum(map(len,c.cache.values()))+sum(map(len,c.raw.values())) for c in channels.values())
  self.assertLess(after,before/2);self.assertLessEqual(live._cache_stats()['processed_bytes'],32*1024*1024)
 def test_idle_cache_is_expired_without_closing_sdk(self):
  live,channels=self.make();ch=channels['1'];ch.cache['a']=b'x';ch.raw['a']=b'y';ch.last_active=time.monotonic()-21
  live.sdk=Mock();live._trim_memory()
  self.assertFalse(ch.cache);self.assertFalse(ch.raw);self.assertIsNone(ch.playlist);live.sdk.close.assert_not_called()
 def test_first_segment_does_not_wait_for_slow_second_download(self):
  live,channels=self.make(1);ch=channels['0'];live.active_channel='0';live.sdk=Mock();live.sdk.timings={}
  source=Builder().stream();live.sdk.transform.return_value=source
  media=service.Playlist(tuple(service.Entry(i,4,f'https://example.test/{i}.ts') for i in [1,2]),4,0,False)
  entered=threading.Event();release=threading.Event()
  def fetch(url,*args):
   if url.endswith('/2.ts'):entered.set();release.wait(3)
   return source,url
  thread=threading.Thread(target=lambda:live.refresh(ch,background=True))
  try:
   with patch.object(service,'read_playlist',return_value=media),patch.object(service,'fetch',side_effect=fetch):
    thread.start();self.assertTrue(entered.wait(1));self.assertTrue(ch.ready.wait(1));self.assertEqual(len(ch.playlist.entries),1)
    self.assertTrue(thread.is_alive());release.set();thread.join(3)
    self.assertFalse(ch.raw)
  finally:release.set();thread.join(3)
 def test_switch_cancels_old_download_wait(self):
  live,channels=self.make();old=channels['0'];live.active_channel='0';live.sdk=Mock();live.sdk.timings={}
  entry=service.Entry(1,4,'https://example.test/slow.ts');media=service.Playlist((entry,),4,0,False)
  entered=threading.Event();release=threading.Event()
  def fetch(*args):entered.set();release.wait(3);return Builder().stream(),''
  thread=threading.Thread(target=lambda:live.refresh(old,background=True))
  try:
   with patch.object(service,'read_playlist',return_value=media),patch.object(service,'fetch',side_effect=fetch):
    thread.start();self.assertTrue(entered.wait(1));start=time.monotonic();live.active_channel='1';thread.join(.5)
    self.assertFalse(thread.is_alive());self.assertLess(time.monotonic()-start,.5);live.sdk.transform.assert_not_called()
  finally:release.set();thread.join(3)
 def test_expired_playlist_is_not_advertised_as_ready(self):
  live,channels=self.make(1);ch=channels['0'];ch.playlist=service.Playlist((service.Entry(1,4,'https://example.test/1.ts'),),4,0,False);ch.updated=time.monotonic()-30
  with patch.object(live,'_schedule'),patch.object(ch.ready,'wait',return_value=False):
   with self.assertRaises(service.LiveError):live.playlist_bytes(ch)
  self.assertIsNone(ch.playlist)

if __name__=='__main__':unittest.main()
