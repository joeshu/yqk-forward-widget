from contextlib import closing
import http.client
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

from migu import build_service
from test_service import catalogue


class ReleaseTests(unittest.TestCase):
    def test_release_is_reproducible_and_matches_current_sources(self):
        script, manifest = build_service.build()
        self.assertEqual(script, build_service.build()[0])
        self.assertEqual(script, Path('migu/migu-live-v0.2.0.py').read_bytes())
        self.assertEqual(manifest, Path('migu/migu-live-v0.2.0.json').read_bytes())
        self.assertNotIn(b'import update_migu',script)
        self.assertNotIn(b'from migu.probe',script)

    def test_single_python_file_runs_in_an_empty_directory_and_shuts_down(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            script=root/'migu-live.py'
            shutil.copyfile('migu/migu-live-v0.2.0.py',script)
            source=root/'fixture.txt'
            source.write_bytes(catalogue())
            with closing(socket.socket()) as reserve:
                reserve.bind(('127.0.0.1',0))
                port=reserve.getsockname()[1]
            process=subprocess.Popen([sys.executable,str(script),str(port),'--input',str(source),'--min-channels','1','--data-dir',str(root/'private')],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            body=None
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        self.fail('Standalone server exited: '+process.communicate()[1])
                    try:
                        client=http.client.HTTPConnection('127.0.0.1',port,timeout=1)
                        client.request('GET','/all.m3u')
                        response=client.getresponse()
                        data=response.read()
                        client.close()
                        if response.status==200:
                            body=data
                            break
                    except OSError:
                        pass
                    time.sleep(0.02)
                self.assertIsNotNone(body)
                self.assertIn(f'http://127.0.0.1:{port}/live/p100.m3u8'.encode(),body)
                self.assertNotIn(b'token=',body)
                self.assertFalse((root/'private'/'access.token').exists())
            finally:
                process.terminate()
                try:
                    out,error=process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    raise
            self.assertEqual(process.returncode,0,error)
            self.assertIn(f'http://127.0.0.1:{port}/all.m3u',out)


    def test_native_standalone_serves_builtin_channels_from_readonly_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            script=root/'migu-live.py'
            shutil.copyfile('migu/migu-live-v0.2.0.py',script)
            readonly=root/'readonly'; readonly.mkdir(); readonly.chmod(0o500)
            with closing(socket.socket()) as reserve:
                reserve.bind(('127.0.0.1',0)); port=reserve.getsockname()[1]
            process=subprocess.Popen([sys.executable,str(script),str(port)],cwd=readonly,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                for _ in range(100):
                    if process.poll() is not None: self.fail(process.communicate()[1])
                    try:
                        client=http.client.HTTPConnection('127.0.0.1',port,timeout=1)
                        client.request('GET','/all.m3u'); response=client.getresponse(); body=response.read(); client.close()
                        self.assertEqual(response.status,200)
                        self.assertIn(b'/live/p608807420.m3u8',body)
                        self.assertGreater(body.count(b'#EXTINF:'),100)
                        self.assertEqual(list(readonly.iterdir()),[])
                        break
                    except OSError: time.sleep(0.02)
                else: self.fail('native server did not start')
            finally:
                process.terminate()
                try: out,error=process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.communicate(); raise
                finally: readonly.chmod(0o700)
            self.assertEqual(process.returncode,0,error)
            self.assertIn('provider=official-api',out)


if __name__=='__main__':
    unittest.main()
