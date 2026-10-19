import contextlib
import http.server
import io
import json
import os
from pathlib import Path
import select
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
from test_gateway import g, ROOT, URL

PUBLIC = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('8.8.8.8', 443))]

class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cls.cert, key = root/'cert.pem', root/'key.pem'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cls.cert),'-days','1','-subj','/CN=cdn.cctv.cn','-addext','subjectAltName=DNS:cdn.cctv.cn,DNS:player-api.yangshipin.cn,DNS:h5access.yangshipin.cn'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        cls.origin_requests, cls.proxy_requests, cls.api_requests = [], [], []
        class Origin(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                cls.origin_requests.append(dict(self.headers))
                cls.api_requests.append(('GET', self.path))
                if self.path.startswith('/web/open/token'):
                    body=json.dumps({'data':{'token':'test-open','ts':'1234567890'}}).encode()
                elif self.path == '/live.m3u8':
                    body=b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\na.ts\n'
                else:body=b'payload'
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                cls.api_requests.append(('POST',self.path))
                data={'token':'test-auth','ts':1234567890} if self.path.endswith('/auth') else {'playurl':'https://cdn.cctv.cn/live.m3u8'}
                body=json.dumps({'data':data}).encode()
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        cls.origin = http.server.ThreadingHTTPServer(('127.0.0.1',0),Origin)
        cls.origin.daemon_threads = True
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(str(cls.cert),str(key))
        cls.origin.socket = ctx.wrap_socket(cls.origin.socket,server_side=True)
        class Forward(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                cls.proxy_requests.append((self.command,self.path,dict(self.headers)))
                self.send_response(200);self.send_header('Content-Length','7');self.end_headers();self.wfile.write(b'payload')
            def do_CONNECT(self):
                cls.proxy_requests.append((self.command,self.path,dict(self.headers)))
                upstream = socket.create_connection(cls.origin.server_address,timeout=3)
                self.send_response(200);self.end_headers()
                self.connection.settimeout(3);upstream.settimeout(3)
                try:
                    while True:
                        readers,_,_ = select.select([self.connection,upstream],[],[],3)
                        if not readers: return
                        for reader in readers:
                            chunk=reader.recv(65536)
                            if not chunk:return
                            (upstream if reader is self.connection else self.connection).sendall(chunk)
                except OSError: pass
                finally:upstream.close()
        cls.proxy = http.server.ThreadingHTTPServer(('127.0.0.1',0),Forward)
        cls.proxy.daemon_threads = True
        cls.proxy_url = f'http://user:secret@127.0.0.1:{cls.proxy.server_address[1]}'
        for server in [cls.origin,cls.proxy]:
            threading.Thread(target=server.serve_forever,daemon=True).start()
    @classmethod
    def tearDownClass(cls):
        for server in [cls.proxy,cls.origin]:server.shutdown();server.server_close()
        cls.temp.cleanup()
    def env(self):
        return {'http_proxy':self.proxy_url,'HTTP_PROXY':self.proxy_url,'https_proxy':self.proxy_url,'HTTPS_PROXY':self.proxy_url,'no_proxy':'','NO_PROXY':'','YSP_DIRECT':'0','SSL_CERT_FILE':str(self.cert)}
    def test_python_http_forward_proxy_and_auth(self):
        with patch.dict(os.environ,self.env()), patch.object(g,'_proxy_addresses',return_value=PUBLIC):
            with g.open_proxy_upstream('http://cdn.cctv.cn/segment.ts') as response:
                self.assertEqual(response.read(),b'payload')
        method,path,headers=self.proxy_requests[-1]
        self.assertEqual(method,'GET');self.assertEqual(path,'http://cdn.cctv.cn/segment.ts')
        self.assertIn('Proxy-Authorization',headers)
    def test_python_https_connect_tls_and_auth_isolation(self):
        with patch.dict(os.environ,self.env()),patch.object(g,'_proxy_addresses',return_value=PUBLIC):
            with g.open_proxy_upstream('https://cdn.cctv.cn/segment.ts') as response:
                self.assertEqual(response.read(),b'payload')
        self.assertEqual(self.proxy_requests[-1][:2],('CONNECT','cdn.cctv.cn:443'))
        self.assertIn('Proxy-Authorization',self.proxy_requests[-1][2])
        self.assertNotIn('Proxy-Authorization',self.origin_requests[-1])
    @unittest.skipUnless(shutil.which('node'),'Node.js required')
    def test_node_coalesces_resolution_and_reuses_auth_on_playlist_refresh(self):
        env={**os.environ,**self.env(),'NODE_EXTRA_CA_CERTS':str(self.cert)}
        before=len(self.api_requests)
        source="""
const engine = require(process.argv[1]);
(async () => {
 const first = await Promise.all([engine.resolveChannelLive('cctv1'), engine.resolveChannelLive('cctv1')]);
 await new Promise(resolve => setTimeout(resolve, 3200));
 const refreshed = await engine.resolveChannelLive('cctv1');
 console.log(JSON.stringify({ same: first[0] === first[1], hls: refreshed.startsWith('#EXTM3U') }));
 process.exit(0);
})().catch(error => {console.error(error.name);process.exit(1);});
"""
        result=subprocess.run(['node','-e',source,str(ROOT/'ysp-engine.js')],env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout),{'same':True,'hls':True})
        requests=self.api_requests[before:]
        self.assertEqual(requests.count(('POST','/v1/player/auth')),1)
        self.assertEqual(requests.count(('POST','/v1/player/get_live_info')),1)
        self.assertEqual(requests.count(('GET','/live.m3u8')),2)

    def test_private_dns_rejected_before_using_proxy(self):
        private=[(socket.AF_INET,socket.SOCK_STREAM,6,'',('127.0.0.1',443))]
        before=len(self.proxy_requests)
        with patch.dict(os.environ,self.env()),patch.object(g.socket,'getaddrinfo',return_value=private),self.assertRaises(g.YsptpError):
            with g.open_proxy_upstream(URL):pass
        self.assertEqual(len(self.proxy_requests),before)
    def test_no_proxy_loopback_and_direct_mode(self):
        with patch.dict(os.environ,self.env()):
            self.assertIsNone(g.configured_proxy('http://127.0.0.1:8787/segment'))
            with patch.dict(os.environ,{'NO_PROXY':'.cctv.cn','no_proxy':'.cctv.cn'}):
                self.assertIsNone(g.configured_proxy(URL))
            with patch.dict(os.environ,{'YSP_DIRECT':'1'}):self.assertIsNone(g.configured_proxy(URL))
    @unittest.skipUnless(shutil.which('node'),'Node.js required')
    def test_node_http_proxy_and_verified_https_tunnel(self):
        env={**os.environ,**self.env(),'NODE_EXTRA_CA_CERTS':str(self.cert)}
        source="""
const engine = require(process.argv[1]);
(async () => {
 const http = await engine.httpGet('http://cdn.cctv.cn/control');
 const https = await engine.httpGet('https://cdn.cctv.cn/control');
 console.log(JSON.stringify([http.data, https.data]));
 process.exit(0);
})().catch(error => {console.error(error.name);process.exit(1);});
"""
        result=subprocess.run(['node','-e',source,str(ROOT/'ysp-engine.js')],env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout),['payload','payload'])
        self.assertNotIn('Proxy-Authorization',self.origin_requests[-1])

