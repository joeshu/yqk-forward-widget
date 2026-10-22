import io,time,unittest
from email.message import Message
from urllib.error import HTTPError
from unittest.mock import patch
from test_bridge import service
class RecoveryBoundaries(unittest.TestCase):
 def test_retry_after_bounds_and_http_failure_closes_response(self):
  self.assertEqual(service.retry_after_seconds('99999'),120)
  self.assertEqual(service.retry_after_seconds('bad'),0)
  self.assertEqual(service.retry_after_seconds('Thu, 01 Jan 1970 00:00:00 GMT'),0)
  headers=Message();headers['Retry-After']='45';body=io.BytesIO(b'not retained');error=HTTPError('https://example.test',429,'limited',headers,body)
  with patch.object(service,'urlopen',side_effect=error):
   with self.assertRaises(service.UpstreamHTTPError) as caught:service.fetch('https://example.test',1024)
  self.assertEqual(caught.exception.retry_after,45);self.assertTrue(body.closed)
 def test_bad_hls_numeric_fields_and_master_cycles_are_recoverable(self):
  for field in ['#EXT-X-MEDIA-SEQUENCE:bad','#EXT-X-MEDIA-SEQUENCE:-1','#EXT-X-DISCONTINUITY-SEQUENCE:-1','#EXT-X-TARGETDURATION:999','#EXTINF:inf,']:
   body=('#EXTM3U\n'+field+'\n'+('' if field.startswith('#EXTINF:') else '#EXTINF:4,\n')+'a.ts\n').encode()
   with patch.object(service,'fetch',return_value=(body,'https://example.test/a')):
    with self.assertRaises(service.LiveError):service.read_playlist('https://example.test/a',2500000)
  master=b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1800000\na.m3u8\n'
  with patch.object(service,'fetch',return_value=(master,'https://example.test/a.m3u8')) as fetch:
   with self.assertRaisesRegex(service.LiveError,'loop'):service.read_playlist('https://example.test/a.m3u8',2500000)
   self.assertEqual(fetch.call_count,1)
 def test_cooldown_does_not_submit_jobs_or_reopen_network(self):
  ch=service.Channel('a','A','https://example.test');live=service.LiveService({}, {'a':ch});live.stopping.set();live.worker.join();live.stopping.clear();live.active_channel='a'
  try:
   ch.retry_at=time.monotonic()+45
   with patch.object(live.refresh_pool,'submit') as submit:
    for _ in range(10):live._schedule(ch)
    submit.assert_not_called();self.assertEqual(live.refresh_cooldown_skips,10)
  finally:live.close()
 def test_server_delay_is_preserved_by_refresh_backoff(self):
  ch=service.Channel('a','A','https://example.test');live=service.LiveService({}, {'a':ch});live.stopping.set();live.worker.join()
  try:
   with patch.object(live.sdk,'ensure_ready'),patch.object(service,'read_playlist',side_effect=service.UpstreamHTTPError(503,45)):
    with self.assertRaises(service.LiveError):live.refresh(ch,background=True)
   delay=ch.retry_at-time.monotonic();self.assertGreater(delay,44);self.assertLessEqual(delay,45)
  finally:live.close()
