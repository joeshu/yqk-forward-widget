import http.server
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import threading
import unittest


@unittest.skipUnless(platform.system()=='Darwin','requires macOS Foundation')
class NativeRouteProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory();folder=Path(cls.tmp.name)
        driver=folder/'driver.m';cls.executable=folder/'probe'
        driver.write_text('''#import "HLSRouteProbe.h"
          int main(int argc,const char **argv){@autoreleasepool{__block BOOL finished=NO,plain=NO;__block int callbacks=0;
          HLSRouteProbe *probe=[HLSRouteProbe new];[probe startURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]] completion:^(BOOL value){callbacks++;plain=value;finished=YES;}];
          BOOL cancel=argc>2;if(cancel)[probe cancel];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:cancel?.3:10];
          while(!finished&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
          printf("{\\"plain\\":%s,\\"callbacks\\":%d}",plain?"true":"false",callbacks);[probe cancel];return (!cancel&&!finished)?2:0;}}''')
        root=Path(__file__).resolve().parents[1]
        result=subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-I',str(root/'Sources'),str(driver),str(root/'Sources/HLSRouteProbe.m'),'-o',str(cls.executable)],capture_output=True,text=True)
        if result.returncode:raise AssertionError(result.stderr)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def test_master_media_key_limits_and_cancel(self):
        requests=[]
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                requests.append(self.path)
                bodies={'/master':b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia\n',
                        '/media':b'#EXTM3U\n#EXTINF:4,\nseg.ts\n',
                        '/encrypted':b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:4,\nseg.ts\n',
                        '/html':b'<html>error</html>',
                        '/large':b'#EXTM3U\n'+b'#x\n'*100000,
                        '/loop':b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nloop\n'}
                body=bodies.get(self.path,b'not a playlist');self.send_response(200);self.end_headers()
                try:self.wfile.write(body)
                except (BrokenPipeError,ConnectionResetError):pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            for path,expected in [('/master',True),('/media',True),('/encrypted',False),('/html',False),('/large',False),('/loop',False)]:
                with self.subTest(path=path):
                    run=subprocess.run([str(self.executable),'http://127.0.0.1:%d%s'%(server.server_port,path)],capture_output=True,text=True,timeout=12)
                    self.assertEqual(run.returncode,0,run.stderr);reply=json.loads(run.stdout);self.assertEqual(reply,{'plain':expected,'callbacks':1})
            self.assertNotIn('/seg.ts',requests,'classification must not download media segments')
            run=subprocess.run([str(self.executable),'http://127.0.0.1:%d/media'%server.server_port,'cancel'],capture_output=True,text=True,timeout=3)
            self.assertEqual(json.loads(run.stdout)['callbacks'],0)
        finally:server.shutdown();server.server_close()
