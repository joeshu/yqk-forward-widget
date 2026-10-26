import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from unittest import mock

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
import host_media_runtime as media
from host_media_relay import MediaRelay, safe_error_summary
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

    def test_detail_preserves_optional_metadata_for_native_film_page(self):
        detail = media.detail({'vod_id': 'film-1', 'vod_name': '影片',
                               'vod_content': '简介', 'vod_actor': '演员',
                               'vod_year': '2026', 'vod_area': '中国大陆',
                               'vod_lang': '普通话', 'vod_class': '剧集',
                               'vod_director': '导演', 'vod_remarks': '更新中',
                               'backdrop': 'https://example.test/banner.jpg',
                               'vod_play_from': '主线', 'vod_play_url': '第1集$opaque'},
                              'film-1')
        self.assertEqual((detail['year'], detail['area'], detail['lang'], detail['type']),
                         ('2026', '中国大陆', '普通话', '剧集'))
        self.assertEqual((detail['director'], detail['remarks'], detail['banner']),
                         ('导演', '更新中', 'https://example.test/banner.jpg'))
        self.assertEqual(detail['description'], '简介')

    def test_detail_normalizes_url_episodes_for_native_picker(self):
        value = media.detail({'vod_id': 'film-2', 'vod_name': 'URL 分集',
                              'episodes': [{'title': '第 1 集', 'url': 'https://cdn.test/one?token=a%2Bb'},
                                           {'name': '第 2 集', 'id': 'opaque-2'},
                                           {'name': '缺少地址'}]}, 'film-2')
        self.assertEqual(value['lines'][0]['episodes'], [
            {'id': 'https://cdn.test/one?token=a%2Bb', 'name': '第 1 集'},
            {'id': 'opaque-2', 'name': '第 2 集'},
        ])

    def test_detail_unwraps_common_provider_envelopes_and_episode_aliases(self):
        value = media.detail({'code': 200, 'data': {'vod_info': {
            'vod_id': 'wrapped-film', 'vod_name': '包装详情',
            'episodes': [{'label': '第 1 集', 'play_url': 'https://cdn.test/1.m3u8?token=a%2Fb'},
                         {'title': '第 2 集', 'value': 'opaque-2'}]}}}, 'wrapped-film')
        self.assertEqual(value['name'], '包装详情')
        self.assertEqual(value['lines'][0]['episodes'], [
            {'id': 'https://cdn.test/1.m3u8?token=a%2Fb', 'name': '第 1 集'},
            {'id': 'opaque-2', 'name': '第 2 集'},
        ])

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
        self.assertEqual(media.playback({'jx': 1, 'url': 'https://a.test/watch'})['jx'], 1)
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

    def test_playback_removes_only_redundant_hls_format_suffix(self):
        signed = 'https://a.test/master.m3u8?token=a%2Fb&expires=123&format=.m3u8'
        repaired = media.playback({'url': signed, 'parse': 0, 'format': 'hls',
                                   'contentType': 'application/vnd.apple.mpegurl',
                                   'header': {'Referer': 'https://a.test/'}})
        self.assertEqual(repaired['url'], 'https://a.test/master.m3u8?token=a%2Fb&expires=123')
        self.assertEqual(repaired['headers']['Referer'], 'https://a.test/')
        # Do not rewrite an extensionless endpoint, a non-HLS response, or a
        # playlist whose path has no .m3u8 extension.
        extensionless = 'https://a.test/media?token=x&format=.m3u8'
        self.assertEqual(media.playback({'url': extensionless, 'format': 'hls'})['url'], extensionless)
        explicit = 'https://a.test/master.m3u8?format=.m3u8'
        self.assertEqual(media.playback({'url': explicit, 'format': 'mp4'})['url'], explicit)

    def test_playback_normalizes_nested_media_metadata_and_legacy_url_shapes(self):
        wrapped = media.playback({'code': 1, 'parse': '0', 'headers': {'X-Shared': 'top'},
            'data': {'url': {'url': '//cdn.test/manifest.php?token=a%2Fb', 'format': 'hls',
                            'contentType': 'application/vnd.apple.mpegurl',
                            'header': {'Referer': 'https://site.test/'}}}})
        self.assertEqual(wrapped['url'], 'https://cdn.test/manifest.php?token=a%2Fb')
        self.assertEqual(wrapped['headers'], {'X-Shared': 'top', 'Referer': 'https://site.test/'})
        self.assertTrue(wrapped['nativePlayable'])
        self.assertFalse(wrapped['requiresWebPlayback'])
        self.assertEqual(wrapped['contentType'], 'application/vnd.apple.mpegurl')
        self.assertEqual(media.playback({'url': ['//cdn.test/1.m3u8', 'https://cdn.test/2.m3u8']})['url'],
                         'https://cdn.test/1.m3u8')
        self.assertEqual(len(media.playback({'url': ['https://cdn.test/1.m3u8',
                                                     'https://cdn.test/2.m3u8']})['alternates']), 2)
        self.assertFalse(media.playback({'url': 'https://cdn.test/1.m3u8',
                                         'requiresWebPlayback': 'false'})['requiresWebPlayback'])
        quality_list = media.playback({'url': [
            {'name': '主线路', 'url': 'https://cdn.test/manifest.php?token=one',
             'format': 'hls', 'parse': 1,
             'header': {'Referer': 'https://site.test/'}, 'headers': {'X-Quality': 'main'}},
            {'name': '备用', 'url': 'https://cdn.test/backup.m3u8'}]})
        self.assertTrue(quality_list['nativePlayable'])
        self.assertFalse(quality_list['requiresWebPlayback'])
        self.assertEqual(quality_list['headers'], {'Referer': 'https://site.test/',
                                                    'X-Quality': 'main'})
        self.assertEqual(quality_list['alternates'][0]['format'], 'hls')

    def test_playback_decodes_html_escaped_hls_query_separators(self):
        encoded = 'https://a.test/master.m3u8?token=a%2Fb&amp;expires=123&amp;format=.m3u8'
        repaired = media.playback({'url': encoded, 'format': 'hls'})
        self.assertEqual(repaired['url'], 'https://a.test/master.m3u8?token=a%2Fb&expires=123')

    def test_playback_preserves_safe_headers_per_quality_choice(self):
        choices = media.playback({'url': {'values': [
            {'name': '1080P', 'url': 'https://a.test/1080.m3u8',
             'headers': {'X-Quality': 'high', 'Host': 'spoof'}},
            {'name': '720P', 'url': 'https://a.test/720.m3u8',
             'header': 'X-Quality$low#Referer$https://a.test/watch'}],
            'headers': {'X-Shared': 'source'}}})
        # The first quality is the primary URL, so its request headers must be
        # used immediately. Keep source-wide headers separately so selecting a
        # different quality does not inherit the first quality's credentials.
        self.assertEqual(choices['headers'], {'X-Shared': 'source', 'X-Quality': 'high'})
        self.assertEqual(choices['baseHeaders'], {'X-Shared': 'source'})
        self.assertEqual(choices['alternates'][0]['headers'], {'X-Quality': 'high'})
        self.assertEqual(choices['alternates'][1]['headers'], {
            'X-Quality': 'low', 'Referer': 'https://a.test/watch'})

    def test_top_level_alternates_keep_quality_specific_headers(self):
        value = media.playback({'url': 'https://a.test/default.m3u8',
                                'alternates': [{'name': '专用线路', 'url': 'https://a.test/specific.m3u8',
                                                'header': {'X-Quality': 'specific'}}]})
        self.assertEqual(value['alternates'][0]['headers'], {'X-Quality': 'specific'})

    def test_plugin_error_summary_keeps_reason_but_redacts_signed_urls(self):
        value = safe_error_summary('source timeout at https://cdn.test/session?access_token=private-value')
        self.assertIn('source timeout', value)
        self.assertNotIn('cdn.test', value)
        self.assertNotIn('private-value', value)
        self.assertLessEqual(len(safe_error_summary('x' * 500)), 180)

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
        self.assertIn(os.path.realpath(self.tmp.name), [os.path.realpath(path) for path in sys.path])  # The running Spider owns this import path, regardless of macOS's /var symlink.

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

    def test_health_listener_is_available_while_spider_initializes(self):
        entered = threading.Event()
        release = threading.Event()
        class Engine:
            def capabilities(self): return {'capabilities': ['home']}
            def call(self, operation, args): return {}
            def close(self): pass
        runtime = media.MediaRuntime()
        def initialize():
            entered.set()
            release.wait(2)
            return Engine()
        runtime.start_initialization(initialize)
        server = transport.Server(('127.0.0.1', 0), runtime)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(path):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)
            try:
                client.request('GET' if path == '/health' else 'POST', path,
                               None if path == '/health' else b'{}',
                               {} if path == '/health' else {'Content-Type': 'application/json'})
                response = client.getresponse()
                return response.status, json.loads(response.read())
            finally:
                client.close()
        try:
            self.assertTrue(entered.wait(1))
            status, health = request('/health')
            self.assertEqual(status, 200)
            self.assertTrue(health['ok'])
            self.assertFalse(health['runtime_ready'])
            self.assertEqual(health['runtime_state'], 'starting')
            status, pending = request('/api/v1/capabilities')
            self.assertEqual(status, 503)
            self.assertEqual(pending['error']['code'], 'BUSY')
            self.assertTrue(pending['error']['retryable'])
            release.set()
            for _ in range(30):
                status, ready = request('/api/v1/capabilities')
                if status == 200:
                    break
                threading.Event().wait(.02)
            self.assertEqual(status, 200)
            self.assertEqual(ready['data']['capabilities'], ['home'])
            self.assertTrue(request('/health')[1]['runtime_ready'])
        finally:
            release.set()
            runtime.close()
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_failed_async_spider_initialization_is_reported_not_left_busy(self):
        runtime = media.MediaRuntime()
        def initialize(): raise RuntimeError('fixture init failure')
        runtime.start_initialization(initialize)
        try:
            for _ in range(50):
                if runtime.health_status()['runtime_state'] == 'failed':
                    break
                threading.Event().wait(.02)
            self.assertEqual(runtime.health_status()['runtime_state'], 'failed')
            with self.assertRaises(media.MediaError) as failure:
                runtime.call('capabilities')
            self.assertEqual(failure.exception.code, 'STARTUP_FAILED')
            self.assertFalse(failure.exception.retryable)
        finally:
            runtime.close()

    def test_async_initialization_preserves_host_service_context(self):
        class Owner:
            def __init__(self):
                self.stopping = threading.Event()
                self.threads = set()
        owner = Owner()
        runtime = media.MediaRuntime()
        observed = []
        class Engine:
            def capabilities(self): return {'capabilities': []}
            def call(self, operation, args): return {}
            def close(self): pass
        previous = getattr(threading.current_thread(), '_host_session', None)
        threading.current_thread()._host_session = owner
        try:
            runtime.start_initialization(lambda: observed.append(
                getattr(threading.current_thread(), '_host_session', None)) or Engine())
            runtime._startup_thread.join(2)
            self.assertFalse(runtime._startup_thread.is_alive())
            self.assertEqual(observed, [owner])
            self.assertEqual(runtime.health_status()['runtime_state'], 'ready')
        finally:
            if previous is None:
                del threading.current_thread()._host_session
            else:
                threading.current_thread()._host_session = previous
            runtime.close()

    def test_engine_created_after_stop_is_closed_without_becoming_ready(self):
        entered = threading.Event()
        release = threading.Event()
        closed = threading.Event()
        class Engine:
            def close(self): closed.set()
        runtime = media.MediaRuntime()
        def initialize():
            entered.set()
            release.wait(2)
            return Engine()
        runtime.start_initialization(initialize)
        self.assertTrue(entered.wait(1))
        runtime.close()
        release.set()
        runtime._startup_thread.join(2)
        self.assertFalse(runtime._startup_thread.is_alive())
        self.assertTrue(closed.is_set())
        self.assertEqual(runtime.health_status()['runtime_state'], 'stopping')

    def test_configuration_refresh_discards_old_inflight_result_and_cache(self):
        entered=threading.Event();release=threading.Event();errors=[]
        class Engine:
            count=0
            def capabilities(self):return {}
            def call(self,operation,args):
                self.count+=1;current=self.count
                if current==1:entered.set();release.wait(3)
                return {'list':[{'vod_id':str(current),'vod_name':'version '+str(current)}]}
            def close(self):pass
        engine=Engine();runtime=media.MediaRuntime(engine)
        def old_request():
            try:runtime.call('home')
            except media.MediaError as error:errors.append(error.code)
        thread=threading.Thread(target=old_request);thread.start();self.assertTrue(entered.wait(1))
        try:
            self.assertTrue(runtime.call('invalidate')['invalidated'])
            self.assertEqual(runtime.call('home')['items'][0]['id'],'2')
            release.set();thread.join(2)
            self.assertEqual(errors,['REFRESHED'])
            self.assertEqual(runtime.call('home')['items'][0]['id'],'2')
            self.assertEqual(engine.count,2)
        finally:release.set();thread.join(2);runtime.close()

    def test_empty_detail_result_is_not_reported_as_a_loaded_movie(self):
        with self.assertRaises(media.MediaError) as failure:
            media.detail({'list': []}, 'missing')
        self.assertEqual(failure.exception.code,'NO_DETAIL')

    def test_protected_artwork_uses_separate_relay_and_configuration_is_reachable(self):
        observed=[]
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def do_GET(self):
                observed.append((self.path,self.headers.get('Cookie')))
                body=b'fixture-image'
                self.send_response(200 if self.headers.get('Cookie')=='web_token=fixture' else 401)
                self.send_header('Content-Type','image/png');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        upstream=http.server.ThreadingHTTPServer(('127.0.0.1',0),Upstream)
        threading.Thread(target=upstream.serve_forever,daemon=True).start()
        poster=f'http://127.0.0.1:{upstream.server_port}/image.png?ticket=fixture'
        class Engine:
            def capabilities(self):return {'capabilities':['home','configuration']}
            def call(self,operation,args):
                if operation=='configuration':return {'url':f'http://127.0.0.1:{upstream.server_port}/website','configurationPage':True}
                return {'list':[{'vod_id':'id','vod_name':'Movie','vod_pic':poster,'posterHeaders':{'Cookie':'web_token=fixture'}}]}
            def close(self):pass
        runtime=media.MediaRuntime(Engine());server=transport.Server(('127.0.0.1',0),runtime)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        def request(path):
            client=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            try:
                client.request('GET',path);response=client.getresponse();return response.status,response.read()
            finally:client.close()
        try:
            status,body=request('/api/v1/home');self.assertEqual(status,200)
            self.assertNotIn(b'web_token',body);self.assertNotIn(b'posterHeaders',body)
            item=json.loads(body)['data']['items'][0];self.assertIn('/artwork/',item['poster'])
            token=server.relay.register('https://fixture.test/active.m3u8',{})
            for index in range(300):server.artwork_relay.register(f'https://fixture.test/{index}.png',{})
            self.assertIn(token,server.relay.targets)
            # Re-register after deliberately overflowing only the artwork budget.
            _,body=request('/api/v1/home');item=json.loads(body)['data']['items'][0]
            self.assertEqual(request(urllib.parse.urlsplit(item['poster']).path),(200,b'fixture-image'))
            self.assertEqual(observed[-1],('/image.png?ticket=fixture','web_token=fixture'))
            _,body=request('/api/v1/configuration');self.assertTrue(json.loads(body)['data']['configurationPage'])
        finally:
            server.shutdown();server.server_close();runtime.close();upstream.shutdown();upstream.server_close()

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

    def test_relay_refresh_updates_expiring_manifest_and_rebases_child_playlist(self):
        relay=MediaRelay(limit=8)
        refreshes=[]
        def refresh():
            refreshes.append(1)
            return {'url':'https://new.test/live/master.m3u8?token=new',
                    'headers':{'Referer':'https://new.test/'},
                    'refreshInterval':30,'refreshAfter':time.time()+30}
        root=relay.register('https://old.test/live/master.m3u8?token=old',{},refresh=refresh,
                            refresh_after=time.time()-1,refresh_interval=30)
        updated=relay._refresh_record(root)
        self.assertEqual(updated[0][0],'https://new.test/live/master.m3u8?token=new')
        self.assertEqual(dict(updated[0][1])['Referer'],'https://new.test/')
        self.assertEqual(len(refreshes),1)
        rewritten=relay.rewrite('#EXTM3U\nvariants/720/index.m3u8\n',
            'https://old.test/live/master.m3u8?token=old',{},('https','old.test'),
            'http://127.0.0.1:18780','refresh-child',refresh=refresh,
            refresh_after=time.time()-1,refresh_interval=30)
        token=rewritten.splitlines()[-1].rsplit('/',1)[-1]
        child=relay._refresh_record(token)
        self.assertEqual(child[0][0],'https://new.test/live/variants/720/index.m3u8?token=new')
        self.assertEqual(len(refreshes),2)
        nested=relay.rewrite('#EXTM3U\navc1/index.m3u8\n',child[0][0],dict(child[0][1]),child[0][2],
            'http://127.0.0.1:18780','nested-child',refresh=refresh,
            refresh_after=time.time()-1,refresh_interval=30,refresh_relative_base=child[6])
        nested_token=nested.splitlines()[-1].rsplit('/',1)[-1]
        grandchild=relay._refresh_record(nested_token)
        self.assertEqual(grandchild[0][0],'https://new.test/live/variants/720/avc1/index.m3u8?token=new')
        self.assertEqual(len(refreshes),3)
        relay.close()

    def test_failed_refresh_is_coalesced_and_uses_bounded_backoff(self):
        relay=MediaRelay(limit=8)
        calls=[]
        def refresh():
            calls.append(1)
            raise OSError('upstream unavailable')
        token=relay.register('https://old.test/live/master.m3u8',{},refresh=refresh,
                             refresh_after=time.time()-1,refresh_interval=5)
        with self.assertRaisesRegex(Exception,'media_refresh_failed'):
            relay._refresh_record(token)
        with self.assertRaisesRegex(Exception,'media_refresh_backoff'):
            relay._refresh_record(token,force=True)
        self.assertEqual(len(calls),1)
        relay.close()

    def test_relay_inherits_signed_query_for_same_origin_children_only(self):
        relay = MediaRelay(limit=8)
        source = 'https://a.test/path/master.m3u8?token=shared%2Bvalue&expires=123'
        text = ('#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\n'
                'segments/one.ts\n/root/two.ts\nhttps://b.test/three.ts\n'
                'https://a.test/absolute.ts\nhttps://a.test/own.ts?part_signature=own-value\n'
                '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://asset-id"\n')
        rewritten = relay.rewrite(text, source, {}, ('https', 'a.test'),
                                  'http://127.0.0.1:18780', 'play-correlation')
        self.assertIn('URI="skd://asset-id"', rewritten)
        self.assertNotIn('segments/one.ts', rewritten)
        self.assertNotIn('/root/two.ts', rewritten)
        targets = {record[0][0]: record for record in relay.targets.values()}
        self.assertIn('https://a.test/path/segments/one.ts?token=shared%2Bvalue&expires=123', targets)
        self.assertIn('https://a.test/root/two.ts?token=shared%2Bvalue&expires=123', targets)
        self.assertIn('https://a.test/path/keys/key.bin?token=shared%2Bvalue&expires=123', targets)
        self.assertIn('https://b.test/three.ts', targets)
        self.assertIn('https://a.test/absolute.ts?token=shared%2Bvalue&expires=123', targets)
        self.assertIn('https://a.test/own.ts?part_signature=own-value', targets)
        self.assertNotIn('token=shared%2Bvalue', targets['https://b.test/three.ts'][0][0])
        self.assertNotIn('token=shared%2Bvalue', targets['https://a.test/own.ts?part_signature=own-value'][0][0])
        self.assertEqual(targets['https://a.test/path/segments/one.ts?token=shared%2Bvalue&expires=123'][2], 'play-correlation')
        fallback = targets['https://a.test/path/segments/one.ts?token=shared%2Bvalue&expires=123'][0][3]
        self.assertEqual(fallback, 'https://a.test/path/segments/one.ts')
        relay.close()

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

    def test_relay_surfaces_upstream_status_and_logs_correlated_redacted_failure(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append(self.path)
                self.send_response(403)
                self.send_header('Content-Length', '0')
                self.end_headers()
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        threads = [threading.Thread(target=item.serve_forever, daemon=True) for item in (upstream, server)]
        for thread in threads: thread.start()
        client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
        try:
            target = f'http://127.0.0.1:{upstream.server_port}/denied.m3u8?signature=do-not-log'
            token = server.relay.register(target, {}, diagnostic_id='playback-trace-7')
            with mock.patch('builtins.print') as log:
                client.request('GET', '/media/' + token)
                response = client.getresponse()
                body = response.read()
                record = ''.join(str(call.args[0]) for call in log.call_args_list)
            self.assertEqual(response.status, 403)
            self.assertEqual(response.getheader('X-CCTVHost-Relay-Stage'), 'upstream_http_error')
            self.assertEqual(response.getheader('X-CCTVHost-Request-ID'), 'playback-trace-7')
            self.assertIn(b'upstream_http_error', body)
            self.assertEqual(received, ['/denied.m3u8?signature=do-not-log'])
            self.assertIn('playback-trace-7', record)
            self.assertNotIn('do-not-log', record)
        finally:
            client.close()
            for item in (upstream, server): item.shutdown();item.server_close()
            for thread in threads: thread.join(2)

    def test_live_playlist_route_preserves_source_query_and_refreshes_host_media_session(self):
        received=[]
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self,*_):pass
            def do_GET(self):
                received.append(self.path)
                if urllib.parse.urlsplit(self.path).path=='/fresh.m3u8':
                    body=b'#EXTM3U\n#EXTINF:6,\nsegment.ts\n'
                    self.send_response(200);self.send_header('Content-Type','application/vnd.apple.mpegurl')
                elif urllib.parse.urlsplit(self.path).path=='/segment.ts':
                    body=b'segment-data';self.send_response(200);self.send_header('Content-Type','video/mp2t')
                else:
                    self.send_error(404);return
                self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        upstream=http.server.ThreadingHTTPServer(('127.0.0.1',0),Upstream)
        base='http://127.0.0.1:'+str(upstream.server_port)
        class Engine:
            def __init__(self):self.calls=[]
            def capabilities(self):return {'capabilities':['live']}
            def call(self,operation,args):
                self.calls.append((operation,dict(args)))
                if operation=='resolve':
                    return {'url':base+'/old.m3u8?token=old','headers':{},'sessionID':'session-ysp',
                            'expiresAt':time.time()+60,'refreshInterval':5,'refreshAfter':time.time()-1}
                if operation=='refreshMedia':
                    return {'url':base+'/fresh.m3u8?token=fresh','headers':{},
                            'expiresAt':time.time()+60,'refreshInterval':30,'refreshAfter':time.time()+30}
                raise AssertionError(operation)
            def close(self):pass
        engine=Engine();runtime=media.MediaRuntime(engine)
        server=transport.Server(('127.0.0.1',0),runtime)
        threads=[threading.Thread(target=item.serve_forever,daemon=True) for item in (upstream,server)]
        for thread in threads:thread.start()
        client=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=4)
        try:
            client.request('GET','/live/cctv1.m3u8?source=bk&rate=fhd')
            response=client.getresponse();response.read();self.assertEqual(response.status,302)
            media_path=urllib.parse.urlsplit(response.getheader('Location')).path
            client.request('GET',media_path);response=client.getresponse();playlist=response.read()
            self.assertEqual(response.status,200);self.assertIn(b'/media/',playlist)
            self.assertIn(('resolve',{'ref':'cctv1','id':'cctv1','query':{'source':'bk','rate':'fhd'},
                'selfBase':'http://127.0.0.1:'+str(server.server_port),'userAgent':''}),engine.calls)
            self.assertTrue(any(operation=='refreshMedia' and args['sessionID']=='session-ysp' for operation,args in engine.calls))
            self.assertIn('/fresh.m3u8?token=fresh',received)
            child=next(line for line in playlist.decode().splitlines() if line.startswith('http://127.0.0.1:'))
            client.request('GET',urllib.parse.urlsplit(child).path);response=client.getresponse()
            self.assertEqual((response.status,response.read()),(200,b'segment-data'))
            self.assertIn('/segment.ts?token=fresh',received)
        finally:
            client.close();runtime.close()
            for item in (upstream,server):item.shutdown();item.server_close()
            for thread in threads:thread.join(2)

    def test_live_catalog_becomes_channel_page_m3u_entries(self):
        class Engine:
            def capabilities(self):return {'capabilities':['live']}
            def call(self,operation,args):
                if operation=='catalog':return [{'id':'cctv1','name':'CCTV-1 综合','group':'央视','logo':'https://logo.test/cctv1.png'}]
                raise AssertionError(operation)
            def close(self):pass
        runtime=media.MediaRuntime(Engine());server=transport.Server(('127.0.0.1',0),runtime)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        client=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
        try:
            client.request('GET','/all.m3u');response=client.getresponse();playlist=response.read().decode()
            self.assertEqual(response.status,200)
            self.assertIn('#EXTM3U',playlist)
            self.assertIn('group-title="央视",CCTV-1 综合',playlist)
            self.assertIn(f'http://127.0.0.1:{server.server_port}/live/cctv1.m3u8',playlist)
        finally:
            client.close();runtime.close();server.shutdown();server.server_close();thread.join(2)

    def test_relay_falls_back_when_inherited_signature_is_scoped_to_manifest_path(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append(self.path)
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path == '/master.m3u8':
                    body = b'#EXTM3U\n#EXTINF:6,\nsegment.ts\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                elif parsed.path == '/segment.ts' and parsed.query:
                    body = b''
                    self.send_response(403)
                elif parsed.path == '/segment.ts':
                    body = b'segment-data'
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp2t')
                else:
                    self.send_error(404)
                    return
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        threads = [threading.Thread(target=item.serve_forever, daemon=True) for item in (upstream, server)]
        for thread in threads: thread.start()
        def get(path):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            try:
                client.request('GET', path)
                response = client.getresponse()
                return response.status, response.read()
            finally:
                client.close()
        try:
            master = f'http://127.0.0.1:{upstream.server_port}/master.m3u8?signature=master-only'
            token = server.relay.register(master, {}, diagnostic_id='manifest-scoped-signature')
            status, playlist = get('/media/' + token)
            self.assertEqual(status, 200)
            child = next(line for line in playlist.decode().splitlines() if line and not line.startswith('#'))
            status, segment = get(urllib.parse.urlsplit(child).path)
            self.assertEqual((status, segment), (200, b'segment-data'))
            self.assertEqual(received[-2:], ['/segment.ts?signature=master-only', '/segment.ts'])
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
                request_path = urllib.parse.urlsplit(self.path)
                if request_path.path == '/index.m3u8':
                    body = b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                elif request_path.path == '/segment.ts' and request_path.query == 'access_token=fixture-signature':
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
            'parse': 0, 'url': f'http://127.0.0.1:{upstream.server_port}/index.m3u8?access_token=fixture-signature',
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
            status, _, response = request('POST', '/api/v1/play', {'Content-Type': 'application/json', 'X-CCTVHost-Correlation-ID': 'play-correlation'}, {'id': 'episode-1'})
            self.assertEqual(status, 200)
            play_result = json.loads(response)['data']
            self.assertEqual(play_result['originalURL'], f'http://127.0.0.1:{upstream.server_port}/index.m3u8?access_token=fixture-signature')
            proxy = play_result['url']
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
            self.assertEqual(urllib.parse.urlsplit(received[-1][0]).query, 'access_token=fixture-signature')
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            service_thread.join(2)
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(2)

    def test_hls_is_relayed_even_when_source_does_not_require_headers(self):
        source_url = 'https://cdn.example/live.m3u8?token=signature'
        alternate_url = 'https://cdn.example/alternate.m3u8?token=alternate-signature'
        self.engine.spider.playerContent = lambda *_: {
            'parse': 0, 'url': source_url,
            'alternates': [{'name': '备用清晰度', 'url': alternate_url}],
        }
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
        try:
            body = json.dumps({'id': 'episode-1'}).encode()
            client.request('POST', '/api/v1/play', body,
                           {'Content-Type': 'application/json', 'Content-Length': str(len(body))})
            response = client.getresponse()
            payload = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertEqual(payload['data']['originalURL'], source_url)
            self.assertTrue(payload['data']['url'].startswith(f'http://127.0.0.1:{server.server_port}/media/'))
            alternate = payload['data']['alternates'][0]
            self.assertEqual(alternate['originalURL'], alternate_url)
            self.assertTrue(alternate['url'].startswith(f'http://127.0.0.1:{server.server_port}/media/'))
        finally:
            client.close()
            server.shutdown()
            server.server_close()
            thread.join(2)

    def test_extensionless_signed_hls_is_mime_sniffed_and_preserves_child_signature(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append(self.path)
                if self.path == '/manifest?access_token=fixture':
                    body = b'#EXTM3U\n#EXTINF:6,\nsegments/one.ts\n#EXT-X-ENDLIST\n'
                    content_type = 'application/vnd.apple.mpegurl'
                elif self.path == '/segments/one.ts?access_token=fixture':
                    body = b'signed-segment'
                    content_type = 'video/mp2t'
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        source_url = f'http://127.0.0.1:{upstream.server_port}/manifest?access_token=fixture'
        self.engine.spider.playerContent = lambda *_: {'parse': 0, 'url': source_url}
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        service_thread = threading.Thread(target=server.serve_forever, daemon=True)
        service_thread.start()
        def request(path):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
            try:
                client.request('GET', path)
                response = client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                client.close()
        try:
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
            try:
                body = json.dumps({'id': 'episode-1'}).encode()
                client.request('POST', '/api/v1/play', body, {'Content-Type': 'application/json'})
                response = client.getresponse()
                payload = json.loads(response.read())['data']
            finally:
                client.close()
            self.assertEqual(payload['originalURL'], source_url)
            self.assertIn('/media/', payload['url'])
            status, _, playlist = request(urllib.parse.urlsplit(payload['url']).path)
            self.assertEqual(status, 200)
            segment = next(line for line in playlist.decode().splitlines()
                           if line and not line.startswith('#'))
            status, _, data = request(urllib.parse.urlsplit(segment).path)
            self.assertEqual((status, data), (200, b'signed-segment'))
            self.assertEqual(received, ['/manifest?access_token=fixture',
                                        '/segments/one.ts?access_token=fixture'])
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            service_thread.join(2)
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(2)

    def test_declared_hls_on_php_endpoint_is_proxied_and_rewritten_without_headers(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append(self.path)
                if self.path == '/manifest.php?token=fixture':
                    body = b'#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/html; charset=utf-8')
                elif self.path == '/segment.ts?token=fixture':
                    body = b'fixture-ts-segment'
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp2t')
                else:
                    self.send_error(404)
                    return
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        source_url = f'http://127.0.0.1:{upstream.server_port}/manifest.php?token=fixture'
        self.engine.spider.playerContent = lambda *_: {
            'parse': 1, 'url': source_url, 'format': 'hls',
            'contentType': 'application/vnd.apple.mpegurl'}
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        service_thread = threading.Thread(target=server.serve_forever, daemon=True)
        service_thread.start()
        def request(method, path, data=None):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
            try:
                body = json.dumps(data).encode() if data is not None else None
                client.request(method, path, body,
                               {'Content-Type': 'application/json'} if body is not None else {})
                response = client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                client.close()
        try:
            status, _, body = request('POST', '/api/v1/play', {'id': 'episode-1'})
            self.assertEqual(status, 200)
            result = json.loads(body)['data']
            self.assertEqual(result['originalURL'], source_url)
            self.assertTrue(result['nativePlayable'])
            self.assertFalse(result['requiresWebPlayback'])
            status, headers, playlist = request('GET', urllib.parse.urlsplit(result['url']).path)
            self.assertEqual(status, 200)
            self.assertIn('mpegurl', next(value for key, value in headers.items()
                                          if key.lower() == 'content-type').lower())
            segment = next(line for line in playlist.decode().splitlines()
                           if line and not line.startswith('#'))
            status, _, body = request('GET', urllib.parse.urlsplit(segment).path)
            self.assertEqual((status, body), (200, b'fixture-ts-segment'))
            self.assertEqual(received, ['/manifest.php?token=fixture',
                                        '/segment.ts?token=fixture'])
        finally:
            server.relay.close()
            server.shutdown()
            server.server_close()
            service_thread.join(2)
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(2)

    def test_quality_specific_headers_reach_hls_alternate_and_its_segments(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append((self.path, dict(self.headers)))
                name = urllib.parse.urlsplit(self.path).path
                expected_quality = {'/alternate.m3u8': 'high', '/segment-high.ts': 'high',
                                    '/low.m3u8': 'low', '/segment-low.ts': 'low'}
                if (self.headers.get('X-Shared') != 'source' or
                        self.headers.get('X-Quality') != expected_quality.get(name)):
                    self.send_error(403)
                    return
                if self.path == '/alternate.m3u8':
                    body = b'#EXTM3U\n#EXTINF:6,\nsegment-high.ts\n#EXT-X-ENDLIST\n'
                    content_type = 'application/vnd.apple.mpegurl'
                elif self.path == '/low.m3u8':
                    body = b'#EXTM3U\n#EXTINF:6,\nsegment-low.ts\n#EXT-X-ENDLIST\n'
                    content_type = 'application/vnd.apple.mpegurl'
                elif self.path in ('/segment-high.ts', '/segment-low.ts'):
                    body = b'fixture-segment'
                    content_type = 'video/mp2t'
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        base = f'http://127.0.0.1:{upstream.server_port}'
        self.engine.spider.playerContent = lambda *_: {
            'url': base + '/primary.mp4', 'headers': {'X-Shared': 'source'},
            'alternates': [{'name': '高清', 'url': base + '/alternate.m3u8',
                            'headers': {'X-Quality': 'high'}},
                           {'name': '流畅', 'url': base + '/low.m3u8',
                            'headers': {'X-Quality': 'low'}}]}
        server = transport.Server(('127.0.0.1', 0), self.runtime)
        service_thread = threading.Thread(target=server.serve_forever, daemon=True)
        service_thread.start()
        def request(method, path, data=None):
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
            try:
                body = json.dumps(data).encode() if data is not None else None
                client.request(method, path, body,
                               {'Content-Type': 'application/json'} if body is not None else {})
                response = client.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            finally:
                client.close()
        try:
            status, _, body = request('POST', '/api/v1/play', {'id': 'episode-1'})
            self.assertEqual(status, 200)
            result = json.loads(body)['data']
            self.assertEqual(result['headers'], {'X-Shared': 'source'})
            self.assertEqual([item['headers']['X-Quality'] for item in result['alternates']],
                             ['high', 'low'])
            for alternate in result['alternates']:
                status, _, playlist = request('GET', urllib.parse.urlsplit(alternate['url']).path)
                self.assertEqual(status, 200)
                segment = next(line for line in playlist.decode().splitlines()
                               if line and not line.startswith('#'))
                status, _, segment_body = request('GET', urllib.parse.urlsplit(segment).path)
                self.assertEqual((status, segment_body), (200, b'fixture-segment'))
            self.assertEqual([headers['X-Quality'] for _, headers in received],
                             ['high', 'high', 'low', 'low'])
            self.assertEqual([headers['X-Shared'] for _, headers in received],
                             ['source'] * 4)
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
