import http.client
import http.server
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

HOST = Path(__file__).resolve().parents[1] / 'Plugins/node-plugin-host.cjs'


@unittest.skipUnless(shutil.which('node'), 'requires Node for host protocol fixture')
class NodeMediaHostTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.packages = self.root / 'Services'
        self.packages.mkdir()
        self.package = self.packages / 'fixture'
        self.package.mkdir()
        self.data = self.packages / 'data'
        self.data.mkdir()
        self.info = self.root / 'control.json'
        self.token = 'test-token-' + os.urandom(8).hex()
        environment = {key: os.environ[key] for key in ('PATH', 'LANG', 'TMPDIR') if key in os.environ}
        environment['CCTVHOST_TEST_DIAGNOSTICS'] = '1'
        node = os.environ.get('CCTVHOST_NODE_BINARY', shutil.which('node'))
        version = subprocess.check_output([node, '--version'], text=True).strip()
        if environment.get('CCTVHOST_TEST_DIAGNOSTICS') == '1':
            print(f'[Node host test] {version}; WebAssembly={subprocess.check_output([node, "--jitless", "-p", "typeof WebAssembly"], text=True).strip()}')
        # Match iOS Mobile's disabled JIT/WebAssembly rather than desktop defaults.
        self.process = subprocess.Popen([node, '--jitless', str(HOST), str(self.info), self.token, str(self.packages)], env=environment,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 8
        while not self.info.exists() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail('Node host exited: ' + self.process.stderr.read().decode())
            time.sleep(.02)
        self.assertTrue(self.info.exists(), 'Node control listener started')
        self.port = json.loads(self.info.read_text())['port']

    def tearDown(self):
        self.process.terminate()
        self.process.communicate(timeout=5)
        self.tmp.cleanup()

    def call(self, operation, session='one', **args):
        client = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            body = json.dumps({'operation': operation, 'payload': dict(args, session=session)})
            client.request('POST', '/control', body, {'X-CCTVHost-Token': self.token, 'Content-Type': 'application/json'})
            response = client.getresponse()
            return json.loads(response.read())
        finally:
            client.close()

    def start(self, **extra):
        return self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.cjs',
                         protocol='catvod-js', moduleType='commonjs', **extra)

    def test_catpaw_defaults_config_exports_provider_identity_and_relative_media(self):
        source = """const http=require('http');let server,switched=false;
          exports.start=async function(config={marker:'defaults'}){
            if(!['defaults','sidecar'].includes(config.marker))throw Error('default configuration was overwritten');
            if(config.marker==='sidecar'&&(config.nested.keep!=='value'||config.nested.override!==2))throw Error('partial override discarded source configuration');
            server=catServerFactory((req,res)=>{let value;
              if(req.url==='/website'){res.setHeader('Content-Type','text/html');res.end('<html>configuration</html>');return}
              if(req.url==='/switch'){switched=true;value={ok:true}}
              else if(req.url==='/config')value={video:{sites:[{key:switched?'second':'first',name:config.marker,api:'/spider/demo/3',searchable:switched?0:1},{key:'unsafe',api:'//elsewhere.test/spider/x'}]}};
              else if(req.url.endsWith('/home'))value={class:[{type_id:'movie',type_name:'Movie'}]};
              else if(req.url.endsWith('/homeVod')){res.writeHead(404);res.end();return}
              else if(req.url.endsWith('/detail')){let data='';req.on('data',chunk=>data+=chunk);req.on('end',()=>{const input=JSON.parse(data);res.setHeader('Content-Type','application/json');res.end(JSON.stringify({list:input.id?[{vod_id:input.id,vod_name:'detail'}]:[]}))});return}
              else if(req.url.endsWith('/search'))value={list:[{vod_id:'id',vod_name:'Movie',vod_pic:'/poster.png?signature=fixture'}]};
              else if(req.url.endsWith('/play'))value={parse:0,url:'/spider/demo/3/proxy/live.m3u8?ticket=fixture'};
              else value={};res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value));});
            await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
          };exports.stop=()=>new Promise(resolve=>server.close(resolve));"""
        (self.package/'index.cjs').write_text(source)
        for config_entry in (None, 'index.config.js'):
            with self.subTest(configuration=config_entry):
                if config_entry:
                    (self.package/config_entry).write_text("module.exports={__esModule:true,default:{marker:'sidecar',nested:{keep:'value',override:1}}}")
                extra={'configEntry':config_entry,'options':{'nested':{'override':2}}} if config_entry else {}
                started=self.call('start',packageRoot=str(self.package),dataDirectory=str(self.data),entry='index.cjs',moduleType='commonjs',protocol='catpaw-http',**extra)
                self.assertTrue(started['ok'],started)
                self.assertIn('configuration',started['result']['capabilities'])
                providers=self.call('providers')['result'];self.assertEqual(len(providers),1)
                self.assertEqual(providers[0]['name'],'sidecar' if config_entry else 'defaults')
                self.assertFalse(self.call('home',provider='removed')['ok'])
                self.assertTrue(self.call('home',provider='first')['ok'])
                self.assertEqual(self.call('detail',provider='first',id='opaque-id')['result']['list'][0]['vod_id'],'opaque-id')
                poster=self.call('search',provider='first',keyword='demo')['result']['list'][0]['vod_pic']
                self.assertRegex(poster,r'^http://127\.0\.0\.1:\d+/poster\.png\?signature=fixture$')
                media=self.call('play',provider='first',id='id')['result']['url']
                self.assertIn('/proxy/live.m3u8?ticket=fixture',media)
                configuration=self.call('configuration')['result'];self.assertTrue(configuration['configurationPage'])
                port=int(configuration['url'].split(':')[2].split('/')[0])
                client=http.client.HTTPConnection('127.0.0.1',port);client.request('GET','/switch');client.getresponse().read();client.close()
                self.assertEqual(self.call('providers')['result'][0]['id'],'second')
                self.assertFalse(self.call('providers')['result'][0]['searchable'])
                unsupported=self.call('search',provider='second',keyword='fixture')
                self.assertFalse(unsupported['ok'])
                self.assertFalse(self.call('home',provider='first')['ok'])
                self.assertTrue(self.call('stop')['ok'])
                with self.assertRaises(OSError):
                    probe=socket.create_connection(('127.0.0.1',port),timeout=.5);probe.close()

    def test_catpaw_http_error_preserves_source_msg_summary(self):
        (self.package/'index.cjs').write_text("""let server;exports.start=async()=>{
          server=catServerFactory((req,res)=>{res.setHeader('Content-Type','application/json');
            if(req.url==='/config')res.end(JSON.stringify({video:{sites:[{key:'public',api:'/spider/public/3'}]}}));
            else if(req.url==='/website'){res.writeHead(404);res.end('{}');}
            else{res.writeHead(500);res.end(JSON.stringify({msg:'source fixture missing required configuration'}));}});
          await new Promise(r=>server.listen(0,'127.0.0.1',r));};exports.stop=()=>new Promise(r=>server.close(r));""")
        started=self.call('start',packageRoot=str(self.package),dataDirectory=str(self.data),entry='index.cjs',moduleType='commonjs',protocol='catpaw-http')
        self.assertTrue(started['ok'],started)
        result=self.call('home',provider='public')
        self.assertFalse(result['ok'])
        self.assertIn('source fixture missing required configuration',result['error'])
        self.assertTrue(self.call('stop')['ok'])

    def test_catpaw_esm_configuration_exports_are_loaded(self):
        (self.package/'package.json').write_text('{"type":"module"}')
        (self.package/'index.config.js').write_text('export default {marker:"esm-config"}')
        (self.package/'index.mjs').write_text("""let server;export async function start(config){
          if(config.marker!=='esm-config')throw Error('ESM configuration not loaded');
          server=catServerFactory((req,res)=>{res.setHeader('Content-Type','application/json');res.end(JSON.stringify({video:{sites:[]}}))});
          await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
        }export async function stop(){await new Promise(resolve=>server.close(resolve))}""")
        reply=self.call('start',packageRoot=str(self.package),dataDirectory=str(self.data),entry='index.mjs',configEntry='index.config.js',moduleType='esm',protocol='catpaw-http')
        self.assertTrue(reply['ok'],reply)
        self.assertEqual(self.call('providers')['result'],[])
        self.assertTrue(self.call('stop')['ok'])

    def test_commonjs_sessions_run_and_stop_independently(self):
        (self.package / 'index.cjs').write_text('''
            let counter=0;module.exports={init(){setInterval(()=>counter++,5)},home(){return {class:[{type_id:'movie',type_name:'电影'}]}},
            search(key,quick,pg){return {page:pg,list:[{vod_id:key,vod_name:'Node original '+counter}]}},
            detail(ids){return {list:[{vod_id:ids[0],vod_play_from:'main',vod_play_url:'First$opaque-id'}]}},
            play(flag,id){return {parse:0,url:'https://fixture.test/'+flag+'/'+id}}};''')
        reply = self.start()
        self.assertTrue(reply['ok'], reply)
        self.assertIn('search', reply['result']['capabilities'])
        self.assertEqual(self.call('search', keyword='中文', page=2)['result']['list'][0]['vod_id'], '中文')
        self.assertEqual(self.call('play', lineId='main', id='opaque-id')['result']['url'], 'https://fixture.test/main/opaque-id')
        second = self.call('start', session='two', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.cjs', protocol='catvod-js')
        self.assertTrue(second['ok'], second)
        self.assertTrue(self.call('stop')['ok'])
        self.assertFalse(self.call('search', keyword='late')['ok'])
        self.assertTrue(self.call('search', session='two', keyword='still-running')['ok'])
        self.assertTrue(self.call('stop', session='two')['ok'])

    def test_native_formdata_uses_js_transport_without_wasm(self):
        (self.package/'index.cjs').write_text('''module.exports={search(){const form=new FormData();form.append('fixture','value');return {list:[{vod_id:form.get('fixture'),vod_name:new File(['data'],'fixture.txt').name}]}}}''')
        self.assertTrue(self.start()['ok'])
        result=self.call('search')['result']['list'][0]
        self.assertEqual(result,{'vod_id':'value','vod_name':'fixture.txt'})

    def test_catpaw_factory_selects_application_listener_and_uses_normal_local_auth(self):
        (self.package/'index.config.js').write_text("module.exports={marker:'local-config'}")
        (self.package/'index.cjs').write_text('''const fs=require('fs'),http=require('http');let app,helper;
          exports.start=async config=>{if(config.marker!=='local-config')throw Error('configuration missing');
            helper=http.createServer((req,res)=>{res.writeHead(401);res.end()});await new Promise(r=>helper.listen(0,'127.0.0.1',r));
            app=catServerFactory(async(req,res)=>{let body='';for await(const c of req)body+=c;const args=JSON.parse(body||'{}');let value;
              if(req.url==='/website/auth/status')value={code:0,data:{hasPassword:fs.existsSync('password')}};
              else if(req.url==='/website/auth/setup'){fs.writeFileSync('password',args.password);value={code:0,data:{token:'fixture-token'}}}
              else if(req.url==='/website/auth/login')value={code:args.password===fs.readFileSync('password','utf8')?0:-1,data:{token:'fixture-token'}};
              else if(req.headers.cookie!=='web_token=fixture-token'){res.writeHead(401);res.end();return}
              else if(req.url==='/config')value={video:{sites:[{key:'local',name:'fixture',api:'/spider/local/3'}]}};
              else value={class:[],list:[]};res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value));});
            app.listen({host:'0.0.0.0',port:0})};
          exports.stop=async()=>{await Promise.all([app,helper].map(s=>new Promise(r=>s.close(r))))};''')
        for _ in range(2):
            result=self.call('start',packageRoot=str(self.package),dataDirectory=str(self.data),entry='index.cjs',configEntry='index.config.js',protocol='catpaw-http',moduleType='commonjs')
            self.assertTrue(result['ok'],result)
            self.assertEqual(self.call('providers')['result'][0]['id'],'local')
            self.assertTrue(self.call('home')['ok'])
            self.assertTrue(self.call('stop')['ok'])
        self.assertEqual((self.data/'catpaw-auth.json').stat().st_mode&0o777,0o600)

    def test_widget_has_secure_randomness_and_preserves_season_episode_and_headers(self):
        (self.package/'index.js').write_text('''WidgetMetadata={name:'fixture'};
          async function loadResource(p){const nonce=crypto.getRandomValues(new Uint32Array(4));return [{name:p.title+'/'+p.season+'/'+p.episode,url:'https://fixture.test/live.m3u8?episode='+p.episode,customHeaders:{Referer:'https://fixture.test/'}}]}''')
        result=self.call('start',packageRoot=str(self.package),dataDirectory=str(self.data),entry='index.js',protocol='widget-extractor',moduleType='script')
        self.assertTrue(result['ok'],result)
        row=self.call('search',keyword='节目',season=2,episode=7)['result']['list'][0]
        self.assertEqual(row['name'],'节目/2/7')
        playback=self.call('play',id=row['id'])['result']
        self.assertEqual(playback['headers']['Referer'],'https://fixture.test/')
        self.assertTrue(playback['url'].endswith('episode=7'))

    def test_process_listeners_are_released_on_failed_start_and_independent_stop(self):
        (self.package/'index.cjs').write_text("process.on('cctv-fixture',()=>{});module.exports={search(){return {count:process.listenerCount('cctv-fixture')}}}")
        self.assertTrue(self.start()['ok'])
        self.assertTrue(self.call('start',session='two',packageRoot=str(self.package),dataDirectory=str(self.data),entry='index.cjs',protocol='catvod-js')['ok'])
        self.assertEqual(self.call('search',session='two')['result']['count'],2)
        self.assertTrue(self.call('stop')['ok'])
        self.assertEqual(self.call('search',session='two')['result']['count'],1)
        (self.package/'broken.cjs').write_text("process.on('cctv-fixture',()=>{});process.removeAllListeners('unhandledRejection');throw Error('fixture startup error')")
        self.assertFalse(self.call('start',session='broken',packageRoot=str(self.package),dataDirectory=str(self.data),entry='broken.cjs',protocol='catvod-js')['ok'])
        self.assertEqual(self.call('search',session='two')['result']['count'],1)
        self.assertTrue(self.call('stop',session='two')['ok'])

    def test_commonjs_global_state_and_environment_are_scoped_by_session(self):
        (self.package / 'index.cjs').write_text('''
          module.exports={init(){global.__fixtureCounter=(global.__fixtureCounter||0)+1;const marker='session-'+global.__fixtureCounter;global.local={marker};process.env.CCTV_FIXTURE_MARKER=marker;this.marker=marker},
            search(){return {module:this.marker,local:global.local.marker,env:process.env.CCTV_FIXTURE_MARKER}}};''')
        self.assertTrue(self.start()['ok'])
        self.assertTrue(self.call('start', session='two', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.cjs', protocol='catvod-js')['ok'])
        first=self.call('search')['result'];second=self.call('search',session='two')['result']
        self.assertEqual((first['module'],first['local'],first['env']),(first['module'],first['module'],first['module']))
        self.assertEqual((second['module'],second['local'],second['env']),(second['module'],second['module'],second['module']))
        self.assertNotEqual(first['module'],second['module'])
        self.assertTrue(self.call('stop')['ok'])
        self.assertTrue(self.call('search',session='two')['ok'])
        self.assertTrue(self.call('stop',session='two')['ok'])

    def test_catpaw_http_protocol_providers_and_lifecycle_with_real_local_server(self):
        (self.package / 'index.cjs').write_text('''
            const http=require('http');let server;
            exports.start=async()=>{server=http.createServer(async(req,res)=>{let text='';for await(const chunk of req)text+=chunk;const data=JSON.parse(text||'{}');
              let value=req.url==='/config'?{video:{sites:[{key:'first',name:'第一来源',api:'/spider/first/3'}]}}:
                req.url.endsWith('/search')?{page:data.pg,list:[{vod_id:data.wd,vod_name:'Catpaw HTTP'}]}:
                req.url.endsWith('/homeVod')?{list:[{vod_id:'one',vod_name:'推荐'}]}:
                {class:[{type_id:'movie',type_name:'电影'}]};res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value))});
              await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))};
            exports.stop=async()=>{if(server)await new Promise(resolve=>server.close(resolve))};''')
        reply = self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.cjs', protocol='catpaw-http')
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(self.call('providers')['result'][0]['id'], 'first')
        self.assertEqual(self.call('home', provider='first')['result']['list'][0]['vod_name'], '推荐')
        self.assertEqual(self.call('search', provider='first', keyword='query', page=2)['result']['list'][0]['vod_id'], 'query')
        self.assertTrue(self.call('stop')['ok'])

    def test_catpaw_bundle_app_instance_is_bound_by_host_and_stopped(self):
        (self.package / 'index.mjs').write_text('''
          import http from 'node:http';
          let server;
          globalThis.Pans={listen:async({host,port})=>{server=http.createServer(async(req,res)=>{
            let body='';for await(const chunk of req)body+=chunk;const data=JSON.parse(body||'{}');
            const value=req.url==='/config'?{video:{sites:[{key:'pans',name:'本地源',api:'/spider/pans/3'}]}}:
              req.url.endsWith('/search')?{list:[{vod_id:data.wd,vod_name:'Pans app'}]}:{class:[]};
            res.setHeader('Content-Type','application/json');res.end(JSON.stringify(value));
          });await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,host,resolve)})},
          close:async()=>{if(!server?.listening)throw Error('host closed before app cleanup');await new Promise(resolve=>server.close(resolve))}};
        ''')
        reply = self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.mjs',
                          protocol='catpaw-http', moduleType='esm')
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(self.call('providers')['result'][0]['id'], 'pans')
        self.assertEqual(self.call('search', keyword='catpaw')['result']['list'][0]['vod_id'], 'catpaw')
        self.assertTrue(self.call('stop')['ok'])
        self.assertFalse(self.call('providers')['ok'])

    def test_widget_extractor_uses_bounded_http_bridge_and_returns_playable_item(self):
        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                body = json.dumps({'url': 'https://fixture.test/video.m3u8'}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        thread = threading.Thread(target=upstream.serve_forever, daemon=True); thread.start()
        try:
            (self.package / 'index.js').write_text(f'''WidgetMetadata={{name:'fixture'}};
              async function loadResource(params){{
                const response=await Widget.http.get('http://127.0.0.1:{upstream.server_port}/resource',{{base64Data:false}});
                const media=JSON.parse(response.data);
                return [{{name:params.seriesName,url:media.url,description:'fixture source',headers:{{Referer:'https://fixture.test/'}}}}];
              }}''')
            reply = self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.js',
                              protocol='widget-extractor', moduleType='script')
            self.assertTrue(reply['ok'], reply)
            self.assertIn('search', reply['result']['capabilities'])
            results = self.call('search', keyword='测试剧')['result']
            self.assertEqual(results['list'][0]['name'], '测试剧')
            identifier = results['list'][0]['id']
            details = self.call('detail', id=identifier)['result']
            self.assertEqual(details['lines'][0]['episodes'][0]['id'], identifier)
            playback = self.call('play', id=identifier)['result']
            self.assertEqual((playback['url'], playback['headers']['Referer']),
                             ('https://fixture.test/video.m3u8', 'https://fixture.test/'))
            self.assertTrue(self.call('stop')['ok'])
        finally:
            upstream.shutdown(); upstream.server_close(); thread.join(timeout=2)

    def test_head_response_without_body_is_supported_by_plugin_http_bridge(self):
        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_HEAD(self):
                self.send_response(204); self.end_headers()
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        thread = threading.Thread(target=upstream.serve_forever, daemon=True); thread.start()
        try:
            (self.package / 'index.cjs').write_text(f'''module.exports={{async search(){{
              const response=await req('http://127.0.0.1:{upstream.server_port}/health',{{method:'HEAD',timeout:-1}});
              return {{list:[{{vod_id:String(response.code),vod_name:String(response.content.length)}}]}};
            }}}};''')
            self.assertTrue(self.start()['ok'])
            result = self.call('search')['result']['list'][0]
            self.assertEqual((result['vod_id'], result['vod_name']), ('204', '0'))
            self.assertTrue(self.call('stop')['ok'])
        finally:
            upstream.shutdown(); upstream.server_close(); thread.join(timeout=2)

    def test_unhandled_rejection_isolated_to_owning_plugin_session(self):
        (self.package / 'index.cjs').write_text('''module.exports={init(ext){if(ext!=='healthy')
          setTimeout(()=>Promise.reject(new Error('fixture rejection')),0)},
          search(){return {list:[{vod_id:'still-healthy',vod_name:'healthy'}]}}};''')
        self.assertTrue(self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data),
                                  entry='index.cjs', protocol='catvod-js')['ok'])
        deadline = time.monotonic() + 2
        failed = None
        while time.monotonic() < deadline:
            failed = self.call('search')
            if not failed['ok']:
                break
            time.sleep(.01)
        self.assertIsNotNone(failed)
        self.assertFalse(failed['ok'], failed)
        self.assertIn('fixture rejection', failed['error'])
        self.assertTrue(self.call('start', session='healthy', packageRoot=str(self.package),
                                  dataDirectory=str(self.data), entry='index.cjs', protocol='catvod-js',
                                  options={'ext': 'healthy'})['ok'])
        self.assertEqual(self.call('search', session='healthy')['result']['list'][0]['vod_id'], 'still-healthy')
        self.assertTrue(self.call('stop')['ok'])
        self.assertTrue(self.call('stop', session='healthy')['ok'])

    def test_throwing_stop_hook_force_closes_owned_listener_and_releases_session(self):
        (self.package / 'index.cjs').write_text('''const http=require('node:http'),fs=require('node:fs');let server;
          module.exports={async init(){server=http.createServer((_req,res)=>res.end('ok'));
            await new Promise(resolve=>server.listen(0,'127.0.0.1',()=>{fs.writeFileSync('port.txt',String(server.address().port));resolve()}));},
            search(){return {list:[{vod_id:fs.readFileSync('port.txt','utf8'),vod_name:'listener'}]}},
            stop(){throw Error('fixture stop hook failed')}};''')
        self.assertTrue(self.start()['ok'])
        port = int((self.data / 'port.txt').read_text())
        stopped = self.call('stop')
        self.assertTrue(stopped['ok'], stopped)
        self.assertIn('fixture stop hook failed', '\n'.join(stopped.get('logs', [])))
        self.assertEqual(self.call('state')['result']['sessions'], [])
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', port), timeout=.5)

    def test_modern_catvod_factory_receives_site_ext_and_scalar_detail_ids(self):
        (self.package / 'spider.mjs').write_text('''
          export default site=>({async init(ext){local.set('fixture-ext',ext)},
            async home(filter){return {class:[{type_id:'movie',type_name:'电影'}],list:[{vod_id:site.key,vod_name:site.name+':'+local.get('fixture-ext')+':'+local.get('missing','fallback')+':'+filter}]}},
            async homeVod(){return {list:[]}},
            async category(tid,pg,filter,extend){return {page:Number(pg),list:[{vod_id:tid,vod_name:JSON.stringify(extend)}]}},
            async search(key,quick,pg){return {page:Number(pg),list:[{vod_id:key,vod_name:String(quick)+':'+pg}]}},
            async detail(id){return {list:[{vod_id:id,vod_name:id,vod_play_from:'线路',vod_play_url:'第一集$'+id}]}},
            async play(flag,id,vipFlags){return {parse:0,url:'https://fixture.test/'+id,header:{Referer:'https://fixture.test/'+flag}}}})
        ''')
        reply = self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data), entry='spider.mjs',
                          protocol='catvod-js', moduleType='esm', name='CatVod Node fixture',
                          options={'site': {'key': 'catvod_fixture', 'name': 'CatVod fixture'}, 'ext': 'extension-value'})
        self.assertTrue(reply['ok'], reply)
        self.assertEqual(self.call('home')['result']['list'][0]['vod_name'], 'CatVod fixture:extension-value:fallback:true')
        self.assertEqual(self.call('category', categoryId='movie', page=2, filters={'area': '大陆'})['result']['list'][0]['vod_name'], '{"area":"大陆"}')
        self.assertEqual(self.call('detail', id='opaque/id')['result']['list'][0]['vod_id'], 'opaque/id')
        self.assertEqual(self.call('play', lineId='线路', id='opaque/id')['result']['header']['Referer'], 'https://fixture.test/线路')
        self.assertTrue(self.call('stop')['ok'])

    def test_path_escape_and_plugin_process_exit_are_reported_without_killing_host(self):
        (self.package / 'index.cjs').write_text("module.exports={search(){process.exit(1)}}")
        reply = self.call('start', packageRoot=str(self.root), dataDirectory=str(self.data), entry='outside.cjs')
        self.assertFalse(reply['ok'])
        self.assertTrue(self.start()['ok'])
        reply = self.call('search', keyword='query')
        self.assertFalse(reply['ok'])
        self.assertIsNone(self.process.poll())
        self.assertTrue(self.call('stop')['ok'])

    def test_original_esm_iptv_extractor_exposes_live_catalog_and_uses_account_options(self):
        (self.package / 'index.mjs').write_text('''
          export default {async fetch(){return {groups:[{name:'直播',dataList:[{pID:'opaque/live',deferredRef:'opaque/live',name:'频道',pics:{highResolution:'https://fixture.test/logo.png'}}]}]}},
            async resolve(ref,{config,account}){return {url:'https://fixture.test/'+encodeURIComponent(ref),desc:account.userId+':'+config.rateType}}};''')
        reply = self.call('start', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.mjs', protocol='iptv-extractor', moduleType='esm', options={'userId': 'fixture-user', 'rateType': 3})
        self.assertTrue(reply['ok'], reply)
        self.assertIn('live', reply['result']['capabilities'])
        item = self.call('catalog')['result'][0]
        self.assertEqual((item['ref'], item['group']), ('opaque/live', '直播'))
        resolved = self.call('resolve', ref=item['ref'])['result']
        self.assertEqual((resolved['url'], resolved['desc']), ('https://fixture.test/opaque%2Flive', 'fixture-user:3'))
        self.assertTrue(self.call('stop')['ok'])
    def test_nanotv_v2_service_bridges_http_crypto_storage_channels_and_hls(self):
        class Fixture(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                body=b'{\"ok\":true}'
                self.send_response(200);self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        upstream=http.server.ThreadingHTTPServer(('127.0.0.1',0),Fixture)
        thread=threading.Thread(target=upstream.serve_forever,daemon=True);thread.start()
        try:
            manifest={'id':'fixture-live','name':'Fixture Live','version':'2.0','apiVersion':2,
                      'networkHosts':['127.0.0.1'],'mediaHosts':['127.0.0.1'],
                      'mediaCredentialHosts':['127.0.0.1'],'capabilities':['http','crypto','storage','scheduler','media.hls']}
            declaration=json.dumps({'declarationVersion':1,'manifest':manifest},separators=(',',':'))
            source='''/* nanoTV-declaration
__DECLARATION__
*/
(function(g){
  g.nanoService={
    manifest:{\"id\":\"fixture-live\",\"version\":\"2.0\",\"apiVersion\":2},
    async start(host){
      this.host=host;
      const key=host.bytes.convert('00'.repeat(32),'hex','base64');
      const plain=host.bytes.convert('round-trip','utf8','base64');
      const sealed=host.crypto.seal({key,data:plain});
      if(host.bytes.convert(host.crypto.open({key,data:sealed}),'base64','utf8')!=='round-trip')throw Error('AES-GCM bridge failed');
      const rsa=host.crypto.rsaEncrypt({publicKey:'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkKeLy4ywWLSnBkwRyqYgF3HMIj05V5uuh5HjyEsZOWnu1NHu3jPQv3sr32wwQNYv5qapsNXmNgLUDHtgHZxqPQAYXltjSRc0qhcD286t62wOIHId8zXS3s1Jy4rgU4qjQWzI9rp/1sE0pMsmwTaJa4zuJ5iz8VwF8Av5oJ1k+HxY+/HLnjNlW1hmWLpuDYmkZYuAoTHa1VGeHQh9FEKI8ZcL3GTQphShUoC+Kg3P1hGUVTtCYapmzPS5lkAdwebuzwvTCfGiTErYZCnPBUSeV7BVlgjtLYIi29KvF0a8FHsJMfe/UdHcyW/RihsIYOtDQcRRpFGXyPXbVrzFJse24QIDAQAB',data:host.bytes.convert('test-device','utf8','base64')});
      if(host.bytes.convert(rsa,'base64','bytes').length!==256)throw Error('RSA bridge failed');
      if(host.crypto.gunzip(host.crypto.gzip(host.bytes.convert('gzip','utf8','base64')))!==host.bytes.convert('gzip','utf8','base64'))throw Error('gzip bridge failed');
      host.storage.set('started',(host.storage.get('started')||0)+1);
      if(host.crypto.digest('sha256','test').length!==64)throw Error('digest bridge failed');
      const response=await host.http.request({url:'http://127.0.0.1:__PORT__/health',timeoutSeconds:3});
      const native=await new Promise((resolve,reject)=>host.native.http(JSON.stringify({url:'http://127.0.0.1:__PORT__/health'}),value=>{const result=JSON.parse(value);result.ok?resolve(result):reject(Error(result.error))}));
      if(response.status!==200||native.status!==200)throw Error('HTTP bridge failed');
      host.scheduler.every('fixture-heartbeat',1000,()=>{});
    },
    channels(){return [{id:'cctv1',name:'CCTV-1',group:'央视',logo:''}]},
    async resolve({channelID,query},host){
      const media=host.media.openHLS({channelID,manifestURL:'http://127.0.0.1:__PORT__/live.m3u8',headers:{'User-Agent':'fixture'},expiresAt:Date.now()/1000+60,liveWindow:{minPollSeconds:5},refresh:async()=>({url:'http://127.0.0.1:__PORT__/fresh.m3u8',headers:{'User-Agent':'fixture'},expiresAt:Date.now()/1000+60})});
      return {...media,channel:{id:channelID,name:'CCTV-1'},query,source:'fixture',resolutionVerified:false};
    },
    status(){return {started:this.host.storage.get('started')||0}},
    stop(){this.stopped=true}
  };
})(globalThis);'''
            source=source.replace('__DECLARATION__',declaration).replace('__PORT__',str(upstream.server_port))
            (self.package/'nano.js').write_text(source)
            started=self.call('start',packageRoot=str(self.package),dataDirectory=str(self.data),entry='nano.js',
                              protocol='nanotv-service-v2',moduleType='script',pluginID='app-generated-service-id')
            self.assertTrue(started['ok'],started)
            self.assertEqual(started['result']['protocol'],'nanotv-service-v2')
            self.assertIn('live',started['result']['capabilities'])
            capabilities=self.call('capabilities')
            self.assertTrue(capabilities['ok'],capabilities)
            self.assertIn('live',capabilities['result']['capabilities'])
            self.assertEqual(self.call('catalog')['result'][0]['id'],'cctv1')
            resolved=self.call('resolve',ref='cctv1',query={'source':'bk'})
            self.assertTrue(resolved['ok'],resolved)
            self.assertEqual(resolved['result']['query']['source'],'bk')
            self.assertTrue(resolved['result']['url'].endswith('/live.m3u8'))
            refreshed=self.call('refreshMedia',sessionID=resolved['result']['sessionID'])
            self.assertTrue(refreshed['ok'],refreshed)
            self.assertTrue(refreshed['result']['url'].endswith('/fresh.m3u8'))
            self.assertEqual(self.call('status')['result']['started'],1)
            self.assertTrue(self.call('stop')['ok'])
        finally:
            upstream.shutdown();upstream.server_close();thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
