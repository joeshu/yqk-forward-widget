"""Regression coverage for Python TVBox selectors missing from iOS CPython."""

import sys
import tempfile
import unittest
from pathlib import Path

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
import host_media_runtime as media


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
        return {'list': []}

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

                detail = media.detail(engine.call('detail', {'id': 'movie-1'}), 'movie-1')
                episode = detail['lines'][0]['episodes'][0]
                playback = media.playback(engine.call('play', {
                    'id': episode['id'], 'lineId': detail['lines'][0]['id']}))
                self.assertEqual(playback['url'], 'https://cdn.test/episode.m3u8')
            finally:
                engine.close()


if __name__ == '__main__':
    unittest.main()
