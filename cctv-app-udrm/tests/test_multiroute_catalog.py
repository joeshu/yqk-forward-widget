"""M3U routes must filter correctly without prefetching every CDN."""
import json,threading,unittest
from urllib.request import urlopen
from urllib.error import HTTPError
from test_bridge import service

class MultiRouteCatalogTests(unittest.TestCase):
 def test_provider_and_program_directories_are_lazy_and_isolated(self):
  channels=service.build_channels();live=service.LiveService({},channels)
  live.stopping.set();live.worker.join()
  http=service.ThreadingHTTPServer(('127.0.0.1',0),service.make_handler(live));thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  base='http://127.0.0.1:'+str(http.server_port)
  def read(path):
   with urlopen(base+path,timeout=2) as response:return response.read().decode()
  def ids(text):return [line.rsplit('/',1)[-1][:-5] for line in text.splitlines() if line.startswith('http://')]
  try:
   primary=ids(read('/all.m3u'));self.assertEqual(len(primary),len(set(primary)))
   self.assertTrue(all(channels[x].catalog for x in primary))
   lines=ids(read('/lines.m3u'));self.assertEqual(set(lines),set(channels));self.assertGreater(len(lines),len(primary))
   for provider in ['ws','bd','tx','ks']:
    chosen=ids(read('/providers/'+provider+'.m3u'));self.assertTrue(chosen)
    self.assertTrue(all(channels[x].provider==provider for x in chosen))
   for path in ['/cctv7.m3u','/lines/cctv7.m3u']:
    chosen=ids(read(path));self.assertGreaterEqual(len(chosen),2)
    self.assertTrue(all(channels[x].logical_id=='cctv7' for x in chosen))
   self.assertIn('tvg-id="cctv2"',read('/lines/cctv2.m3u'))
   self.assertIn('tvg-name="CCTV-7 国防军事"',read('/lines/cctv7.m3u'))
   self.assertIn('x-tvg-url="'+base+'/epg.xml.gz"',read('/all.m3u'))
   self.assertEqual(live.sdk.sessions,0);self.assertFalse(live.refresh_jobs)
   self.assertFalse(any(c.cache or c.raw for c in channels.values()))
   state=json.loads(read('/status'));self.assertEqual(state['program_count'],len(primary));self.assertEqual(state['route_count'],len(lines))
   for path in ['/providers/unknown.m3u','/lines/unknown.m3u']:
    with self.assertRaises(HTTPError) as caught:read(path)
    self.assertEqual(caught.exception.code,404)
  finally:http.shutdown();http.server_close();live.close()
 def test_route_state_tokens_and_default_existing_sources(self):
  channels=service.build_channels();same=[c for c in channels.values() if c.logical_id=='cctv7']
  entry=service.Entry(1,4,'https://example.test/same.ts')
  self.assertEqual(len({service.LiveService.token(c,entry) for c in same}),len(same))
  self.assertEqual(channels['cctv7'].provider,'ws');self.assertEqual(channels['cctv1'].provider,'bd');self.assertEqual(channels['guizhou'].provider,'tx')
  for c in same:
   self.assertIsNot(c.cache,channels['cctv1'].cache);self.assertIsNot(c.lock,channels['cctv1'].lock)

if __name__=='__main__':unittest.main()
