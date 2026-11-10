from pathlib import Path
import os
import platform
import subprocess
import tempfile
import unittest
import threading
import time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

@unittest.skipUnless(platform.system() == 'Darwin','requires macOS Foundation')
class NativeImportAuditTests(unittest.TestCase):
    def build_run(self,name,sources,args=()):
        root=Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as tmp:
            exe=str(Path(tmp)/name)
            cmd=['xcrun','clang','-fobjc-arc','-framework','Foundation','-lz','-I',str(root/'Sources')]+[str(root/p) for p in sources]+['-o',exe]
            build=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            env=dict(os.environ,CFFIXED_USER_HOME=tmp)
            run=subprocess.run([exe,*args],env=env,capture_output=True,text=True,timeout=25)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
    def test_static_resource_page_inspection(self):
        self.build_run('resource-inspection',['Tests/native_resource_inspection_tests.m','Sources/ResourceContentInspection.m'])
    def test_concurrent_resource_storage_and_corrupt_defaults(self):
        self.build_run('store-concurrency',['Tests/native_store_concurrency_tests.m','Sources/ProfileStore.m','Sources/ServiceStore.m','Sources/TVBoxCatalogStore.m','Sources/MediaPlaybackStateStore.m'])

    def test_fetcher_is_bounded_and_cancellable(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                if self.path in ('/redirect','/loop'):
                    self.send_response(302);self.send_header('Location','/ok' if self.path=='/redirect' else '/loop');self.end_headers();return
                if self.path=='/slow':time.sleep(.3)
                self.send_response(200)
                data=b'resource' if self.path in ('/ok','/slow') else b'x'*(9*1024*1024)
                if self.path!='/stream-large':self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                try:self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError):pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler);worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        try:self.build_run('resource-fetcher',['Tests/native_resource_fetcher_tests.m','Sources/ResourceImportFetcher.m','Sources/HostSyncRequest.m'],[str(server.server_port)])
        finally:server.shutdown();server.server_close();worker.join()
