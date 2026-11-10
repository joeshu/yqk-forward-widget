"""Selected-source identity must survive adapter errors and empty responses."""
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Plugins'))
import csp_adapter as adapter
import host_media_runtime as media


class PythonSourceIdentityTests(unittest.TestCase):
    def test_generic_adapter_requires_explicit_host_without_network(self):
        for name in ('csp_AppRJ', 'csp_Gz360', 'csp_Jpys', 'csp_Unknown'):
            with self.subTest(api=name), mock.patch.object(adapter.requests, 'Session') as session:
                with self.assertRaisesRegex(ValueError, '不使用默认站点'):
                    adapter.AppVideoEngine(name, '')
                session.assert_not_called()

    def test_empty_responses_never_change_site_or_use_default_catalog(self):
        engine = adapter.AppVideoEngine('csp_AppRJ', {'url': 'https://chosen.invalid'})
        response = mock.Mock(text='{}')
        engine.session.get = mock.Mock(return_value=response)
        calls = (lambda: engine.homeContent(),
                 lambda: engine.categoryContent('17', '1', False, {}),
                 lambda: engine.detailContent(['17']),
                 lambda: engine.searchContent('selected title', False))
        for call in calls:
            call()
            self.assertEqual(engine.base_url, 'https://chosen.invalid')
        self.assertGreater(engine.session.get.call_count, 0)
        self.assertTrue(all(urlsplit(call.args[0]).hostname == 'chosen.invalid'
                            for call in engine.session.get.call_args_list))

    def test_unrelated_ext_text_does_not_select_yqk(self):
        engine = adapter.AppVideoEngine('csp_AppRJ', {'url': 'https://chosen.invalid', 'siteName': 'yqk archive'})
        self.assertFalse(engine._is_yqk)
        self.assertEqual(engine.base_url, 'https://chosen.invalid')

    def test_detail_chooses_requested_id_instead_of_first_row(self):
        engine = adapter.AppVideoEngine('csp_AppRJ', {'url': 'https://chosen.invalid'})
        wrong = {'vod_id': 'other', 'vod_name': 'unrelated', 'vod_play_url': 'https://cdn.invalid/wrong.m3u8'}
        selected = {'vod_id': '17', 'vod_name': 'chosen', 'vod_play_url': 'https://cdn.invalid/right.m3u8'}
        engine._request_json = mock.Mock(return_value={'list': [wrong, selected]})
        self.assertEqual(engine.detailContent(['17'])['list'][0], selected)
        engine._request_json.return_value = {'list': [wrong]}
        with self.assertRaisesRegex(ValueError, '避免错片'):
            engine.detailContent(['17'])
        self.assertEqual(engine.base_url, 'https://chosen.invalid')

    def test_known_yqk_protocol_keeps_its_declared_identity(self):
        engine = adapter.AppVideoEngine('csp_AppYQK', {})
        self.assertTrue(engine._is_yqk)
        self.assertEqual(engine.base_url, 'https://api.yqk3hxe.com')

    def test_failed_numeric_loopback_is_not_reinterpreted_as_hgtv(self):
        spider = object.__new__(media.PythonSpider)
        selected = {'parse': 0, 'url': 'http://127.0.0.1:9990/?vid=12345678901234567'}
        with mock.patch('requests.get', side_effect=OSError('fixture unavailable')), \
                mock.patch.object(media, '_load_csp_adapter', return_value=adapter), \
                mock.patch.object(media.importlib.util, 'spec_from_file_location') as load:
            self.assertEqual(spider._upgrade_tvbox_play_result(selected, '12345678901234567'), selected)
        load.assert_not_called()

    def test_ad_and_trailer_urls_are_not_host_playback_results(self):
        page = '<script>var ad="https://ad.invalid/trailer.mp4";</script>'
        self.assertEqual(adapter._extract_stream_from_html(page), '')
        # A source with its own explicit extraction rules can still opt in.
        self.assertEqual(adapter._extract_stream_from_html(page, allow_unscoped=True),
                         'https://ad.invalid/trailer.mp4')
        page += '<script>player_aaaa=' + json.dumps({'url': 'https://cdn.invalid/selected.m3u8', 'encrypt': 0}) + '</script>'
        self.assertEqual(adapter._extract_stream_from_html(page), 'https://cdn.invalid/selected.m3u8')


if __name__ == '__main__':
    unittest.main()
