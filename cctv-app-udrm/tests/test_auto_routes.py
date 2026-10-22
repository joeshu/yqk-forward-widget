import time,unittest,threading
from urllib.request import urlopen,Request
from unittest.mock import patch
from test_bridge import service
class AutoRouteTests(unittest.TestCase):
 def setUp(self):
  self.a=service.Channel('demo','Demo','https://a.test',logical_id='demo')
  self.b=service.Channel('demo_bd','Demo BD','https://b.test',logical_id='demo',catalog=False)
  self.live=service.LiveService({}, {'demo':self.a,'demo_bd':self.b});self.live.stopping.set();self.live.sdk.phase='ready'
 def tearDown(self):self.live.close()
 def ready(self,ch,seq):
  ch.playlist=service.Playlist((service.Entry(seq,4,'https://test/1.ts'),service.Entry(seq+1,4,'https://test/2.ts')),4,0,False);ch.updated=time.monotonic()
 def test_switch_sequence_is_monotonic_and_segments_remain_bound_to_source(self):
  self.ready(self.a,100)
  with patch.object(self.live,'playlist_bytes',return_value=b''),patch.object(self.live,'_schedule') as schedule:
   initial=self.live.auto_playlist_bytes('demo');self.assertIn(b'MEDIA-SEQUENCE:100',initial)
   self.a.error='CDN failure';self.a.failures=2
   with self.assertRaisesRegex(service.LiveError,'备用线路'):self.live.auto_playlist_bytes('demo')
   schedule.assert_called_once_with(self.b)
   self.ready(self.b,900000)
   switched=self.live.auto_playlist_bytes('demo');self.assertIn(b'MEDIA-SEQUENCE:102',switched);self.assertIn(b'DISCONTINUITY-SEQUENCE:1',switched);self.assertIn(b'/segments/demo_bd/',switched);self.assertNotIn(b'/segments/demo/',switched)
   # Healthy route stays selected; do not bounce to recovered preferred route.
   self.a.error='';self.a.failures=0
   self.assertEqual(self.live.auto_playlist_bytes('demo'),switched)
 def test_source_restart_and_discontinuity_counter_do_not_go_backwards(self):
  self.ready(self.a,100)
  p=self.a.playlist;self.a.playlist=service.Playlist(p.entries,4,11,False)
  with patch.object(self.live,'playlist_bytes',return_value=b''):
   self.assertIn(b'DISCONTINUITY-SEQUENCE:11',self.live.auto_playlist_bytes('demo'))
   self.ready(self.a,1)
   result=self.live.auto_playlist_bytes('demo')
   self.assertIn(b'MEDIA-SEQUENCE:102',result);self.assertIn(b'DISCONTINUITY-SEQUENCE:12',result)
 def test_initial_wait_without_route_error_does_not_rotate_cdns(self):
  with patch.object(self.live,'playlist_bytes',side_effect=service.LiveError('首片或防抖准备中')),patch.object(self.live,'_schedule') as schedule:
   with self.assertRaises(service.LiveError):self.live.auto_playlist_bytes('demo')
   schedule.assert_not_called();self.assertEqual(self.live.auto_states['demo']['route'],'demo')
 def test_common_sdk_failure_does_not_rotate_cdns(self):
  self.live.sdk.phase='failed';self.a.error='license';self.a.failures=2
  with patch.object(self.live,'_schedule') as schedule:
   with self.assertRaises(service.LiveError):self.live.auto_playlist_bytes('demo')
   schedule.assert_not_called();self.assertEqual(self.live.auto_states['demo']['route'],'demo')
 def test_all_routes_cooling_down_does_not_loop(self):
  for ch in (self.a,self.b):ch.error='CDN failure';ch.failures=2;ch.retry_at=time.monotonic()+30
  with patch.object(self.live,'_schedule') as schedule:
   with self.assertRaises(service.LiveError):self.live.auto_playlist_bytes('demo')
   schedule.assert_not_called()

class AutoHTTPTests(unittest.TestCase):
 def test_default_subscription_uses_auto_but_explicit_lines_stay_fixed_and_head_is_lazy(self):
  channels={k:v for k,v in service.build_channels().items() if v.logical_id=='cctv7'}
  live=service.LiveService({},channels);live.stopping.set()
  server=service.ThreadingHTTPServer(('127.0.0.1',0),service.make_handler(live));thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  base='http://127.0.0.1:'+str(server.server_port)
  try:
   with urlopen(base+'/all.m3u') as response:self.assertIn(b'/auto/cctv7.m3u8',response.read())
   with urlopen(base+'/lines.m3u') as response:
    body=response.read();self.assertIn(b'/live/cctv7.m3u8',body);self.assertNotIn(b'/auto/',body)
   with urlopen(Request(base+'/auto/cctv7.m3u8',method='HEAD')) as response:self.assertEqual(response.status,200)
   self.assertEqual(live.sdk.sessions,0);self.assertEqual(live.auto_states,{})
  finally:server.shutdown();server.server_close();thread.join();live.close()
