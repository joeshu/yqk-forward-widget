"""Real HTTP framing plus HTTPS/proxy policy checks, with no external I/O."""
import concurrent.futures
from email.message import Message
import http.client
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import threading
import time
import unittest
from unittest import mock
from urllib.request import ProxyHandler
from test_service import service


class CountingServer(ThreadingHTTPServer):
    daemon_threads=True
    def __init__(self,*args):
        self.accepts=0
        super().__init__(*args)
    def get_request(self):
        value=super().get_request();self.accepts+=1;return value


class Upstream(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):
        if self.path=='/forbidden':code,body=403,b'no'
        elif self.path=='/redirect':code,body=302,b'redirect'
        elif self.path=='/bad-redirect':code,body=302,b'redirect'
        elif self.path=='/chunked':
            self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.end_headers()
            self.wfile.write(b'3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n');self.wfile.flush();return
        elif self.path=='/truncated':
            self.send_response(200);self.send_header('Content-Length','9');self.end_headers()
            self.wfile.write(b'abc');self.wfile.flush();self.close_connection=True;return
        else:code,body=200,(self.path+'|'+self.headers.get('auth-key','')).encode()
        self.send_response(code)
        self.send_header('Content-Length',str(len(body)))
        if self.path=='/redirect':self.send_header('Location','https://media.cntv.cn/final')
        if self.path=='/bad-redirect':self.send_header('Location','https://untrusted.example/private?token=secret')
        if self.path=='/close':self.send_header('Connection','close')
        self.end_headers();self.wfile.write(body);self.wfile.flush()
        if self.path in ('/close','/stale'):self.close_connection=True


