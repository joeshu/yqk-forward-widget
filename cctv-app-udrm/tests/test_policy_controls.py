import time,unittest
from unittest.mock import patch
from concurrent.futures import Future
from test_bridge import service,standalone
class PolicyControls(unittest.TestCase):
 def test_large_cache_retains_more_recent_objects_and_honors_idle_expiry(self):
  ch=service.Channel('a','A','https://example.test');live=service.LiveService({}, {'a':ch},cache_mib=64,inactive_cache_segments=5,inactive_cache_seconds=60)
  live.stopping.set();live.worker.join()
  try:
   ch.last_active=time.monotonic()-25
   ch.cache.update((str(i),b'x') for i in range(8));live._trim_memory()
   self.assertEqual(len(ch.cache),5)
   ch.last_active=time.monotonic()-61;live._trim_memory();self.assertEqual(len(ch.cache),0)
  finally:live.close()
 def test_debounce_coalesces_repeated_selection_and_cdn_change_keeps_timer(self):
  a=service.Channel('a','A','https://a.test',logical_id='a');alt=service.Channel('a_bd','A','https://b.test',logical_id='a');b=service.Channel('b','B','https://b.test')
  live=service.LiveService({}, {'a':a,'a_bd':alt,'b':b},zap_debounce_ms=10000);live.stopping.set();live.worker.join();live.stopping.clear()
  try:
   with patch.object(live.refresh_pool,'submit',return_value=Future()) as submit:
    live._select_channel(a);first=live.selection_changed
    live._select_channel(a);self.assertEqual(live.selection_changed,first)
    live._schedule(a);submit.assert_not_called()
    live._select_channel(alt);self.assertEqual(live.selection_changed,first)
    live.selection_changed-=11;live._schedule(alt);submit.assert_called_once()
    live._select_channel(b);self.assertGreater(live.selection_changed,first-1)
  finally:live.close()
 def test_ready_cached_channel_does_not_wait_for_debounce(self):
  ch=service.Channel('a','A','https://a.test');live=service.LiveService({}, {'a':ch},zap_debounce_ms=10000,download_workers=2,refresh_workers=1)
  live.stopping.set();live.worker.join();live.stopping.clear()
  try:
   ch.playlist=service.Playlist((service.Entry(1,4,'https://a.test/1.ts'),),4,0,False);live._select_channel(ch)
   with patch.object(live.refresh_pool,'submit',return_value=Future()) as submit:live._schedule(ch);submit.assert_called_once()
   self.assertEqual(live.download_workers,2);self.assertEqual(live.refresh_workers,1)
  finally:live.close()

 def test_phone_settings_are_available_without_cli_and_can_disable_backend(self):
  with patch.dict(standalone.PHONE_OPTIONS,{'cache_mib':64,'zap_debounce_ms':250,'wasm_memory_ops':False}):
   args=standalone.phone_arguments();self.assertEqual(args[args.index('--cache-mib')+1],'64');self.assertEqual(args[args.index('--zap-debounce-ms')+1],'250');self.assertIn('--no-wasm-memory-ops',args)
