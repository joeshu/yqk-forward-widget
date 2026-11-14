from pathlib import Path
import platform
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

@unittest.skipUnless(platform.system()=='Darwin','requires macOS Foundation URLSession')
class NativeMediaKeyTests(unittest.TestCase):
    def test_bounded_cancellable_key_transport(self):
        seen=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                seen.append((self.server.server_port,self.path,{name.lower():value for name,value in self.headers.items()}))
                if self.path in ('/same','/loop'):
                    self.send_response(302);self.send_header('Location','/same-key' if self.path=='/same' else '/loop');self.send_header('Content-Length','0');self.end_headers();return
                if self.path=='/redirect':
                    self.send_response(302);self.send_header('Location',f'http://127.0.0.1:{second.server_port}/key');self.send_header('Content-Length','0');self.end_headers();return
                body=b'0123456789abcdef' if self.path!='/large' else b'x'*4097
                self.send_response(403 if self.path=='/denied' else 200);self.send_header('Content-Length',str(len(body)));self.end_headers()
                try:self.wfile.write(body)
                except (BrokenPipeError,ConnectionResetError):pass
        first=ThreadingHTTPServer(('127.0.0.1',0),Handler);second=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threads=[threading.Thread(target=server.serve_forever,daemon=True) for server in (first,second)]
        for thread in threads:thread.start()
        root=Path(__file__).resolve().parents[1]
        try:
            with tempfile.TemporaryDirectory() as directory:
                exe=str(Path(directory)/'keys')
                build=subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-I',str(root/'Sources'),str(root/'Sources/MediaKeyRequest.m'),str(root/'Sources/MediaPlaybackHeaders.m'),str(root/'Tests/native_media_key_tests.m'),'-o',exe],capture_output=True,text=True)
                self.assertEqual(build.returncode,0,build.stdout+build.stderr)
                run=subprocess.run([exe,f'http://127.0.0.1:{first.server_port}'],capture_output=True,text=True,timeout=30);self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                redirected=[headers for port,path,headers in seen if port==second.server_port]
                self.assertTrue(redirected)
                for headers in redirected:
                    for name in ('authorization','x-api-key','x-auth','x-session','referer','origin'):
                        self.assertNotIn(name,headers)
                same=[headers for port,path,headers in seen if path=='/same-key']
                self.assertTrue(same)
                self.assertEqual(same[0].get('x-api-key'),'private')
                self.assertLessEqual(sum(path=='/loop' for _,path,_ in seen),6)
        finally:
            for server in (first,second):server.shutdown();server.server_close()
            for thread in threads:thread.join()
