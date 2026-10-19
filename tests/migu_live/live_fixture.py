from contextlib import contextmanager
import http.client
import threading
from unittest.mock import Mock
from migu import native as n, service as s

TOKEN='t'*43

@contextmanager
def server(self, require_token=False, mode='redirect', epg=None, resolver=None):
    store=n.NativeStore(resolver=resolver or Mock(return_value='http://gslbmgsplive.miguvideo.com/live/index.m3u8?ddCalcu=x'))
    service=s.Service(store,TOKEN,'http://127.0.0.1:0',mode,require_token=require_token,epg=epg)
    host=s.BoundedServer(('127.0.0.1',0),service)
    service.public_base=f'http://127.0.0.1:{host.server_address[1]}'
    thread=threading.Thread(target=host.serve_forever,kwargs={'poll_interval':.01},daemon=True); thread.start()
    try: yield host,service
    finally:
        host.shutdown(); host.server_close(); service.close(); thread.join(2)

def request(self, server, path, method='GET', headers=None):
    client=http.client.HTTPConnection('127.0.0.1',server.server_address[1],timeout=8)
    try:
        client.request(method,path,headers=headers or {})
        response=client.getresponse()
        return response.status,dict(response.getheaders()),response.read()
    finally: client.close()
