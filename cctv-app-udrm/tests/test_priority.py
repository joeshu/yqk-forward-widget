"""Cancellation must happen before expensive SDK work and reset partial state."""
import unittest
from unittest.mock import Mock,patch
from test_bridge import service,Builder

class PriorityTests(unittest.TestCase):
 def test_upstream_error_reports_safe_reason_type(self):
  with patch.object(service,'urlopen',side_effect=service.URLError(TimeoutError('private detail'))):
   with self.assertRaisesRegex(service.LiveError,'URLError/TimeoutError') as caught:service.fetch('https://example.test/a',1024)
  self.assertNotIn('private detail',str(caught.exception))
 def test_obsolete_channel_never_starts_sdk(self):
  sdk=service.MediaSDK({})
  with patch.object(sdk,'_start',side_effect=AssertionError('obsolete SDK work')):
   with self.assertRaises(service.Superseded):sdk.transform('a',Builder().stream(),current=lambda:False)
 def test_cancel_mid_segment_resets_state_and_does_not_publish(self):
  sdk=service.MediaSDK({});sdk.client=Mock()
  sdk.client.process_batch.side_effect=lambda channel,frames:frames
  builder=Builder();source=b''.join(builder.stream() for _ in range(5))
  decisions=iter([True,True,False])
  with self.assertRaises(service.Superseded):sdk.transform('a',source,current=lambda:next(decisions))
  self.assertEqual(sdk.client.process_batch.call_count,1)
  sdk.client.reset.assert_called_once_with('a');self.assertNotIn('a',sdk.timings)
 def test_phone_default_selects_advertised_low_bitrate(self):
  master=b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1800000\nhd.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=600000\nmd.m3u8\n'
  child=b'#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:4,\na.ts\n'
  requested=[]
  def fetch(url,*args):requested.append(url);return (master if url.endswith('master.m3u8') else child,url)
  with patch.object(service,'fetch',side_effect=fetch):service.read_playlist('https://example.test/master.m3u8',600000)
  self.assertEqual(requested[-1],'https://example.test/md.m3u8')
 def test_backoff_bounds_repeated_network_failures(self):
  ch=service.Channel('a','A','https://example.test/master.m3u8');live=service.LiveService({}, {'a':ch})
  live.stopping.set();live.worker.join();live.sdk=Mock()
  try:
   with patch.object(service,'read_playlist',side_effect=service.LiveError('Upstream transport URLError')):
    for expected in [3,6,12,24,30]:
     ch.retry_at=0
     with self.assertRaises(service.LiveError):live.refresh(ch,background=True)
     remaining=ch.retry_at-service.time.monotonic();self.assertGreater(remaining,expected-.2);self.assertLessEqual(remaining,expected)
  finally:live.close()

if __name__=='__main__':unittest.main()