class TestHTTPFraming(unittest.TestCase):
    def setUp(self):
        self.server=CountingServer(('127.0.0.1',0),Upstream)
        self.thread=threading.Thread(target=lambda:self.server.serve_forever(poll_interval=.01),daemon=True)
        self.thread.start()
        self.pool=service.HTTPSConnectionPool()
        self.patches=[mock.patch.object(service,'_HTTP_POOL',self.pool),
                      mock.patch.object(service,'_HTTP_REUSE_ENABLED',True),
                      mock.patch.object(service,'HTTPSConnection',side_effect=lambda host,timeout,context:
                          http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=timeout))]
        original=service.build_opener
        self.patches.append(mock.patch.object(service,'build_opener',side_effect=lambda *handlers:
            original(ProxyHandler({}),*handlers)))
        for p in self.patches:p.start()
    def tearDown(self):
        self.pool.clear();self.server.shutdown();self.server.server_close();self.thread.join(2)
        for p in reversed(self.patches):p.stop()
    def get(self,path,**kwargs):return service.get('https://media.cntv.cn'+path,**kwargs)

    def test_complete_bodies_reuse_one_connection_with_fresh_request_headers(self):
        self.assertEqual(self.get('/first',headers={'auth-key':'one'})[0],b'/first|one')
        self.assertEqual(self.get('/second',headers={'auth-key':'two'})[0],b'/second|two')
        self.assertEqual(self.server.accepts,1);self.assertEqual(self.pool.reused,1)

    def test_explicit_close_header_is_honored(self):
        self.get('/first',headers={'Connection':'close'})
        self.assertEqual(len(self.pool.idle),0)
        self.get('/next');self.assertEqual(self.server.accepts,2)

    def test_chunked_response_is_fully_consumed_before_reuse(self):
        self.assertEqual(self.get('/chunked')[0],b'abcde')
        self.assertEqual(self.get('/next')[0],b'/next|')
        self.assertEqual(self.server.accepts,1)

    def test_response_close_and_unread_oversized_body_are_discarded(self):
        self.get('/close');self.get('/next')
        self.assertEqual(self.server.accepts,2)
        with self.assertRaisesRegex(service.NativeError,'response-too-large'):self.get('/long-enough',limit=1)
        self.get('/third');self.assertEqual(self.server.accepts,3)

    def test_truncated_body_is_transport_failure_and_never_reused(self):
        with self.assertRaises(service.IncompleteRead):self.get('/truncated')
        self.get('/next');self.assertEqual(self.server.accepts,2)

    def test_stale_idle_socket_retries_once_on_fresh_connection(self):
        self.get('/stale');self.get('/next')
        self.assertEqual(self.server.accepts,2);self.assertEqual(self.pool.stale_retries,1)

    def test_redirect_is_validated_and_does_not_pool_an_unread_denied_response(self):
        self.assertEqual(self.get('/redirect')[1],'https://media.cntv.cn/final')
        self.assertEqual(self.server.accepts,1)
        with self.assertRaises(service.UnsupportedSource):self.get('/bad-redirect')
        self.get('/next');self.assertEqual(self.server.accepts,2)

    def test_http_rejection_closes_checked_out_connection(self):
        with self.assertRaises(service.HTTPError):self.get('/forbidden')
        self.assertEqual(len(self.pool.idle),0)
        self.get('/next');self.assertEqual(self.server.accepts,2)

    def test_concurrent_requests_do_not_share_a_checked_out_socket(self):
        def get(i):return self.get('/'+str(i),headers={'auth-key':str(i)})[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            values=list(pool.map(get,range(9)))
        self.assertEqual(values,[('/'+str(i)+'|'+str(i)).encode() for i in range(9)])
        self.assertGreaterEqual(self.server.accepts,2)
        self.assertLessEqual(self.server.accepts,3)


class TestPoolPolicy(unittest.TestCase):
    def test_idle_ttl_and_capacity_close_expired_or_evicted_connections(self):
        pool=service.HTTPSConnectionPool(max_idle=1,idle_seconds=15)
        first,second=mock.Mock(),mock.Mock()
        with mock.patch.object(service.time,'monotonic',return_value=1):
            pool.put('first',first);pool.put('second',second)
        first.close.assert_called_once()
        created=mock.Mock()
        with mock.patch.object(service.time,'monotonic',return_value=17):
            self.assertEqual(pool.take('second',lambda:created),(created,False))
        second.close.assert_called_once()

    def test_proxy_tls_mode_and_tunnel_destination_are_isolated(self):
        pool=service.HTTPSConnectionPool();connections=[]
        def create(host,timeout,context):
            conn=mock.Mock();response=mock.Mock(status=200,reason='OK',will_close=False,length=0)
            response.headers=Message();response.isclosed.return_value=True
            conn.getresponse.return_value=response;connections.append((host,context,conn));return conn
        default=service.source_tls_context();tls12=service.source_tls_context(True)
        def request(host,context,auth):
            req=service.Request('https://'+host+'/a',headers={'Proxy-Authorization':auth,'auth-key':'private-origin'})
            req.set_proxy('proxy.local:8080','http');req.timeout=4
            service.PooledHTTPSHandler(context=context).https_open(req).close()
        with mock.patch.object(service,'_HTTP_POOL',pool),mock.patch.object(service,'HTTPSConnection',side_effect=create):
            request('media.cntv.cn',default,'first-proxy')
            request('media.cntv.cn',default,'first-proxy')
            request('media.cntv.cn',default,'second-proxy')
            request('other.cntv.cn',default,'first-proxy')
            request('media.cntv.cn',tls12,'first-proxy')
        self.assertEqual(len(connections),4);self.assertEqual(pool.reused,1)
        for host,context,conn in connections:
            self.assertEqual(host,'proxy.local:8080')
            self.assertNotIn('Proxy-Authorization',conn.request.call_args.args[3])
            self.assertEqual(context.verify_mode,service.ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
        connections[0][2].set_tunnel.assert_called_once_with('media.cntv.cn',headers={'Proxy-Authorization':'first-proxy'})
        pool.clear()

    def test_certificate_failure_is_not_retried_as_a_stale_connection(self):
        pool=service.HTTPSConnectionPool();conn=mock.Mock()
        conn.request.side_effect=service.ssl.SSLCertVerificationError(1,'private certificate details')
        req=service.Request('https://media.cntv.cn/a');req.timeout=3
        with mock.patch.object(service,'_HTTP_POOL',pool),mock.patch.object(service,'HTTPSConnection',return_value=conn) as create:
            with self.assertRaises(service.URLError) as failure:
                service.PooledHTTPSHandler(context=service.source_tls_context()).https_open(req)
        self.assertIsInstance(failure.exception.reason,service.ssl.SSLCertVerificationError)
        self.assertEqual(create.call_count,1);self.assertEqual(pool.stale_retries,0)
        conn.close.assert_called_once()

    def test_tls_contexts_are_reused_but_api_legacy_policy_is_separate(self):
        self.assertIs(service.source_tls_context(),service.source_tls_context())
        self.assertIsNot(service.source_tls_context(),service.source_tls_context(True))
        self.assertFalse(service.source_tls_context().options & getattr(service.ssl,'OP_LEGACY_SERVER_CONNECT',0))

    def test_explicit_opt_out_keeps_original_urllib_path(self):
        response=mock.MagicMock();response.__enter__.return_value=response
        response.url='https://media.cntv.cn/a';response.read.return_value=b'abc'
        opener=mock.Mock();opener.open.return_value=response
        with mock.patch.object(service,'_HTTP_REUSE_ENABLED',False), \
             mock.patch.object(service,'build_opener',return_value=opener) as build:
            self.assertEqual(service.get(response.url)[0],b'abc')
        self.assertEqual(len(build.call_args.args),1)
