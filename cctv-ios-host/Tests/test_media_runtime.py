import http.client
import http.server
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import urllib.parse
from unittest import mock

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
import host_media_runtime as media
from host_media_relay import MediaRelay
SPEC = importlib.util.spec_from_file_location('media_service', PLUGINS / 'media-service.py')
transport = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transport)

SPIDER = '''
class Spider:
    def init(self, extend=''): self.options=extend
    def homeContent(self, filter): return {'class':[{'type_id':'movies','type_name':'电影'}]}
    def homeVideoContent(self): return {'list':[{'vod_id':'movie/1','vod_name':'测试电影','vod_pic':'https://example.test/1.jpg'}]}
    def categoryContent(self, tid, pg, filter, extend): return {'page':int(pg),'pagecount':3,'list':[{'vod_id':tid+pg,'vod_name':'分页'}]}
    def searchContent(self, key, quick, pg='1'): return {'page':int(pg),'pagecount':2,'list':[{'vod_id':key,'vod_name':key}]}
    def detailContent(self, ids): return {'list':[{'vod_id':ids[0],'vod_name':'详情','vod_play_from':'甲$$$乙','vod_play_url':'第一集$https://a.test/one?a=$x#第二集$two$$$正片$three'}]}
    def playerContent(self, flag, id, vipFlags): return {'parse':0,'url':id if id.startswith('http') else 'https://a.test/'+id, 'header':{'Referer':'https://a.test/','User-Agent':'fixture'}}
    def destroy(self): self.destroyed=True
'''


class MediaTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        Path(self.tmp.name, '影视.py').write_text(SPIDER)
        self.engine = media.PythonSpider(self.tmp.name, '影视.py')
        self.runtime = media.MediaRuntime(self.engine)

    def tearDown(self):
        self.runtime.close()
        self.tmp.cleanup()

    def test_spider_home_pagination_multiline_and_play_headers(self):
        home = self.runtime.call('home')
        self.assertEqual(home['categories'], [{'id': 'movies', 'name': '电影'}])
        self.assertEqual(home['items'][0]['id'], 'movie/1')
        page = self.runtime.call('category', {'categoryId': 'movies', 'page': 2})
        self.assertEqual((page['page'], page['pagecount'], page['hasMore']), (2, 3, True))
        self.assertEqual(self.runtime.call('search', {'keyword': '中文', 'page': 2})['hasMore'], False)
        detail = self.runtime.call('detail', {'id': 'movie/1'})
        self.assertEqual([line['id'] for line in detail['lines']], ['甲', '乙'])
        self.assertEqual(detail['lines'][0]['episodes'][0]['id'], 'https://a.test/one?a=$x')
        play = self.runtime.call('play', {'lineId': '乙', 'id': 'three'})
        self.assertEqual(play['headers']['Referer'], 'https://a.test/')
        self.assertEqual(play['url'], 'https://a.test/three')

    def test_search_cache_is_provider_and_page_scoped_and_returns_copies(self):
        with mock.patch.object(self.engine, 'call', wraps=self.engine.call) as call:
            a = self.runtime.call('search', {'keyword': 'word', 'page': 1, 'provider': 'one'})
            a['items'].clear()
            b = self.runtime.call('search', {'keyword': 'word', 'page': 1, 'provider': 'one'})
            self.assertEqual(len(b['items']), 1)
            self.assertEqual(call.call_count, 1)
            self.runtime.call('search', {'keyword': 'word', 'page': 2, 'provider': 'one'})
            self.runtime.call('search', {'keyword': 'word', 'page': 1, 'provider': 'two'})
            self.assertEqual(call.call_count, 3)

    def test_playback_marks_web_tasks_and_rejects_invalid_schemes(self):
        self.assertEqual(media.playback({'parse': 1, 'url': 'https://a.test/'})['parse'], 1)
        for result in [{'url': 'file:///private/data'}, {'url': ''}]:
            with self.assertRaises(media.MediaError):
                media.playback(result)
        value = media.playback({'url': 'https://a.test/video', 'header': {'X-Foo': 'ok', 'Cookie': 'one\r\ntwo', 'Host': 'spoof'}})
        self.assertEqual(value['headers'], {'X-Foo': 'ok'})

    def test_busy_spider_does_not_execute_concurrently(self):
        self.engine.lock.acquire()
        try:
            with self.assertRaisesRegex(media.MediaError, '其他请求'):
                self.runtime.call('search', {'keyword': 'busy'})
        finally:
            self.engine.lock.release()

    def test_close_releases_module_and_rejects_new_requests(self):
        name = self.engine.module_name
        self.assertIn(name, sys.modules)
        self.runtime.close()
        self.assertNotIn(name, sys.modules)
        self.assertTrue(self.engine.spider.destroyed)
        with self.assertRaisesRegex(media.MediaError, '停止'):
            self.runtime.call('home')

    def test_cache_entry_budget(self):
        for i in range(40):
            self.runtime.call('search', {'keyword': str(i)})
        self.assertEqual(len(self.runtime.cache), 32)
        self.assertLessEqual(self.runtime.cache_bytes, 8 * 1024 * 1024)

    def test_real_http_api_and_head_probe(self):
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(path, method='GET', data=None):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            try:
                client.request(method, path, json.dumps(data).encode() if data is not None else None)
                result = client.getresponse()
                body = result.read()
                return result.status, json.loads(body) if body else None
            finally:
                client.close()
        try:
            with mock.patch.object(self.engine, 'call', wraps=self.engine.call) as call:
                self.assertEqual(request('/api/v1/play', 'HEAD'), (200, None))
                self.assertEqual(call.call_count, 0)
            self.assertTrue(request('/health')[1]['ok'])
            status, reply = request('/api/v1/search', 'POST', {'keyword': '影片', 'page': 2})
            self.assertEqual(status, 200)
            self.assertEqual(reply['data']['items'][0]['name'], '影片')
            self.assertFalse(reply['data']['hasMore'])
            status, reply = request('/api/v1/play', 'POST', {'id': 'one'})
            self.assertEqual(status, 200)
            self.assertTrue(reply['data']['url'].startswith(f'http://127.0.0.1:{server.server_port}/media/'))
            self.assertEqual(reply['data']['originalURL'], 'https://a.test/one')
            self.assertEqual(request('/missing')[0], 404)
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_relay_rewrites_master_segments_keys_and_maps_without_open_proxy(self):
        relay = MediaRelay(limit=4)
        text = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\nsegment.ts\n'
        rewritten = relay.rewrite(text, 'https://a.test/path/index.m3u8', {'Referer': 'https://a.test/'}, 'a.test', 'http://127.0.0.1:18780')
        self.assertNotIn('URI="key.bin"', rewritten)
        self.assertNotIn('\nsegment.ts', rewritten)
        targets = [value[0][0] for value in relay.targets.values()]
        self.assertEqual(targets, ['https://a.test/path/key.bin', 'https://a.test/path/init.mp4', 'https://a.test/path/segment.ts'])
        for i in range(8):
            relay.register(f'https://a.test/{i}.ts', {})
        self.assertEqual(len(relay.targets), 4)
        with self.assertRaises(ValueError):
            relay.register('file:///etc/passwd', {})
        relay.close()
        self.assertFalse(relay.targets)

    def test_real_hls_relay_preserves_headers_and_ranges_and_strips_redirect_credentials(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append((self.path, dict(self.headers)))
                if self.path == '/redirect':
                    self.send_response(302);self.send_header('Location', f'http://localhost:{self.server.server_port}/target');self.end_headers();return
                body = b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:6,\nsegment.ts\n' if self.path == '/index.m3u8' else b'0123456789'
                ranged = self.headers.get('Range') == 'bytes=2-5'
                if ranged: body = body[2:6]
                self.send_response(206 if ranged else 200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl' if self.path.endswith('.m3u8') else 'video/mp2t')
                if ranged: self.send_header('Content-Range', 'bytes 2-5/10')
                self.send_header('Content-Length', str(len(body)));self.end_headers();self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        threads = [threading.Thread(target=item.serve_forever, daemon=True) for item in (upstream, server)]
        for thread in threads: thread.start()
        def get(path, headers=None):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            try:
                client.request('GET', path, headers=headers or {});response=client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally: client.close()
        try:
            base = f'http://127.0.0.1:{upstream.server_port}'
            headers = {'Referer': 'https://source.test/', 'Cookie': 'fixture-cookie', 'Authorization': 'fixture-auth'}
            token = server.relay.register(base + '/index.m3u8', headers)
            status, _, body = get('/media/' + token)
            self.assertEqual(status, 200)
            segment = body.decode().strip().splitlines()[-1]
            status, response_headers, body = get(urllib.parse.urlsplit(segment).path, {'Range': 'bytes=2-5'})
            self.assertEqual((status, body, response_headers['Content-Range']), (206, b'2345', 'bytes 2-5/10'))
            self.assertEqual(received[-1][1]['Cookie'], 'fixture-cookie')
            self.assertEqual(received[-1][1]['Referer'], 'https://source.test/')
            token = server.relay.register(base + '/redirect', headers)
            self.assertEqual(get('/media/' + token)[0], 200)
            self.assertNotIn('Cookie', received[-1][1]);self.assertNotIn('Authorization', received[-1][1])
            self.assertEqual(get('/media/unknown')[0], 404)
            server.relay.close()
            self.assertEqual(get('/media/' + token)[0], 404)
        finally:
            for item in (upstream, server): item.shutdown();item.server_close()
            for thread in threads: thread.join(2)


if __name__ == '__main__':
    unittest.main()
