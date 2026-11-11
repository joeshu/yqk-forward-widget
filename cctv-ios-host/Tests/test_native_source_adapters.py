"""Native resolver inputs and VOD expiry use controlled sources, never remote films."""
import http.client
import http.cookiejar
import http.server
import json
from pathlib import Path
import threading
import time
import unittest
import urllib.parse
from unittest.mock import patch

from Tests.test_media_runtime import media, transport


ROOT = Path(__file__).resolve().parents[1]


def cookie(name, value, domain, path='/', secure=True, expires=None):
    return http.cookiejar.Cookie(0, name, value, None, False, domain, True,
        domain.startswith('.'), path, True, secure, expires, expires is None,
        None, None, {}, False)


class NativeSourceAdapterTests(unittest.TestCase):
    def load(self, directory):
        with patch('urllib.request.urlopen', side_effect=AssertionError('no import network')):
            engine = media.PythonSpider(str(ROOT / 'Examples' / directory), 'spider.py')
        self.addCleanup(engine.close)
        return engine

    def test_youku_keeps_vid_page_and_scopes_live_session_cookies(self):
        engine = self.load('youku-python')
        jar = engine.spider.session.cookies
        for item in [cookie('valid', 'yes', '.youku.com'),
                     cookie('other', 'no', '.example.com'),
                     cookie('wrong_path', 'no', '.youku.com', '/unrelated'),
                     cookie('expired', 'no', '.youku.com', expires=time.time()-10)]:
            jar.set_cookie(item)
        raw = engine.call('play', {'lineId': '优酷', 'id': 'fixture+vid==',
                                  'detailId': 'show-1', 'provider': 'youku'})
        result = media.playback(raw)
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(result['url']).query),
                         {'vid': ['fixture+vid==']})
        self.assertEqual(result['pageURL'], result['url'])
        self.assertEqual(result['episodeID'], 'fixture+vid==')
        self.assertEqual(result['provider'], 'youku')
        self.assertEqual(result['headers']['Cookie'], 'valid=yes')
        self.assertTrue(result['requiresWebPlayback'])
        self.assertFalse(result['nativePlayable'])
        self.assertEqual(engine.spider.cookie, {})

    def test_tencent_preserves_cid_vid_without_retired_parser_or_fake_episode(self):
        engine = self.load('tencent-python')
        episodes, trailers = engine.spider.process_pdata(
            [{'item_id': 'vid-1', 'item_params': {'union_title': '第1集'}}], ['cid-1'])
        self.assertEqual(episodes, ['第1集$cid-1@vid-1'])
        self.assertFalse(trailers)
        result = media.playback(engine.call('play', {'lineId': '腾讯视频', 'id': 'cid-1@vid-1'}))
        self.assertEqual(result['url'], 'https://v.qq.com/x/cover/cid-1/vid-1.html')
        self.assertEqual(result['pageURL'], result['url'])
        self.assertEqual(result['episodeID'], 'cid-1@vid-1')
        self.assertEqual(result['provider'], 'qq')
        self.assertTrue(result['parse'])
        self.assertTrue(result['requiresWebPlayback'])
        self.assertFalse(result['nativePlayable'])
        self.assertNotIn('Cookie', result['headers'])
        self.assertEqual(engine.spider.handle_exception(None, 'fixture'), {'list': []})
        with self.assertRaises(media.MediaError):
            media.playback(engine.spider.playerContent('', 'broken', []))

    def test_watch_page_provenance_survives_normalization_without_url_rewrite(self):
        signed = 'https://cdn.test/episode.m3u8?sig=a%2Bb&key=x%2Fy'
        value = media.playback({'url': signed, 'pageURL': 'https://v.qq.com/x/cover/c/v.html',
                                'provider': 'qq', 'episodeID': 'c@v'})
        self.assertEqual(value['url'], signed)
        self.assertEqual(value['pageURL'], 'https://v.qq.com/x/cover/c/v.html')
        unsafe = media.playback({'url': signed, 'pageURL': 'javascript:bad', 'episodeID': 'x\ny'})
        self.assertNotIn('pageURL', unsafe)
        self.assertNotIn('episodeID', unsafe)


