import socket,threading,time,unittest
from concurrent.futures import Future
from unittest.mock import patch
from test_bridge import service
class ResourceLimitTests(unittest.TestCase):
 def test_saturated_http_is_rejected_and_capacity_recovers(self):
  release=threading.Event();entered=threading.Event()
  class Handler(service.BaseHTTPRequestHandler):
   def do_GET(self):
    entered.set();release.wait(2);self.send_response(200);self.send_header('Content-Length','0');self.end_headers()
   def log_message(self,*args):pass
  server=service.ThreadingHTTPServer(('127.0.0.1',0),Handler,max_clients=1)
  thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start();first=socket.create_connection(server.server_address,timeout=2)
  try:
   first.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n');self.assertTrue(entered.wait(1))
   with socket.create_connection(server.server_address,timeout=2) as second:
    second.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n');self.assertIn(b'503 Service Unavailable',second.recv(1024))
   state=server.resource_status();self.assertEqual(state['active_clients'],1);self.assertEqual(state['rejected_total'],1)
   release.set();self.assertIn(b'200 OK',first.recv(1024))
   for _ in range(50):
    if server.resource_status()['active_clients']==0:break
    time.sleep(.01)
   self.assertEqual(server.resource_status()['active_clients'],0)
   with socket.create_connection(server.server_address,timeout=2) as third:
    third.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n');self.assertIn(b'200 OK',third.recv(1024))
  finally:release.set();first.close();server.shutdown();server.server_close();thread.join()
 def test_obsolete_queue_is_cancelled_and_duplicate_refresh_coalesces(self):
  channels={i:service.Channel(i,i,'https://example.test') for i in ['a','b']}
  live=service.LiveService({},channels);live.stopping.set();live.worker.join()
  queued=Future();running=Future();running.set_running_or_notify_cancel();done=Future();done.set_result(None)
  try:
   live.refresh_jobs={'a':queued,'finished':done};live.active_channel='b';live.stopping.clear()
   with patch.object(live.refresh_pool,'submit',return_value=running) as submit:
    live._schedule(channels['b']);live._schedule(channels['b']);live._schedule(channels['a'])
    self.assertTrue(queued.cancelled());self.assertEqual(live.refresh_cancelled,1);submit.assert_called_once();self.assertEqual(set(live.refresh_jobs),{'b'})
  finally:live.refresh_jobs.clear();live.close()
