import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
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
        node = os.environ.get('CCTVHOST_NODE_BINARY', shutil.which('node'))
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

    def test_original_commonjs_runs_and_timers_are_disposed_before_replacement(self):
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
        self.assertFalse(self.call('start', session='two', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.cjs')['ok'])
        self.assertTrue(self.call('stop')['ok'])
        self.assertFalse(self.call('search', keyword='late')['ok'])
        self.assertTrue(self.call('start', session='two', packageRoot=str(self.package), dataDirectory=str(self.data), entry='index.cjs', protocol='catvod-js')['ok'])
        self.assertTrue(self.call('stop', session='one')['ok'])
        self.assertTrue(self.call('search', session='two', keyword='still-running')['ok'])
        self.assertTrue(self.call('stop', session='two')['ok'])

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


if __name__ == '__main__':
    unittest.main()
