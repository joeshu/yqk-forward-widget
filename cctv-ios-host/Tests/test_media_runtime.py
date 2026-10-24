import http.client
import http.server
import importlib.util
import json
import os
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

    def test_identical_inflight_catalog_requests_merge_but_parameters_stay_isolated(self):
        original = self.engine.call
        entered = threading.Event()
        waiter_entered = threading.Event()
        release = threading.Event()
        calls = []
        results = []
        class ObservedWait:
            def __init__(self): self.event = threading.Event()
            def wait(self, timeout=None):
                waiter_entered.set()
                return self.event.wait(timeout)
            def set(self): self.event.set()
            def is_set(self): return self.event.is_set()
        class ObservedFlight:
            def __init__(self):
                self.ready = ObservedWait()
                self.value = None
                self.error = None
        def delayed(operation, args):
            calls.append((operation, dict(args)))
            if args.get('keyword') == 'same':
                entered.set()
                self.assertTrue(release.wait(2))
            return original(operation, args)
        with mock.patch.object(self.engine, 'call', side_effect=delayed), mock.patch.object(media, '_MediaFlight', ObservedFlight):
            first = threading.Thread(target=lambda: results.append(self.runtime.call('search', {'keyword': 'same', 'page': 1})))
            second = threading.Thread(target=lambda: results.append(self.runtime.call('search', {'keyword': 'same', 'page': 1})))
            try:
                first.start()
                self.assertTrue(entered.wait(2))
                second.start()
                self.assertTrue(waiter_entered.wait(2))
            finally:
                release.set()
                first.join(2)
                if second.ident is not None:
                    second.join(2)
            self.assertFalse(first.is_alive())
            self.assertFalse(second.is_alive())
            self.assertEqual(len(results), 2)
            self.assertEqual(len(calls), 1)
            different = self.runtime.call('search', {'keyword': 'different', 'page': 1})
            self.assertEqual(different['items'][0]['name'], 'different')
            self.assertEqual(len(calls), 2)

    def test_playback_marks_web_tasks_and_rejects_invalid_schemes(self):
        self.assertEqual(media.playback({'parse': 1, 'url': 'https://a.test/'})['parse'], 1)
        for result in [{'url': 'file:///private/data'}, {'url': ''}]:
            with self.assertRaises(media.MediaError):
                media.playback(result)
        with self.assertRaises(media.MediaError):
            media.playback({'url': 'https://user:pass@example.test/video'})
        value = media.playback({'url': 'https://a.test/video', 'header': {'X-Foo': 'ok', 'Cookie': 'one\r\ntwo', 'Host': 'spoof'}})
        self.assertEqual(value['headers'], {'X-Foo': 'ok'})
        text_headers = media.playback({'url': 'https://a.test/video', 'header': 'User-Agent$fixture#Referer$https://a.test/'})
        self.assertEqual(text_headers['headers'], {'User-Agent': 'fixture', 'Referer': 'https://a.test/'})
        choices = media.playback({'url': {'values': [{'name': '1080P', 'url': 'https://a.test/1080.m3u8'},
                                                      {'name': '720P', 'url': 'https://a.test/720.m3u8'}],
                                  'headers': {'Referer': 'https://a.test/'}}})
        self.assertEqual(choices['url'], 'https://a.test/1080.m3u8')
        self.assertEqual(choices['alternates'][1]['name'], '720P')
        self.assertEqual(choices['headers']['Referer'], 'https://a.test/')

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

    def test_failed_spider_import_does_not_leave_package_modules_loaded(self):
        helper = Path(self.tmp.name, '_fixture_import_helper.py')
        entry = Path(self.tmp.name, 'broken_spider.py')
        helper.write_text('VALUE = 1')
        entry.write_text('import _fixture_import_helper\nraise RuntimeError("fixture init failed")')
        with self.assertRaisesRegex(RuntimeError, 'fixture init failed'):
            media.PythonSpider(self.tmp.name, entry.name)
        self.assertNotIn('_fixture_import_helper', sys.modules)
        self.assertIn(self.engine.module_name, sys.modules)
        self.assertIn(self.tmp.name, sys.path)  # The already-running Spider still owns this import path.

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
            self.engine.spider.playerContent = lambda *_: {'parse': 1, 'url': 'https://a.test/direct.m3u8?token=x', 'header': {'Referer': 'https://a.test/'}}
            status, reply = request('/api/v1/play', 'POST', {'id': 'direct'})
            self.assertEqual(status, 200)
            self.assertEqual(reply['data']['parse'], 1)
            self.assertTrue(reply['data']['url'].startswith(f'http://127.0.0.1:{server.server_port}/media/'))
            self.assertEqual(reply['data']['originalURL'], 'https://a.test/direct.m3u8?token=x')
            self.engine.spider.playerContent = lambda *_: {'parse': 1, 'url': 'https://a.test/watch?id=direct', 'header': {'Referer': 'https://a.test/'}}
            status, reply = request('/api/v1/play', 'POST', {'id': 'web'})
            self.assertEqual(status, 200)
            self.assertEqual(reply['data']['url'], 'https://a.test/watch?id=direct')
            self.assertNotIn('originalURL', reply['data'])
            self.assertEqual(request('/missing')[0], 404)
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_catpaw_local_route_is_reachable_for_avplayer_and_head_probes(self):
        class RouteEngine:
            def __init__(self): self.requests = []
            def capabilities(self): return {'capabilities': ['home', 'play', 'proxy']}
            def call(self, operation, args):
                self.requests.append((operation, args))
                if operation == 'route':
                    return {'statusCode': 200, 'headers': {'content-type': 'application/vnd.apple.mpegurl'},
                            'body': '#EXTM3U\n#EXTINF:6,\nsegment.ts\n'}
                return {}
            def close(self): pass
        engine = RouteEngine()
        runtime = media.MediaRuntime(engine)
        server = transport.Server(('127.0.0.1', 0), runtime)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(method, path):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            try:
                client.request(method, path, headers={'Range': 'bytes=0-10', 'User-Agent': 'fixture-agent'})
                response = client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally: client.close()
        try:
            path = '/spider/demo/3/proxy/index.m3u8?token=fixture'
            status, headers, body = request('GET', path)
            self.assertEqual((status, body), (200, b'#EXTM3U\n#EXTINF:6,\nsegment.ts\n'))
            self.assertEqual(next(value for key, value in headers.items() if key.lower() == 'content-type'), 'application/vnd.apple.mpegurl')
            args = engine.requests[-1][1]
            self.assertEqual((args['method'], args['path'], args['query']['token'], args['headers']['Range']),
                             ('GET', '/spider/demo/3/proxy/index.m3u8', 'fixture', 'bytes=0-10'))
            self.assertEqual(args['host'], f'127.0.0.1:{server.server_port}')
            status, _, body = request('HEAD', path)
            self.assertEqual((status, body), (200, b''))
            self.assertEqual(engine.requests[-1][1]['method'], 'HEAD')
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            thread.join(2)
            runtime.close()

    def test_python_spider_proxy_preserves_http_headers_ranges_and_head(self):
        calls = []
        def local_proxy(args):
            calls.append(args)
            headers = {'Content-Type': 'video/mp2t', 'Content-Range': 'bytes 2-5/10',
                       'Accept-Ranges': 'bytes', 'Content-Length': '999', 'Connection': 'keep-alive',
                       'X-Fixture': 'ok'}
            if args['method'] == 'HEAD':
                headers['Content-Length'] = '4'
            return [206, headers, b'' if args['method'] == 'HEAD' else b'2345']
        self.engine.spider.localProxy = local_proxy
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(method):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            try:
                client.request(method, '/proxy?url=https%3A%2F%2Ffixture.test%2Fsegment.ts',
                               headers={'Range': 'bytes=2-5', 'User-Agent': 'fixture-agent'})
                response = client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                client.close()
        try:
            status, headers, body = request('GET')
            lower = {key.lower(): value for key, value in headers.items()}
            self.assertEqual((status, body, lower['content-type'], lower['content-range']),
                             (206, b'2345', 'video/mp2t', 'bytes 2-5/10'))
            self.assertEqual(lower['content-length'], '4')
            self.assertEqual(lower['x-fixture'], 'ok')
            self.assertEqual(lower['connection'], 'close')
            self.assertEqual(calls[-1]['method'], 'GET')
            self.assertEqual(calls[-1]['headers']['Range'], 'bytes=2-5')
            status, headers, body = request('HEAD')
            self.assertEqual((status, body), (206, b''))
            self.assertEqual({key.lower(): value for key, value in headers.items()}['content-length'], '4')
            self.assertEqual(calls[-1]['method'], 'HEAD')
        finally:
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

    def test_python_spider_play_reaches_hls_segment_through_local_relay(self):
        received = []
        segment_data = b'0123456789'
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append((self.path, dict(self.headers)))
                if self.path == '/index.m3u8':
                    body = b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                elif self.path == '/segment.ts':
                    range_value = self.headers.get('Range')
                    if range_value == 'bytes=2-5':
                        body = segment_data[2:6]
                        self.send_response(206)
                        self.send_header('Content-Range', 'bytes 2-5/10')
                    else:
                        body = segment_data
                        self.send_response(200)
                    self.send_header('Content-Type', 'video/mp2t')
                    self.send_header('Accept-Ranges', 'bytes')
                else:
                    self.send_error(404)
                    return
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        self.engine.spider.playerContent = lambda *_: {
            'parse': 0, 'url': f'http://127.0.0.1:{upstream.server_port}/index.m3u8',
            'header': {'Referer': f'http://127.0.0.1:{upstream.server_port}/',
                       'User-Agent': 'fixture-player', 'Cookie': 'fixture-cookie'}}
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        service_thread = threading.Thread(target=server.serve_forever, daemon=True)
        service_thread.start()
        def request(method, path, headers=None, data=None):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
            try:
                body = json.dumps(data).encode() if data is not None else None
                client.request(method, path, body, headers or {})
                response = client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                client.close()
        try:
            status, _, response = request('POST', '/api/v1/play', {'Content-Type': 'application/json'}, {'id': 'episode-1'})
            self.assertEqual(status, 200)
            proxy = json.loads(response)['data']['url']
            status, _, playlist = request('GET', urllib.parse.urlsplit(proxy).path)
            self.assertEqual(status, 200)
            lines = playlist.decode().splitlines()
            segment_url = next(line for line in lines if line and not line.startswith('#'))
            self.assertTrue(segment_url.startswith(f'http://127.0.0.1:{server.server_port}/media/'))
            status, response_headers, body = request('GET', urllib.parse.urlsplit(segment_url).path,
                                                     {'Range': 'bytes=2-5'})
            lower = {key.lower(): value for key, value in response_headers.items()}
            self.assertEqual((status, body, lower['content-range']), (206, b'2345', 'bytes 2-5/10'))
            self.assertEqual(received[-1][1]['Range'], 'bytes=2-5')
            self.assertEqual(received[-1][1]['Cookie'], 'fixture-cookie')
            self.assertEqual(received[-1][1]['Referer'], f'http://127.0.0.1:{upstream.server_port}/')
            self.assertEqual(received[-1][1]['User-Agent'], 'fixture-player')
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            service_thread.join(2)
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(2)


if __name__ == '__main__':
    unittest.main()
