import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Plugins'))
import host_media_runtime as media
SPEC = importlib.util.spec_from_file_location('dsx_builtin', ROOT / 'Resources/BuiltinMedia/dsx-python.py')
dsx = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(dsx)


class DSXPlaybackTests(unittest.TestCase):
    def test_spider_runtime_keeps_opaque_hls_format_and_signed_headers(self):
        engine = media.PythonSpider(str(ROOT / 'Resources/BuiltinMedia'), 'dsx-python.py')
        try:
            meta = {'v': 1, 'u': 'https://fixture.test/stream?sig=a%2Bb', 'p': [],
                    'h': {'Referer': 'https://fixture.test/'}, 's': False, 'c': '', 'm': 'auto'}
            token = dsx._pack_play(meta)
            with mock.patch.object(sys.modules[engine.spider.__class__.__module__], '_probe_media',
                                   return_value=(meta['u'], 'm3u8')):
                result = media.playback(engine.call('play', {'id': token}))
            self.assertEqual(result['url'], meta['u'])
            self.assertEqual(result['format'], 'hls')
            self.assertTrue(result['nativePlayable'])
            self.assertEqual(result['headers']['Referer'], meta['h']['Referer'])
        finally:
            engine.close()

    def test_verified_media_rejects_error_body(self):
        self.assertEqual(dsx._sniff_media(b'<html>denied</html>'), '')
        self.assertEqual(dsx._sniff_media(b'#EXTM3U\n#EXTINF:6,\nsegment.ts'), 'm3u8')

    def test_native_request_roundtrip_preserves_unicode(self):
        body = dsx.encrypt_request('search', {'text': '电影', 'pg': 2}, csrf=123, iv=bytes(16))
        self.assertEqual(dsx.decrypt_request(body)['data']['text'], '电影')
