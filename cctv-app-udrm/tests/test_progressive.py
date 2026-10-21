"""First verified segment must be visible while later transforms are blocked."""
import threading
import time
import unittest
from unittest.mock import Mock,patch
from test_bridge import service,Builder

class ProgressiveTests(unittest.TestCase):
 def test_first_segment_published_before_second_finishes(self):
  ch=service.Channel('test','Test','https://example.test/main.m3u8')
  live=service.LiveService({}, {'test':ch});live.stopping.set();live.worker.join();live.active_channel='test'
  live.sdk=Mock();live.sdk.timings={};source=Builder().stream();second=threading.Event();release=threading.Event();calls=[]
  def transform(*args,**kwargs):
   calls.append(args)
   if len(calls)==2:second.set();release.wait(3)
   return source
  live.sdk.transform.side_effect=transform
  media=service.Playlist(tuple(service.Entry(i,4,f'https://example.test/{i}.ts') for i in [1,2]),4,0,False)
  thread=threading.Thread(target=lambda:live.refresh(ch,background=True))
  try:
   with patch.object(service,'read_playlist',return_value=media),patch.object(service,'fetch',return_value=(source,'')):
    thread.start();self.assertTrue(second.wait(2))
    start=time.monotonic();body=live.playlist_bytes(ch)
    self.assertLess(time.monotonic()-start,.2);self.assertEqual(body.count(b'#EXTINF'),1)
    self.assertTrue(thread.is_alive());self.assertTrue(ch.ready.is_set())
    release.set();thread.join(3);self.assertFalse(thread.is_alive())
    self.assertEqual(live.playlist_bytes(ch).count(b'#EXTINF'),2)
  finally:release.set();thread.join(3);live.close()
 def test_stale_playlist_returns_while_update_is_pending(self):
  ch=service.Channel('test','Test','https://example.test/main.m3u8')
  live=service.LiveService({}, {'test':ch});live.stopping.set();live.worker.join()
  ch.playlist=service.Playlist((service.Entry(1,4,'https://example.test/1.ts'),),4,0,False)
  ch.updated=time.monotonic()-6
  try:
   with patch.object(live,'_schedule') as schedule,ch.lock:
    started=time.monotonic();self.assertIn(b'#EXTINF',live.playlist_bytes(ch))
    self.assertLess(time.monotonic()-started,.2);schedule.assert_called_once_with(ch)
  finally:live.close()
 def test_background_schedules_only_selected_channel(self):
  channels={x:service.Channel(x,x,'https://example.test/main.m3u8') for x in ['a','b']}
  live=service.LiveService({},channels);live.active_channel='a'
  for ch in channels.values():ch.last_active=time.monotonic()
  event=threading.Event();selected=[]
  try:
   with patch.object(live,'_schedule',side_effect=lambda ch:(selected.append(ch.ident),event.set())):
    self.assertTrue(event.wait(2));self.assertEqual(selected,['a'])
  finally:live.close()

if __name__=='__main__':unittest.main()