class RecoveryTests(unittest.TestCase):
    def test_transient_read_only_request_retries_once(self):
        expected=io.BytesIO(b'ok')
        with patch.object(g.urllib.request,'urlopen',side_effect=[g.http.client.RemoteDisconnected(),expected]) as request,patch.object(g.time,'sleep'):
            self.assertIs(g.open_readonly_request('https://example.com'),expected)
            self.assertEqual(request.call_count,2)
    def test_http_400_is_not_retried(self):
        error=g.urllib.error.HTTPError(URL,400,'Bad request',{},None)
        with patch.object(g.urllib.request,'urlopen',side_effect=error) as request,self.assertRaises(g.urllib.error.HTTPError):
            g.open_readonly_request(URL)
        self.assertEqual(request.call_count,1)
    def test_jce_disconnect_uses_bk_and_recovery_returns_to_jce(self):
        channel=g.Channel('hnws','test','0','0','fhd')
        with patch.object(g,'jce_refresh',side_effect=g.http.client.RemoteDisconnected()),patch.object(g,'bk_refresh',return_value=True) as bk,patch.object(g,'log'):
            self.assertTrue(g.refresh_once(channel));self.assertEqual(channel.mode,'bk');bk.assert_called_once()
        channel.primary_retry_at=0
        with patch.object(g,'jce_refresh',return_value=True) as jce,patch.object(g,'bk_refresh') as bk:
            self.assertTrue(g.refresh_once(channel));self.assertEqual(channel.mode,'jce');jce.assert_called_once();bk.assert_not_called()
    def test_channel_400_does_not_rotate_device(self):
        import argparse
        args=argparse.Namespace(timeout=1,insecure_tls=False,meta_json='/nonexistent/ysp-review-cache',stale_while_refresh_ttl=0,identity_reset_error_threshold=0)
        resolver=g.Resolver(args)
        with patch.object(resolver,'refresh_channel_controlled',side_effect=g.YsptpError('live/v1/01 HTTP 400')),patch.object(resolver,'write_meta'),patch.object(resolver,'rotate_device_on_400') as rotate,self.assertRaises(g.YsptpError):
            resolver.ensure_channel('cctv4k',force=True)
        rotate.assert_not_called()
        self.assertEqual(resolver.state.channel_failures['cctv4k'][2],1)
    def test_discontinuity_sequence_does_not_hide_switch_marker(self):
        playlist='#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:2\n#EXTINF:6,\nhttps://cdn.cctv.cn/a.ts\n'
        result=g.inject_hls_discontinuity(playlist)
        self.assertIn('\n#EXT-X-DISCONTINUITY\n#EXTINF:',result)

    def test_fallback_media_and_key_urls_use_signed_gateway(self):
        playlist='#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.cctv.cn/key"\n#EXTINF:6,\nhttps://cdn.cctv.cn/a.ts\n'
        rewritten=g.gateway_playlist_urls(playlist,'localhost:8767')
        self.assertEqual(rewritten.count('/engine_proxy?token='),2)
        segment=rewritten.splitlines()[-1]
        token=g.urllib.parse.parse_qs(g.urllib.parse.urlsplit(segment).query)['token'][0]
        self.assertEqual(g.decode_proxy_ts_url(token,True),'https://cdn.cctv.cn/a.ts')

if __name__=='__main__':unittest.main()
