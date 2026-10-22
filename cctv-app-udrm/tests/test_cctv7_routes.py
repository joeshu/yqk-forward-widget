"""Backup CDN routes keep independent upstream identities and SDK channels."""
import threading
import unittest
from urllib.request import urlopen
from test_bridge import service

class CCTV7RouteTests(unittest.TestCase):
 def test_main_and_backup_catalogs_are_separate_and_do_not_fetch_media(self):
  channels={key:service.Channel(key,name,url) for key,(name,url) in service.DEFAULTS.items()}
  channels.update({key:service.Channel(key,name,url,catalog=False) for key,(name,url) in service.CCTV7_ALTERNATES.items()})
  live=service.LiveService({},channels);live.stopping.set();live.worker.join()
  http=service.ThreadingHTTPServer(('127.0.0.1',0),service.make_handler(live));thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
  base='http://127.0.0.1:'+str(http.server_port)
  try:
   with urlopen(base+'/all.m3u') as r:main=r.read().decode()
   with urlopen(base+'/cctv7.m3u') as r:backup=r.read().decode()
   self.assertEqual(main.count('#EXTINF'),len(service.DEFAULTS));self.assertNotIn('cctv7_bd.m3u8',main)
   self.assertEqual(backup.count('#EXTINF'),1+len(service.CCTV7_ALTERNATES));self.assertNotIn('cctv1.m3u8',backup)
   for ident in ['cctv7','cctv7_bd','cctv7_ks']:self.assertIn('/live/'+ident+'.m3u8',backup)
   self.assertEqual(live.sdk.sessions,0)
   entry=service.Entry(1,4,'https://example.test/1.ts')
   self.assertEqual(len({live.token(channels[k],entry) for k in ['cctv7','cctv7_bd','cctv7_ks']}),3)
   self.assertIn('wscdns.com',channels['cctv7'].url)
  finally:http.shutdown();http.server_close();live.close()

if __name__=='__main__':unittest.main()