class VODRefreshTests(unittest.TestCase):
    def test_source_expiry_accepts_unix_seconds_and_javascript_milliseconds(self):
        now = time.time()
        seconds = transport.vod_refresh_after({'expiresAt': now + 120})
        milliseconds = transport.vod_refresh_after({'expiresAt': (now + 120) * 1000})
        js_refresh_after = transport.vod_refresh_after({'refreshAfter': (now + 45) * 1000})
        self.assertAlmostEqual(seconds, milliseconds, delta=0.05)
        self.assertAlmostEqual(js_refresh_after, now + 45, delta=0.05)

    def test_callback_keeps_full_identity_and_quality_name_across_reordering(self):
        class Runtime:
            def __init__(self): self.calls = []
            def call(self, operation, args):
                self.calls.append((operation, args))
                return {'url': 'https://cdn.test/main.m3u8', 'baseHeaders': {'X-Base': 'fresh'},
                        'alternates': [{'name': '720', 'url': 'https://cdn.test/720.m3u8'},
                                       {'name': '1080', 'url': 'https://cdn.test/1080.m3u8?sig=a%2Bb',
                                        'headers': {'X-Quality': '1080'}}]}
        runtime = Runtime()
        args = {'id': 'c@v', 'lineId': 'line-a', 'provider': 'qq', 'detailId': 'c',
                'parserID': 'catalog:0', 'filters': {'region': 'cn'}}
        refresh = transport.make_vod_refresh(runtime, args, {'name': '1080'}, alternate_index=0)
        args['id'] = 'different'
        args['filters']['region'] = 'changed'
        result = refresh()
        self.assertEqual(runtime.calls, [('play', {'id': 'c@v', 'lineId': 'line-a',
            'provider': 'qq', 'detailId': 'c', 'parserID': 'catalog:0', 'filters': {'region': 'cn'}})])
        self.assertEqual(result['url'], 'https://cdn.test/1080.m3u8?sig=a%2Bb')
        self.assertEqual(result['headers'], {'X-Base': 'fresh', 'X-Quality': '1080'})

    def test_refresh_rejects_page_expired_or_changed_episode_results(self):
        class Runtime:
            def __init__(self, value): self.value = value
            def call(self, *_): return self.value
        cases = [({'url': 'https://v.qq.com/x/cover/c/v.html', 'parse': 1}, 'MEDIA_REFRESH_REQUIRED'),
                 ({'url': 'https://cdn.test/a.m3u8', 'expiresAt': time.time()-1}, 'MEDIA_REFRESH_EXPIRED'),
                 ({'url': 'https://cdn.test/a.m3u8', 'episodeID': 'other'}, 'MEDIA_REFRESH_IDENTITY_CHANGED')]
        for value, expected in cases:
            with self.subTest(expected=expected), self.assertRaises(media.MediaError) as raised:
                transport.make_vod_refresh(Runtime(value), {'id': 'c@v'}, {'episodeID': 'c@v'})()
            self.assertEqual(raised.exception.code, expected)

    def test_timeout_does_not_spawn_more_workers_for_the_same_refresh(self):
        release = threading.Event()
        class Runtime:
            def __init__(self): self.calls = 0
            def call(self, *_):
                self.calls += 1
                release.wait(2)
                return {'url': 'https://cdn.test/a.m3u8'}
        runtime = Runtime()
        refresh = transport.make_vod_refresh(runtime, {'id': 'one'}, {}, timeout=0.02)
        try:
            for _ in range(2):
                with self.assertRaises(media.MediaError) as raised:
                    refresh()
                self.assertEqual(raised.exception.code, 'MEDIA_REFRESH_TIMEOUT')
            self.assertEqual(runtime.calls, 1)
        finally:
            release.set()

    def test_transport_403_refreshes_exact_play_once_without_old_child_path_stitching(self):
        received = []
        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                received.append((self.path, self.headers.get('X-Session')))
                if self.path.startswith('/old/master.m3u8'):
                    self.send_error(403)
                    return
                if self.path.startswith('/new/master.m3u8'):
                    body = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.42e01e,mp4a.40.2"\nnew-video.m3u8?variant=own%2Bsig\n'
                elif self.path == '/new/new-video.m3u8?variant=own%2Bsig':
                    body = b'#EXTM3U\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n'
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        base = 'http://127.0.0.1:' + str(upstream.server_port)
        class Engine:
            def __init__(self): self.calls = []
            def capabilities(self): return {'capabilities': ['play']}
            def call(self, operation, args):
                self.calls.append((operation, json.loads(json.dumps(args))))
                suffix = '/old/master.m3u8?sig=old' if len(self.calls) == 1 else '/new/master.m3u8?sig=new%2Bvalue'
                return {'url': base + suffix, 'headers': {'X-Session': 'old' if len(self.calls)==1 else 'fresh'},
                        'expiresAt': time.time()+120, 'provider': 'qq', 'episodeID': 'cid@vid'}
            def close(self): pass
        engine = Engine()
        runtime = media.MediaRuntime(engine)
        server = transport.Server(('127.0.0.1', 0), runtime)
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (upstream, server)]
        for thread in threads: thread.start()
        client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
        try:
            args = {'id': 'cid@vid', 'lineId': '腾讯视频', 'detailId': 'cid',
                    'provider': 'qq', 'parserID': 'catalog:0'}
            client.request('POST', '/api/v1/play', body=json.dumps(args), headers={'Content-Type': 'application/json'})
            response = client.getresponse()
            result = json.loads(response.read())['data']
            self.assertEqual(response.status, 200)
            root_path = urllib.parse.urlsplit(result['url']).path
            client.request('GET', root_path)
            response = client.getresponse()
            master = response.read().decode()
            self.assertEqual(response.status, 200, master)
            child_url = next(line for line in master.splitlines() if line.startswith('http://127.0.0.1:'))
            client.request('GET', urllib.parse.urlsplit(child_url).path)
            response = client.getresponse()
            response.read()
            self.assertEqual(response.status, 200)
            self.assertEqual(len(engine.calls), 2)
            self.assertEqual(engine.calls[0], engine.calls[1])
            self.assertEqual(engine.calls[0][1]['id'], 'cid@vid')
            self.assertIn(('/new/master.m3u8?sig=new%2Bvalue', 'fresh'), received)
            self.assertIn(('/new/new-video.m3u8?variant=own%2Bsig', 'fresh'), received)
            records = list(server.relay.targets.values())
            root_record = server.relay.targets[root_path.rsplit('/', 1)[-1]]
            self.assertFalse(root_record[7])
            self.assertTrue(callable(root_record[3]))
            self.assertTrue(any(record[3] is None and '/new/new-video.m3u8?' in record[0][0] for record in records))
        finally:
            client.close()
            runtime.close()
            for item in (upstream, server): item.shutdown(); item.server_close()
            for thread in threads: thread.join(2)


if __name__ == '__main__':
    unittest.main()
