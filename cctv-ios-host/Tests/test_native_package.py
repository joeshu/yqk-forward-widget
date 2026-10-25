import json
import hashlib
import http.server
from pathlib import Path
import platform
import stat
import subprocess
import tempfile
import threading
import unittest
import zipfile
import urllib.parse


@unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS Foundation')
class NativePackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.tmp.name)
        root = Path(__file__).resolve().parents[1]
        cls.executable = cls.folder / 'package-test'
        build = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-lz', '-I', str(root / 'Sources'),
                                str(root / 'Tests/native_package_tests.m'), str(root / 'Sources/MediaPackageImporter.m'),
                                str(root / 'Sources/MediaPackageDownloader.m'),
                                str(root / 'Sources/ServiceStore.m'), '-o', str(cls.executable)], capture_output=True, text=True)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def inspect(self, file):
        result = subprocess.run([str(self.executable), str(file)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def archive(self, entries):
        file = self.folder / 'fixture.zip'
        with zipfile.ZipFile(file, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, content in entries.items():
                archive.writestr(name, content)
        return file

    def test_zip_manifest_esm_dependencies_and_original_archive_are_preserved(self):
        file = self.archive({'wrapped/cctvhost.json': json.dumps({'schemaVersion': 1, 'name': '中文影视', 'entry': 'src/index.mjs', 'runtime': 'javascript', 'protocol': 'cctvhost.media/1'}),
                             'wrapped/src/index.mjs': 'import value from "./value.js";export default {search(){return []}}',
                             'wrapped/src/value.js': 'export default 1'})
        result = self.inspect(file)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['name'], result['engine'], result['manifest']['moduleType']), ('中文影视', 'javascript', 'esm'))
        self.assertTrue(result['vodCapable'])
        self.assertTrue(result['entryExists'])
        self.assertTrue(result['archiveExists'])

    def test_commonjs_node_require_is_routed_to_node_unless_manifest_overrides(self):
        source = "const fs=require('fs');module.exports={search(){return {list:[]}}}"
        inferred = self.inspect(self.archive({'index.js': source}))
        self.assertTrue(inferred['ok'], inferred)
        self.assertEqual((inferred['engine'], inferred['manifest']['moduleType']), ('node', 'commonjs'))

        explicit = self.inspect(self.archive({'index.js': source,
            'cctvhost.json': json.dumps({'entry': 'index.js', 'runtime': 'javascript',
                                         'protocol': 'cctvhost.media/1'})}))
        self.assertTrue(explicit['ok'], explicit)
        self.assertEqual(explicit['engine'], 'javascript')

    def test_package_dependencies_default_to_node_for_esm(self):
        result = self.inspect(self.archive({'package.json': json.dumps({'type': 'module',
                                                                       'dependencies': {'example': '^1.0.0'}}),
                                           'index.js': 'export default {search(){return {list:[]}}}'}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['manifest']['moduleType']), ('node', 'esm'))

    def test_catpaw_fastify_spider_is_identified_as_native_esm_route_plugin(self):
        source = '''export default function createSpider(name, config) {
          return {meta:{key:'fixture',name:'Fixture',type:3},api:async fastify=>{
            fastify.post('/init',async()=>({}));fastify.post('/home',async()=>({class:[],list:[]}));
            fastify.post('/category',async()=>({list:[]}));fastify.post('/detail',async()=>({list:[]}));
            fastify.post('/play',async()=>({parse:0,url:'https://fixture.test/video.m3u8'}));fastify.post('/search',async()=>({list:[]}));
          }};
        }'''
        result = self.inspect(self.archive({'package.json': json.dumps({'type': 'module', 'dependencies': {'cheerio': '^1.0.0'}}),
                                           'index.js': source}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol'], result['manifest']['moduleType']),
                         ('javascript', 'catvod-spider', 'esm'))
        direct = self.folder / 'catpaw.js'
        direct.write_text(source)
        result = self.inspect(direct)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('javascript', 'catvod-spider'))

    def test_catpaw_fastify_route_api_is_detected_even_when_routes_are_registered_with_route(self):
        source = '''export default function createSpider() { return {meta:{key:'route_fixture'},api:async fastify=>{
          const handler=async()=>({});fastify.route({method:'POST',url:'/init',handler});
          fastify.route({method:'POST',url:'/home',handler});fastify.route({method:'POST',url:'/category',handler});
          fastify.route({method:'POST',url:'/detail',handler});fastify.route({method:'POST',url:'/play',handler});fastify.route({method:'POST',url:'/search',handler});
        }}; }'''
        result = self.inspect(self.archive({'index.mjs': source}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('javascript', 'catvod-spider'))

    def test_catpaw_open_node_server_is_found_under_src(self):
        package = {'type': 'module', 'dependencies': {'fastify': '^4.26.0'}}
        index = "import router from './router.js';let server;export async function start(config){server=fastify();server.config=config;server.register(router);await server.listen({port:0,host:'127.0.0.1'})}export async function stop(){await server.close()}"
        router = "const spiderPrefix='/spider';fastify.get('/config',async()=>({video:{sites:[]}}));fastify.register(spider.api,{prefix:spiderPrefix+'/'+spider.meta.key+'/'+spider.meta.type})"
        result = self.inspect(self.archive({'package.json': json.dumps(package), 'src/index.js': index, 'src/router.js': router}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol'], result['manifest']['entry']),
                         ('node', 'catpaw-http', 'src/index.js'))

    def test_catpaw_server_with_inline_routes_is_recognized(self):
        source = '''import fastify from 'fastify';let active;
          export function createService(){const server=fastify();server.get('/config',async()=>({video:{sites:[]}}));
          server.post('/spider/demo/3/home',async()=>({class:[]}));return server;}
          export function start(input={}){active=createService();return active.listen({host:'127.0.0.1',port:0})}
          export function stop(){return active?.close()}'''
        result = self.inspect(self.archive({'index.js': source, 'package.json': json.dumps({'type': 'module', 'dependencies': {'fastify': '^4.0.0'}})}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('node', 'catpaw-http'))

    def test_catpaw_bundled_fastify_app_is_esm_and_gets_node_package_metadata(self):
        source = '''globalThis.Pans = await createApplication();
          // The bundle contains a nested CJS loader string but its entry is ESM.
          const loader = "module.exports = value";
          const route = '/config'; const prefix = '/spider/demo';
          const video = {sites: []};'''
        result = self.inspect(self.archive({'index.js': source}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol'], result['manifest']['moduleType']),
                         ('node', 'catpaw-http', 'esm'))
        self.assertEqual(result['nodePackageType'], 'module')

    def test_catpaw_minified_commonjs_keeps_config_and_is_not_inferred_as_esm(self):
        source = '''var exports={};module.exports=exports;
          exports.start=async()=>{globalThis.Pans=await listPans();};
          const config='/config',prefix='/spider/',video={sites:[]};'''
        result = self.inspect(self.archive({'index.js': source, 'index.config.js': 'module.exports={video:{}}'}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['manifest']['moduleType']), ('node', 'commonjs'))
        self.assertEqual(result['manifest']['configEntry'], 'index.config.js')
        repaired=self.inspect(self.archive({'index.js':source,'index.config.js':'module.exports={}', 'package.json':'{"type":"module"}'}))
        self.assertTrue(repaired['ok'],repaired)
        self.assertEqual((repaired['manifest']['moduleType'],repaired['nodePackageType']),('commonjs','commonjs'))

    def test_nanotv_v2_declaration_is_classified_as_native_service_contract(self):
        source='''/* nanoTV-declaration
        {\"declarationVersion\":1,\"manifest\":{\"id\":\"fixture-live\",\"name\":\"Fixture Live\",\"version\":\"2.0\",\"apiVersion\":2,\"networkHosts\":[\".example.test\"],\"capabilities\":[\"http\",\"crypto\",\"storage\",\"scheduler\",\"media.hls\"]}}
        */
        (function(g){g.nanoService=createYSPService({})})(globalThis);function createYSPService(){return {start(){},channels(){return []},resolve(){},stop(){}}}'''
        file=self.folder/'nano.js';file.write_text(source)
        result=self.inspect(file)
        self.assertTrue(result['ok'],result)
        self.assertEqual((result['engine'],result['protocol'],result['manifest']['moduleType']),
                         ('node','nanotv-service-v2','script'))
        self.assertEqual(result['manifest']['name'],'Fixture Live')
        self.assertEqual(result['manifest']['pluginVersion'],'2.0')
        self.assertFalse(result['vodCapable'])
        self.assertEqual(result['playlistPath'],'/all.m3u')

    def test_local_zip_md5_pairs_are_verified_before_install(self):
        source=b"module.exports={search(){return {list:[]}}}"
        configuration=b"module.exports={video:{sites:[]}}"
        entries={'index.js':source,'index.js.md5':hashlib.md5(source).hexdigest(),
                 'index.config.js':configuration,'index.config.js.md5':hashlib.md5(configuration).hexdigest()}
        result=self.inspect(self.archive(entries))
        self.assertTrue(result['ok'],result)
        self.assertEqual(result['verifiedLocalChecksums'],['index.js','index.config.js'])
        entries['index.config.js.md5']='0'*32
        result=self.inspect(self.archive(entries))
        self.assertFalse(result['ok'],result)
        self.assertIn('MD5',result['error'])

    def test_python_http_zip_with_companion_engine_uses_positional_port_and_mobile_defaults(self):
        source = '''import argparse
from http.server import ThreadingHTTPServer
ap=argparse.ArgumentParser()
ap.add_argument('port',nargs='?',type=int,default=8767)
ap.add_argument('--bind')
ap.add_argument('--data-dir')
ap.add_argument('--cache-mb')
ap.add_argument('--no-engine',action='store_true')
ap.add_argument('--no-4k',action='store_true')
worker='heartbeat-keeper'
route='/all.m3u';body='#EXTM3U'
'''
        result=self.inspect(self.archive({'wrapped/ysp-live-v9.5.py':source,'wrapped/ysp-engine.js':'const engine=1','wrapped/README.md':'docs'}))
        self.assertTrue(result['ok'],result)
        self.assertEqual(result['manifest']['entry'],'ysp-live-v9.5.py')
        self.assertEqual(result['playlistPath'],'/all.m3u')
        self.assertEqual(result['arguments'],'{port}|--bind|{bind}|--data-dir|{dataDir}|--cache-mb|32|--no-engine|--no-4k')
        self.assertIn('1080p',result['manifest']['compatibilityNote'])

    def test_catvod_quickjs_methods_and_tvbox_manifest_alias_are_recognized(self):
        source = "export default site=>({async init(ext){},async home(filter){return {class:[]}},async homeVod(){return {list:[]}},async category(tid,pg,filter,extend){return {list:[]}},async search(key,quick,pg){return {list:[]}},async detail(id){return {list:[]}},async play(flag,id,vipFlags){return {parse:0,url:id}}})"
        inferred = self.inspect(self.archive({'index.mjs': source}))
        self.assertTrue(inferred['ok'], inferred)
        self.assertEqual((inferred['engine'], inferred['protocol']), ('javascript', 'catvod-js'))
        for protocol in ('tvbox', 'tvbox-js'):
            aliased = self.inspect(self.archive({'cctvhost.json': json.dumps({'entry': 'index.mjs', 'runtime': 'javascript', 'protocol': protocol, 'moduleType': 'esm'}), 'index.mjs': source}))
            self.assertTrue(aliased['ok'], aliased)
            self.assertEqual(aliased['protocol'], 'catvod-js')

    def test_catvod_object_property_async_methods_are_recognized(self):
        source = "export default site=>({home:async(filter)=>({class:[]}),category:async(tid,pg)=>({list:[]}),search:async(key)=>({list:[]}),detail:async(id)=>({list:[]}),play:async(flag,id)=>({parse:0,url:id})})"
        result = self.inspect(self.archive({'index.mjs': source}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('javascript', 'catvod-js'))

    def test_python_spider_is_recognized_without_executing_user_code(self):
        marker = self.folder / 'must-not-run'
        file = self.folder / '看剧.py'
        file.write_text(f'from pathlib import Path\nPath({str(marker)!r}).write_text("bad")\nclass Spider: pass\n')
        result = self.inspect(file)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('python', 'python-spider'))
        self.assertFalse(marker.exists())

    def test_widget_metadata_loader_is_recognized_as_widget_extractor(self):
        file = self.folder / 'cheyong-rex.js'
        file.write_text("WidgetMetadata={name:'fixture'}; async function loadResource(params){return await Widget.http.get(params.url)}")
        result = self.inspect(file)
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol']), ('node', 'widget-extractor'))

    def test_standalone_python_http_import_uses_declared_host_port_flags(self):
        ysp = '''import argparse
from http.server import ThreadingHTTPServer
ap = argparse.ArgumentParser()
ap.add_argument('--serve', action='store_true')
ap.add_argument('--port', dest='port_opt', type=int, default=None)
ap.add_argument('--bind', default='127.0.0.1')
def m3u(origin, data): return '#EXTM3U'
route = '/all.m3u'
'''
        result = self.inspect(self.archive({'ysp_live_plugin.py': ysp}))
        self.assertTrue(result['ok'], result)
        self.assertEqual((result['engine'], result['protocol'], result['arguments']),
                         ('python', 'python-http', '--port|{port}|--bind|{bind}|--serve'))
        self.assertEqual(result['playlistPath'], '/all.m3u')

        cbox = "import argparse\nap=argparse.ArgumentParser()\nap.add_argument('--port', dest='port_opt')\nap.add_argument('--bind', default='127.0.0.1')\n"
        result = self.inspect(self.archive({'cbox_live_plugin.py': cbox}))
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['arguments'], '--port|{port}|--bind|{bind}')

        generic = "import argparse\nap=argparse.ArgumentParser()\nap.add_argument('--serve', action='store_true')\n"
        result = self.inspect(self.archive({'generic.py': generic}))
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['arguments'], '')

    def test_traversal_symlink_duplicate_and_bad_crc_are_rejected(self):
        for path in ('../escaped.py', '/absolute.py', 'directory/../../escaped.py', 'C:/escaped.py'):
            self.assertFalse(self.inspect(self.archive({path: 'class Spider: pass'}))['ok'], path)
        file = self.folder / 'link.zip'
        with zipfile.ZipFile(file, 'w') as archive:
            entry = zipfile.ZipInfo('index.py')
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, '../outside')
        self.assertFalse(self.inspect(file)['ok'])
        self.assertFalse(self.inspect(self.archive({'Index.js': 'var plugin={}', 'index.js': 'var plugin={}'}))['ok'])
        file = self.archive({'index.js': 'export default {search(){return []}}'})
        data = bytearray(file.read_bytes())
        data[30 + len('index.js')] ^= 0x10
        file.write_bytes(data)
        self.assertFalse(self.inspect(file)['ok'])

    def test_invalid_manifest_types_and_unknown_runtime_do_not_crash(self):
        for manifest in ({'entry': 42}, {'entry': '../outside.py'}, {'entry': 'index.js', 'runtime': 'java'},
                         {'entry': 'index.js', 'capabilities': [None]}, {'entry': 'index.js', 'moduleType': 'native'},
                         {'entry': 'index.js', 'schemaVersion': 99}):
            result = self.inspect(self.archive({'index.js': 'export default {search(){return []}}', 'cctvhost.json': json.dumps(manifest)}))
            self.assertFalse(result['ok'], manifest)

    def test_single_file_size_and_expansion_limits(self):
        file = self.archive({'index.js': b'x' * (8 * 1024 * 1024 + 1)})
        self.assertFalse(self.inspect(file)['ok'])

    def test_remote_catpaw_import_fetches_configuration_and_preserves_queries(self):
        source=b"const r='/config',s='/spider/',v={video:{sites:[]}};const a=catServerFactory,b=catDartServerPort;module.exports={start:async()=>{},stop(){}};"
        configuration=b'module.exports={default:{video:{sites:[]}}}'
        observed=[]
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                observed.append(self.path);path=urllib.parse.urlsplit(self.path).path
                if path=='/redirect.md5':
                    self.send_response(302);self.send_header('Location','/cat/index.js.md5?variant=one');self.end_headers();return
                if path.endswith('/index.js.md5'):body=(hashlib.md5(source).hexdigest()+' *index.js').encode()
                elif path.endswith('/index.js'):body=source
                elif '/missing/' in path:self.send_response(404);self.end_headers();return
                elif path.endswith('/index.config.js.md5'):body=('0'*32 if '/bad/' in path else hashlib.md5(configuration).hexdigest()).encode()
                elif path.endswith('/index.config.js'):body=configuration
                else:self.send_response(404);self.end_headers();return
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            origin=f'http://127.0.0.1:{server.server_port}'
            result=self.inspect(origin+'/redirect.md5')
            self.assertTrue(result['ok'],result);self.assertEqual(result['protocol'],'catpaw-http');self.assertEqual(result['engine'],'node')
            self.assertEqual(result['configurationState'],'verified');self.assertTrue(result['configurationExists'])
            for name in ('index.js','index.config.js','index.config.js.md5'):self.assertIn('/cat/'+name+'?variant=one',observed)
            result=self.inspect(origin+'/missing/index.js.md5');self.assertTrue(result['ok'],result);self.assertEqual(result['configurationState'],'missing_using_defaults')
            self.assertFalse(self.inspect(origin+'/bad/index.js.md5')['ok'])
            canceled=subprocess.run([str(self.executable),'--cancel-download',origin+'/cat/index.js.md5'],capture_output=True,text=True,timeout=10)
            self.assertEqual(canceled.returncode,0,canceled.stderr);self.assertFalse(json.loads(canceled.stdout)['ok'])
        finally:server.shutdown();server.server_close();thread.join(2)

    def test_imported_update_preserves_identity_options_account_data_and_rollback(self):
        old=self.folder/'old.cjs';new=self.folder/'new.cjs'
        old.write_text('module.exports={search(){return {list:[],version:1}}}')
        new.write_text('module.exports={search(){return {list:[],version:2}}}')
        result=subprocess.run([str(self.executable),'--update',str(old),str(new)],capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        value=json.loads(result.stdout)
        for key in ('ok','sameID','portKept','optionsKept','accountKept','rollbackRestoredCode'):self.assertTrue(value[key],value)

    def test_md5_pair_downloads_original_code_and_rejects_mismatch_and_limits(self):
        source = b'module.exports={search(){return {list:[]}}}'
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                body = source
                if self.path.endswith('.md5'):
                    body = (hashlib.md5(source).hexdigest() if self.path == '/index.cjs.md5' else '0' * 32).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(25 * 1024 * 1024 if self.path == '/oversize.js' else len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True);thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            result = self.inspect(base + '/index.cjs.md5')
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['manifest']['moduleType'], 'commonjs')
            self.assertFalse(self.inspect(base + '/mismatch.js.md5')['ok'])
            self.assertFalse(self.inspect(base + '/oversize.js')['ok'])
            self.assertFalse(self.inspect(base + '/unsupported.txt')['ok'])
        finally:
            server.shutdown();server.server_close();thread.join(2)


if __name__ == '__main__':
    unittest.main()
