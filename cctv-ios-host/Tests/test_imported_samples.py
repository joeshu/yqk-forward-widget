"""Opt-in integration checks against user-supplied original packages.

CCTVHOST_SAMPLE_DIR points to the attachment directory. No third-party source or
credentials are copied into the repository. Media fixtures prove the transport
contract, not availability or decoding of a remote source.
"""
import contextlib
import http.client
import http.server
import io
import importlib
import sys
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch
import zipfile

SAMPLES = os.environ.get('CCTVHOST_SAMPLE_DIR')


@unittest.skipUnless(SAMPLES, 'set CCTVHOST_SAMPLE_DIR to verify original attachments')
class ImportedSamples(unittest.TestCase):
    def sample(self, suffix):
        matches=list(Path(SAMPLES).glob('*'+suffix))
        self.assertEqual(len(matches),1,suffix)
        return matches[0]

    def test_original_spiders_reach_hls_segment_with_playback_headers(self):
        bridge=sys.modules.get('test_media_runtime') or importlib.import_module('Tests.test_media_runtime')
        observed=[]
        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                observed.append(dict(self.headers))
                body=b'#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n' if '.m3u8' in self.path else b'\x47'+b'\0'*187
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        upstream=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
        threading.Thread(target=upstream.serve_forever,daemon=True).start()
        try:
            for suffix in ('看剧AI.py','蝴蝶影院-广告去不干净-iOS版本.py'):
                with self.subTest(source=suffix),tempfile.TemporaryDirectory() as root:
                    shutil.copyfile(self.sample(suffix),Path(root)/'source.py')
                    with contextlib.redirect_stdout(io.StringIO()),patch('urllib.request.OpenerDirector.open',side_effect=urllib.error.URLError('offline fixture')):
                        engine=bridge.media.PythonSpider(root,'source.py')
                        # Join the finite original warmup before restoring network.
                        for worker in threading.enumerate():
                            if worker.name.endswith('(_warm)'):worker.join(1)
                    runtime=bridge.media.MediaRuntime(engine)
                    server=bridge.transport.Server(('127.0.0.1',0),runtime)
                    threading.Thread(target=server.serve_forever,daemon=True).start()
                    def request(url,body=None):
                        parts=urllib.parse.urlsplit(url);c=http.client.HTTPConnection(parts.hostname,parts.port,timeout=3)
                        try:
                            c.request('POST' if body else 'GET',parts.path+('?' + parts.query if parts.query else ''),json.dumps(body).encode() if body else None,{'Content-Type':'application/json'})
                            response=c.getresponse();self.assertEqual(response.status,200);return response.read()
                        finally:c.close()
                    try:
                        origin='http://127.0.0.1:%d'%server.server_port
                        reply=json.loads(request(origin+'/api/v1/play',{'id':'http://127.0.0.1:%d/live.m3u8'%upstream.server_port,'lineId':''}))
                        self.assertTrue(reply['ok'],reply)
                        manifest=request(reply['data']['url']).decode()
                        segment=next(line for line in manifest.splitlines() if line and not line.startswith('#'))
                        self.assertEqual(request(urllib.parse.urljoin(reply['data']['url'],segment))[0],0x47)
                        self.assertTrue(observed[-1].get('User-Agent'))
                        if '蝴蝶' in suffix:self.assertTrue(observed[-1].get('Referer'))
                    finally:server.shutdown();server.server_close();runtime.close()
        finally:upstream.shutdown();upstream.server_close()

    def test_original_widget_crypto_episode_and_hls_probe(self):
        script=r'''const fs=require('fs'),vm=require('vm'),assert=require('assert');let posts=0,segments=0;
          const title='CCTVHost测试',url='https://fixture.test/second.m3u8';
          const sandbox={console,URL,URLSearchParams,TextEncoder,TextDecoder,crypto:require('crypto').webcrypto,Widget:{http:{
            post:async(_url,body)=>{assert(body.length>20);return {statusCode:200,data:JSON.stringify(++posts===1?{code:1,data:[{vod_id:1,vod_name:title,type_id:2}]}:{code:1,data:{vod_info:{vod_id:1,vod_name:title,type_id:2,vod_url_with_player:[{name:'fixture',code:'direct',url:'第1集$https://fixture.test/first.m3u8#第2集$'+url,headers:{Referer:'https://fixture.test/'}}]}}})}},
            get:async(url,options)=>{if(url.endsWith('.ts')){segments++;const bytes=Buffer.alloc(188*6);for(let i=0;i<6;i++)bytes[i*188]=0x47;return {statusCode:206,headers:{'Content-Type':'video/mp2t'},data:bytes.toString('base64')}}return {statusCode:200,headers:{'Content-Type':'application/vnd.apple.mpegurl'},data:'#EXTM3U\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n'}}}}};
          vm.runInNewContext(fs.readFileSync(process.argv[1],'utf8'),sandbox,{timeout:2000});
          sandbox.loadResource({seriesName:title,season:1,episode:2}).then(rows=>{assert.equal(rows.length,1);assert.equal(rows[0].url,url);assert(segments>0);assert.equal(rows[0].headers.Referer,'https://fixture.test/');console.log('original Widget: encrypted request, episode 2 and HLS segment probe passed')}).catch(e=>{console.error(e);process.exitCode=1});'''
        result=subprocess.run([os.environ.get('CCTVHOST_NODE_BINARY','node'),'--jitless','-e',script,str(self.sample('cheyong-rex.js'))],capture_output=True,text=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)

    def test_original_catpaw_config_lifecycle_and_independent_peer(self):
        node_tests=sys.modules.get('test_node_media_host') or importlib.import_module('Tests.test_node_media_host')
        helper=node_tests.NodeMediaHostTests();helper.setUp()
        def call(operation,session='one',**args):
            c=http.client.HTTPConnection('127.0.0.1',helper.port,timeout=40)
            try:
                c.request('POST','/control',json.dumps({'operation':operation,'payload':dict(args,session=session)}),{'X-CCTVHost-Token':helper.token,'Content-Type':'application/json'})
                return json.loads(c.getresponse().read())
            finally:c.close()
        try:
            with zipfile.ZipFile(self.sample('猫源本地包0911.zip')) as archive:
                for name in ('index.js','index.config.js'):(helper.package/name).write_bytes(archive.read(name))
            (helper.package/'peer.cjs').write_text("exports.search=()=>({list:[{vod_id:'peer',vod_name:'independent'}]})")
            self.assertTrue(call('start',session='peer',packageRoot=str(helper.package),dataDirectory=str(helper.data),entry='peer.cjs',moduleType='commonjs',protocol='catvod-js')['ok'])
            for _ in range(2):
                result=call('start',packageRoot=str(helper.package),dataDirectory=str(helper.data),entry='index.js',configEntry='index.config.js',moduleType='commonjs',protocol='catpaw-http')
                self.assertTrue(result['ok'],result)
                providers=call('providers');self.assertTrue(providers['ok'],providers);self.assertGreater(len(providers['result']),0)
                self.assertTrue(call('stop')['ok'])
                self.assertTrue(call('search',session='peer',keyword='fixture')['ok'])
            self.assertTrue(call('stop',session='peer')['ok'])
        finally:helper.process.kill();helper.process.communicate(timeout=3);helper.tmp.cleanup()

    def test_original_live_http_services_list_and_stop_independently(self):
        lifecycle=sys.modules.get('test_service_runtime') or importlib.import_module('Tests.test_service_runtime')
        runtime=lifecycle.runtime
        sessions=[];workers=[];errors=[]
        with tempfile.TemporaryDirectory() as root:
            try:
                for index,suffix in enumerate(('cbox_live_plugin.py','ysp_live_plugin.py','ysp-live-v9.5.zip')):
                    folder=Path(root)/str(index);folder.mkdir();entry=folder/'source.py'
                    if suffix.endswith('.zip'):
                        with zipfile.ZipFile(self.sample(suffix)) as archive:entry.write_bytes(archive.read('ysp-live-v9.5/ysp-live-v9.5.py'))
                    else:shutil.copyfile(self.sample(suffix),entry)
                    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
                    args=([str(port),'--bind','127.0.0.1','--no-engine','--no-4k','--cache-mb','32','--data-dir',str(folder)] if suffix.endswith('.zip') else ['--port',str(port),'--bind','127.0.0.1']+(['--serve'] if suffix=='ysp_live_plugin.py' else []))
                    identifier='original-sample-'+str(index);sessions.append((identifier,port))
                    def run(path=entry,sid=identifier,argv=args,data=folder,p=port):
                        try:runtime.run_script(str(path),sid,str(data),p,argv)
                        except BaseException as error:errors.append(error)
                    worker=threading.Thread(target=run,daemon=True);workers.append(worker);worker.start()
                    deadline=time.monotonic()+8
                    while time.monotonic()<deadline:
                        state=runtime._sessions.get(identifier)
                        if state and state.servers and state.servers[0]._host_serving.is_set():break
                        time.sleep(.02)
                    self.assertTrue(state and state.servers and state.servers[0]._host_serving.is_set(),errors)
                    namespace=state.servers[0].RequestHandlerClass.do_GET.__globals__
                    if suffix=='cbox_live_plugin.py':namespace['_CATALOG'].update(ts=time.time(),items=[{'code':'cctv1','name':'fixture','group':'cctv','url':'https://fixture.test/live.m3u8'}])
                    if suffix=='ysp_live_plugin.py':namespace['epg_xml']=lambda:b''
                def playlist(port):
                    c=http.client.HTTPConnection('127.0.0.1',port,timeout=3)
                    try:c.request('GET','/all.m3u');response=c.getresponse();self.assertEqual(response.status,200);return response.read()
                    finally:c.close()
                for identifier,port in sessions:self.assertTrue(playlist(port).startswith(b'#EXTM3U'))
                first,port=sessions[0];self.assertTrue(runtime.stop_session(first,4),runtime.last_error(first))
                with self.assertRaises(OSError):socket.create_connection(('127.0.0.1',port),timeout=.2)
                for _,other in sessions[1:]:self.assertTrue(playlist(other).startswith(b'#EXTM3U'))
            finally:
                for identifier,_ in sessions:self.assertTrue(runtime.stop_session(identifier,5),runtime.last_error(identifier))
                for worker in workers:worker.join(1)
            self.assertEqual(errors,[])
