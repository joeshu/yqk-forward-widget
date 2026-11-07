"""Regression coverage for Python TVBox selectors and protocol normalization."""

import sys
import tempfile
import unittest
from pathlib import Path

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
import host_media_runtime as media
import host_media_relay as relay_mod


class PythonSpiderCompatibilityTests(unittest.TestCase):
    def setUp(self):
        if str(PLUGINS) not in sys.path:
            sys.path.insert(0, str(PLUGINS))

    def test_pyquery_lxml_and_beautifulsoup_lxml_alias_roundtrip_playback(self):
        source = r'''from bs4 import BeautifulSoup
from lxml import etree, html
from pyquery import PyQuery as pq

class Spider:
    def homeContent(self, filter):
        markup = '<div class="movie-card"><a href="movie-1"><img alt="样例影片" src="poster.jpg"></a></div>'
        tree = etree.HTML(markup)
        soup = BeautifulSoup(markup, 'lxml')
        BeautifulSoup(markup)
        doc = pq(markup)
        href = tree.xpath('//div[contains(@class,"movie-card")]//a/@href')[0]
        name = doc('img').eq(0).attr('alt')
        image = soup.select_one('img').get('src')
        return {'class': [{'type_id': 'movie', 'type_name': '电影'}],
                'list': [{'vod_id': href, 'vod_name': name, 'vod_pic': image}]}

    def categoryContent(self, tid, pg, filter, extend):
        root = html.fromstring('<ul><li><a class="episode" href="https://cdn.test/episode.m3u8">第1集</a></li></ul>')
        return {'list': [{'vod_id': root.xpath('//a[contains(@class,"episode")]/@href')[0],
                         'vod_name': '样例影片'}]}

    def detailContent(self, ids):
        return {'list': [{'vod_id': ids[0], 'vod_name': '样例影片',
                          'vod_play_from': '直连',
                          'vod_play_url': '第1集$https://cdn.test/episode.m3u8'}]}

    def searchContent(self, key, quick, pg='1'):
        return {'list': [{'vod_id': f'{key}-{pg}', 'vod_name': key}]}

    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': id}
'''
        with tempfile.TemporaryDirectory() as root:
            Path(root, 'source.py').write_text(source, encoding='utf-8')
            engine = media.PythonSpider(root, 'source.py')
            try:
                self.assertEqual(engine.capabilities()['capabilities'],
                                 ['home', 'category', 'search', 'detail', 'play'])
                listing = media.home(engine.call('home', {}))
                self.assertEqual(listing['items'][0]['id'], 'movie-1')
                self.assertEqual(listing['items'][0]['name'], '样例影片')

                category = media.listing(engine.call('category', {
                    'categoryId': 'movie', 'page': 1, 'filters': {}}))
                self.assertEqual(category['items'][0]['id'],
                                 'https://cdn.test/episode.m3u8')

                search_res = media.listing(engine.call('search', {'keyword': '测试', 'page': 2}))
                self.assertEqual(search_res['items'][0]['id'], '测试-2')
                self.assertEqual(getattr(engine, '_search_arity', None), 3)

                detail = media.detail(engine.call('detail', {'id': 'movie-1'}), 'movie-1')
                episode = detail['lines'][0]['episodes'][0]
                playback = media.playback(engine.call('play', {
                    'id': episode['id'], 'lineId': detail['lines'][0]['id']}))
                self.assertEqual(playback['url'], 'https://cdn.test/episode.m3u8')
            finally:
                engine.close()

    def test_missing_options_use_legacy_empty_extend_and_base_log_is_available(self):
        source = '''from base.spider import Spider as BaseSpider

class Spider(BaseSpider):
    def init(self, extend=""):
        self.received_extend = extend
        self.log("initialized")
'''
        with tempfile.TemporaryDirectory() as root:
            Path(root, 'source.py').write_text(source, encoding='utf-8')
            engine = media.PythonSpider(root, 'source.py')
            try:
                self.assertEqual(engine.spider.received_extend, '')
            finally:
                engine.close()

    def test_detail_normalizes_list_vod_play_from_and_vod_play_url(self):
        raw = {
            'list': [{
                'vod_id': 'vod-list-1',
                'vod_name': '多线测试',
                'vod_play_from': ['蓝光A', '超清B'],
                'vod_play_url': [
                    '第1集$https://cdn.test/a1.m3u8#第2集$https://cdn.test/a2.m3u8',
                    '第1集$https://cdn.test/b1.m3u8',
                ],
            }]
        }
        normalized = media.detail(raw, 'vod-list-1')
        self.assertEqual(len(normalized['lines']), 2)
        self.assertEqual(normalized['lines'][0]['name'], '蓝光A')
        self.assertEqual(len(normalized['lines'][0]['episodes']), 2)
        self.assertEqual(normalized['lines'][1]['name'], '超清B')

    def test_playback_promotes_first_valid_alternate_escapes_spaces_and_preserves_tracks(self):
        raw = {
            'url': ['4K', '', '1080P', '//cdn.test/video 1080.m3u8?a=1&amp;b=2'],
            'subs': [{'name': '简中', 'url': 'https://cdn.test/sub.vtt', 'lang': 'zh'}],
            'danmaku': 'https://cdn.test/danmaku.xml',
        }
        normalized = media.playback(raw)
        self.assertEqual(normalized['url'], 'https://cdn.test/video%201080.m3u8?a=1&b=2')
        self.assertEqual(len(normalized['alternates']), 1)
        self.assertEqual(normalized['alternates'][0]['name'], '1080P')
        self.assertEqual(normalized['subtitles'][0]['url'], 'https://cdn.test/sub.vtt')
        self.assertEqual(normalized['danmaku'], 'https://cdn.test/danmaku.xml')

    def test_relay_rewrites_single_quoted_uris_ll_hls_preload_hints_and_html_entities(self):
        relay = relay_mod.MediaRelay()
        try:
            manifest = (
                "#EXTM3U\n"
                "#EXT-X-KEY:METHOD=AES-128,URI='https://cdn.test/key.bin?token=1&amp;v=2'\n"
                '#EXT-X-PRELOAD-HINT:TYPE=MAP,URI="https://cdn.test/init.mp4"\n'
                '#EXT-X-PART:DURATION=1.0,URI="https://cdn.test/part1.m4s"\n'
                "#EXTINF:4.0,\n"
                "https://cdn.test/seg1.ts?sig=a&amp;exp=1\n"
            )
            rewritten = relay.rewrite(
                manifest,
                'https://cdn.test/master.m3u8',
                {'Referer': 'https://cdn.test/'},
                'https://cdn.test',
                'http://127.0.0.1:9999',
            )
            self.assertNotIn("URI='https://cdn.test", rewritten)
            self.assertEqual(rewritten.count('http://127.0.0.1:9999/media/'), 4)
        finally:
            relay.close()


if __name__ == '__main__':
    unittest.main()
