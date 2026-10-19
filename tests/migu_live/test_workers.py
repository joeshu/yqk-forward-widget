import socket
import subprocess
import sys
import tempfile
import pathlib
import time
import threading
import unittest
from migu.workers import BoundedExecutor
from migu import service as s, native as n, epg as e


class WorkersTests(unittest.TestCase):
    def test_queue_is_bounded_queued_work_cancelled_and_running_workers_are_daemons(self):
        started,release=threading.Event(),threading.Event()
        pool=BoundedExecutor(1,max_pending=1)
        try:
            def work():
                started.set(); release.wait(2); return 1
            first=pool.submit(work); self.assertTrue(started.wait(1))
            queued=pool.submit(lambda:2)
            with self.assertRaises(RuntimeError): pool.submit(lambda:3)
            self.assertTrue(all(t.daemon for t in pool.threads))
            pool.shutdown(wait=False)
            self.assertTrue(queued.cancelled())
            release.set(); self.assertEqual(first.result(2),1)
            with self.assertRaises(RuntimeError): pool.submit(lambda:4)
        finally: release.set(); pool.shutdown()

    def test_server_close_releases_incomplete_client_and_port_for_immediate_restart(self):
        service=s.Service(n.NativeStore(),'', 'http://127.0.0.1:0',require_token=False,epg=e.EpgStore(enabled=False))
        server=s.BoundedServer(('127.0.0.1',0),service)
        thread=threading.Thread(target=server.serve_forever,kwargs={'poll_interval':.01},daemon=True);thread.start()
        port=server.server_address[1]
        client=socket.create_connection(('127.0.0.1',port),timeout=1)
        client.sendall(b'GET /all.m3u HTTP/1.1\r\n')
        try:
            for _ in range(100):
                with server.connection_lock:
                    if server.connections: break
                time.sleep(.005)
            server.shutdown(); server.server_close(); thread.join(1)
            client.settimeout(1)
            try: self.assertEqual(client.recv(1),b'')
            except ConnectionResetError: pass
            replacement=s.BoundedServer(('127.0.0.1',port),service)
            replacement.server_close()
        finally: client.close(); server.server_close(); service.close()

    def test_stalled_background_work_does_not_keep_standalone_process_alive(self):
        script=pathlib.Path('migu-live.py').resolve()
        with tempfile.TemporaryDirectory() as directory:
            harness=pathlib.Path(directory)/'host.py'
            harness.write_text('''import runpy,sys,time
api=runpy.run_path(sys.argv[1],run_name="migu_embedded_library")
pool=api['BoundedExecutor'](1)
pool.submit(time.sleep,60)
print('background-started',flush=True)
pool.shutdown(wait=False)
''')
            process=subprocess.Popen([sys.executable,str(harness),str(script)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try: out,error=process.communicate(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill();process.communicate();self.fail('background job held process open')
            self.assertEqual(process.returncode,0,error)
            self.assertIn('background-started',out)
