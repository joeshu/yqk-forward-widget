"""Offline playback contracts for the three supplied Python adapters.

Only loopback HTTP is used; no source site availability is implied.
"""
import contextlib
import http.cookiejar
import http.server
import json
from pathlib import Path
import ssl
import sys
import threading
import unittest
import urllib.request
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Plugins'))
import host_media_runtime as media


@contextlib.contextmanager
def engine_for(name, **options):
    root = ROOT / 'Examples' / (name + '-python')
    manifest = json.loads((root / 'cctvhost.json').read_text())
    engine = media.PythonSpider(str(root), manifest['entry'], options=options or None)
    try:
        yield engine
    finally:
        engine.close()


def put_cookie(jar, host, value='fixture=valid'):
    name, value = value.split('=', 1)
    jar.set_cookie(http.cookiejar.Cookie(0, name, value, None, False, host, False, False,
                                        '/', True, False, None, True, None, None, {}))


class Fixture(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.requests.append((self.path, dict(self.headers)))
        if self.path.startswith('/cross-origin'):
            self.send_response(302)
            self.send_header('Location', 'http://localhost:' + str(self.server.server_port) + '/target')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/api/hls/'):
            self.send_response(302)
            self.send_header('Location', '/stream/index.png?sig=a%2Bb&part=1')
            self.send_header('Set-Cookie', 'auth=fixture; Path=/')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/video/'):
            body = b'<div data-hls="../stream/master.m3u8?sig=a%2Bb&amp;part=1"></div>'
            content_type = 'text/html'
        else:
            # The .mp4 entries are init/fragment media, never whole movies.
            body = (b'#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
                    b'#EXT-X-MAP:URI="init.mp4"\n#EXTINF:4,\npart1.mp4\n'
                    b'#EXTINF:4,\npart2.mp4\n#EXT-X-ENDLIST\n')
            content_type = 'application/vnd.apple.mpegurl'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class AttachmentPlaybackAdapters(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = 'http://127.0.0.1:' + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def test_all_manifests_load_without_network_or_optional_requests(self):
        with mock.patch('urllib.request.OpenerDirector.open', side_effect=AssertionError('unexpected network')):
            for name in ('rou', '718', 'huangguo'):
                with self.subTest(source=name), engine_for(name) as engine:
                    self.assertIn('play', engine.capabilities()['capabilities'])
                    if hasattr(engine.spider, 'ctx'):
                        self.assertEqual(engine.spider.ctx.verify_mode, ssl.CERT_REQUIRED)
                        self.assertTrue(engine.spider.ctx.check_hostname)

    def test_hls_redirect_preserves_signed_url_session_and_format(self):
        with engine_for('rou', siteUrl=self.base) as engine:
            playback = media.playback(engine.call('play', {'id': self.base + '/api/hls/one'}))
            self.assertEqual(playback['url'], self.base + '/stream/index.png?sig=a%2Bb&part=1')
            self.assertEqual(playback['format'], 'hls')
            self.assertTrue(playback['nativePlayable'])
            self.assertIn('auth=fixture', playback['headers']['Cookie'])
            self.assertNotIn('Connection', playback['headers'])

    def test_regular_hls_redirect_is_accepted_not_only_index_png(self):
        with engine_for('rou', siteUrl=self.base) as engine:
            response = mock.MagicMock()
            response.geturl.return_value = 'https://cdn.fixture.invalid/master.m3u8?sig=a%2Fb'
            response.headers = {'Content-Type': 'application/vnd.apple.mpegurl'}
            response.__enter__.return_value = response
            with mock.patch.object(engine.spider.opener, 'open', return_value=response):
                result = engine.call('play', {'id': self.base + '/api/hls/two'})
            self.assertEqual(result['url'], response.geturl.return_value)
            self.assertEqual(result['format'], 'hls')

    def test_huangguo_keeps_complete_hls_timeline_and_page_referer(self):
        with engine_for('huangguo', siteUrl=self.base) as engine:
            for _attempt in range(2):
                result = media.playback(engine.call('play', {'id': self.base + '/video/one'}))
                self.assertEqual(result['url'], self.base + '/stream/master.m3u8?sig=a%2Bb&part=1')
                self.assertEqual(result['headers']['Referer'], self.base + '/video/one')
                self.assertIn('hg_age=1', result['headers']['Cookie'])
                self.assertEqual(result['format'], 'hls')
            with mock.patch.object(engine.spider, '_http_get', side_effect=AssertionError('HLS should be lazy')):
                result = engine.call('play', {'id': self.base + '/stream/master.m3u8?sig=a%2Bb'})
                self.assertNotIn('part1.mp4', result['url'])

    def test_source_cookies_are_scoped_to_media_origin(self):
        for name in ('rou', '718', 'huangguo'):
            with self.subTest(source=name), engine_for(name, siteUrl=self.base) as engine:
                put_cookie(engine.spider.cj, '127.0.0.1')
                result = engine.call('play', {'id': 'https://external.fixture.invalid/media.m3u8'})
                self.assertNotIn('Cookie', result['header'])
                result = engine.call('play', {'id': self.base + '/stream/master.m3u8'})
                self.assertIn('fixture=valid', result['header']['Cookie'])

    def test_huangguo_fetch_redirect_does_not_forward_source_cookies(self):
        with engine_for('huangguo', siteUrl=self.base) as engine:
            put_cookie(engine.spider.cj, '127.0.0.1')
            start = len(Fixture.requests)
            engine.spider._http_get(self.base + '/cross-origin')
            observed = Fixture.requests[start:]
            self.assertIn('hg_age=1', observed[0][1]['Cookie'])
            self.assertNotIn('Cookie', observed[-1][1])

    def test_718_signed_urls_and_original_scheme_are_preserved(self):
        with engine_for('718', siteUrl=self.base) as engine:
            signed = "https://cdn.fixture.invalid/movie.m3u8?sig=a%2Fb+o'k&v=2"
            result = engine.call('play', {'id': signed.replace('&', '&amp;')})
            self.assertEqual(result['url'], signed)
            markup = '<video src="https://cdn.fixture.invalid/movie.m3u8?sig=a%2Fb+token&amp;v=2">'
            direct, invented = engine.spider._extract_episodes_from_html(markup)
            self.assertEqual(len(direct), 1)
            self.assertIn('https://', direct[0])
            self.assertIn('?sig=a%2Fb+token&v=2', direct[0])
            self.assertEqual(invented, [])


class MediaHeaderContracts(unittest.TestCase):
    def test_first_delimiter_keeps_dollar_in_referer_value(self):
        headers = media.media_headers('Referer:https://source.invalid/path/$signed#User-Agent$fixture')
        self.assertEqual(headers, {'Referer': 'https://source.invalid/path/$signed', 'User-Agent': 'fixture'})

    def test_header_precedence_is_case_insensitive_for_each_choice(self):
        result = media.playback({'url': [
            {'url': 'https://cdn.invalid/one.m3u8', 'headers': {'referer': 'old-choice'},
             'header': {'Referer': 'new-choice'}}],
            'headers': {'user-agent': 'old'}, 'header': {'User-Agent': 'new'}})
        self.assertEqual(result['headers'], {'User-Agent': 'new', 'Referer': 'new-choice'})
        self.assertEqual(result['alternates'][0]['headers'], {'Referer': 'new-choice'})

    def test_runtime_preserves_selected_media_without_cross_catalog_title_search(self):
        class Engine:
            def call(self, operation, args):
                return {'url': args['id'], 'parse': 1 if 'youku.com' in args['id'] else 0,
                        'header': {'Referer': 'https://selected.invalid/'}}
            def close(self):
                pass
        runtime = media.MediaRuntime(Engine())
        try:
            runtime._last_detail_title = 'Fixture title'
            for url in ('https://v.youku.com/v_show/id_fixture.html',
                        'https://lzcdn.invalid/movie.m3u8?sig=a%2Fb+1'):
                with mock.patch.object(media, '_load_csp_adapter', side_effect=AssertionError('unexpected catalog search')):
                    result = runtime.call('play', {'id': url, 'title': 'Fixture title'})
                self.assertEqual(result['url'], url)
                self.assertEqual(result['headers']['Referer'], 'https://selected.invalid/')
        finally:
            runtime.close()

    def test_python_spider_upgrade_keeps_original_with_title_and_no_catalog_rescue(self):
        adapter = media._load_csp_adapter()
        with engine_for('rou') as engine:
            engine._last_detail_title = 'Known fixture title'
            for url in ('https://v.youku.com/v_show/id_fixture.html',
                        'https://lzcdn.invalid/movie.m3u8?sig=a%2Fb+1'):
                original = {'url': url, 'parse': 1, 'header': {'Referer': 'https://selected.invalid/'}}
                engine._episode_map[url] = ('Known fixture title', 1, 'Episode 2')
                with mock.patch.object(adapter, 'resolve_maccms_stream_by_title',
                                       return_value='https://other.invalid/wrong.m3u8') as rescue:
                    result = engine._upgrade_tvbox_play_result(original, url, {'title': 'Known fixture title'})
                self.assertIs(result, original)
                rescue.assert_not_called()

    def test_python_upgrade_skips_probes_for_declared_hls_png_and_opaque_media(self):
        adapter = media._load_csp_adapter()
        requests_stub = mock.Mock()
        with engine_for('rou') as engine:
            # Exercise the production compatibility branch even if a fixture
            # source is classified as a non-TVBox implementation.
            engine._is_tvbox_spider = True
            engine._last_detail_title = 'Known fixture title'
            for url, hint in (
                    ('https://cdn.invalid/index.png?sig=a%2Fb+1', {'format': 'hls'}),
                    ('https://cdn.invalid/stream?sig=a%2Fb+1', {'contentType': 'application/vnd.apple.mpegurl'}),
                    ('https://cdn.invalid/native-stream', {'nativePlayable': True}),
                    ('https://cdn.invalid/direct-stream', {'directMedia': True})):
                original = dict(hint, url=url, parse=0, header={'Referer': 'https://selected.invalid/'})
                with mock.patch.dict(sys.modules, {'requests': requests_stub}), \
                     mock.patch.object(adapter, 'resolve_maccms_stream_by_title') as rescue, \
                     mock.patch.object(engine.spider, 'playerContent', return_value=original):
                    result = engine._upgrade_tvbox_play_result(original, url, {'title': 'Known fixture title'})
                    self.assertIs(result, original)
                    self.assertEqual(engine.call('play', {'id': url, 'title': 'Known fixture title'}), original)
                    rescue.assert_not_called()
            requests_stub.get.assert_not_called()

    def test_app_video_engine_keeps_unresolved_page_with_title_and_no_catalog_rescue(self):
        adapter = media._load_csp_adapter()
        engine = adapter.AppVideoEngine('AppYsV2', {'url': 'https://selected.invalid'})
        engine._last_vod_name = 'Known fixture title'
        selected = 'https://selected.invalid/watch/episode-2'
        with mock.patch.object(engine, '_request_json', return_value={'url': selected}), \
             mock.patch.object(engine.session, 'get', return_value=mock.Mock(text='<html>No stream</html>')), \
             mock.patch.object(adapter, 'resolve_maccms_stream_by_title',
                               return_value='https://other.invalid/wrong.m3u8') as rescue:
            result = engine.playerContent('selected', 'episode-2', [])
        self.assertEqual(result['url'], selected)
        self.assertEqual(result['parse'], 1)
        rescue.assert_not_called()

    def test_control_characters_are_dropped(self):
        self.assertEqual(media.media_headers({'X-Nul': 'a\0b', 'X-Del': 'a\x7fb',
                                             'X-CR': 'a\rb', 'X-Tab': 'a\tb'}), {'X-Tab': 'a\tb'})


if __name__ == '__main__':
    unittest.main()
