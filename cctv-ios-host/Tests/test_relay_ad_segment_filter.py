"""MediaRelay spliced-ad filtering: discontinuity-bounded foreign blocks.

Real case: AI短剧网 (aiduanju) serves an HLS media playlist whose first 9
segments and a mid-roll block of 9 segments come from a different video
directory (/20261009/RCP0FQBQ/9622kb/ instead of the content's
/20261117/UfQu9FNp/1500kb/), each wrapped in #EXT-X-DISCONTINUITY. The
fixture is that playlist as fetched 2026-11-18; the filter must drop both
ad blocks, keep the 918 content segments in order, and keep the header.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Plugins'))

from host_media_relay import MediaRelay, _drop_spliced_ad_segments

URL = 'https://2609.v155p.com/20261117/UfQu9FNp/1500kb/hls/index.m3u8'
CONTENT = '/20261117/UfQu9FNp/1500kb/hls/'
AD = '/20261009/RCP0FQBQ/9622kb/hls/'


def _segments(prefix, count, start=0, duration=3):
    lines = []
    for index in range(start, start + count):
        lines.append('#EXTINF:%s,' % duration)
        lines.append('%sseg%03d.ts' % (prefix, index))
    return lines


def _playlist(blocks):
    lines = ['#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:5',
             '#EXT-X-MEDIA-SEQUENCE:0']
    for index, block in enumerate(blocks):
        if index:
            lines.append('#EXT-X-DISCONTINUITY')
        lines.extend(block)
    lines.append('#EXT-X-ENDLIST')
    return '\n'.join(lines) + '\n'


class AdSegmentFilterTests(unittest.TestCase):
    def test_real_ad_splice_playlist(self):
        fixture = Path(__file__).resolve().parent / 'fixtures' / 'aiduanju-ad-splice.m3u8'
        original = fixture.read_text(encoding='utf-8')
        filtered, dropped = _drop_spliced_ad_segments(original, URL)
        self.assertEqual(dropped, 18)
        self.assertEqual(filtered.count('#EXTINF'), 918)
        self.assertNotIn('RCP0FQBQ', filtered)
        self.assertNotIn('#EXT-X-DISCONTINUITY', filtered)
        for tag in ('#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-TARGETDURATION:5',
                    '#EXT-X-PLAYLIST-TYPE:VOD', '#EXT-X-MEDIA-SEQUENCE:0',
                    '#EXT-X-ENDLIST'):
            self.assertIn(tag, filtered)
        segments = [line for line in filtered.splitlines() if line.endswith('.ts')]
        self.assertEqual(len(segments), 918)
        self.assertTrue(segments[0].endswith('/aeD7JnSx.ts'))
        self.assertTrue(all(CONTENT in line for line in segments))
        original_content = [line for line in original.splitlines()
                            if line.endswith('.ts') and CONTENT in line]
        self.assertEqual(segments, original_content)

    def test_rewrite_drops_ad_segments_before_registering(self):
        fixture = Path(__file__).resolve().parent / 'fixtures' / 'aiduanju-ad-splice.m3u8'
        original = fixture.read_text(encoding='utf-8')
        relay = MediaRelay()
        rewritten = relay.rewrite(original, URL, {}, ('https', '2609.v155p.com'),
                                  'http://127.0.0.1:18793')
        self.assertEqual(relay.ad_segments_dropped, 18)
        self.assertEqual(rewritten.count('#EXTINF'), 918)
        self.assertNotIn('RCP0FQBQ', rewritten)
        self.assertEqual(rewritten.count('/media/'), 918)

    def test_master_playlist_untouched(self):
        master = ('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\n'
                  '/20261117/UfQu9FNp/1500kb/hls/index.m3u8\n')
        self.assertEqual(_drop_spliced_ad_segments(master, URL), (master, 0))

    def test_no_discontinuity_untouched(self):
        plain = _playlist([_segments(CONTENT, 30)])
        self.assertEqual(_drop_spliced_ad_segments(plain, URL), (plain, 0))

    def test_same_directory_discontinuity_kept(self):
        playlist = _playlist([_segments(CONTENT, 15), _segments(CONTENT, 15, 15)])
        filtered, dropped = _drop_spliced_ad_segments(playlist, URL)
        self.assertEqual((filtered, dropped), (playlist, 0))
        self.assertIn('#EXT-X-DISCONTINUITY', filtered)

    def test_short_playlist_untouched(self):
        playlist = _playlist([_segments(AD, 3), _segments(CONTENT, 12, 3)])
        self.assertEqual(_drop_spliced_ad_segments(playlist, URL), (playlist, 0))

    def test_foreign_block_over_duration_cap_kept(self):
        playlist = _playlist([_segments(AD, 25, 0, 6), _segments(CONTENT, 200, 25)])
        self.assertEqual(_drop_spliced_ad_segments(playlist, URL), (playlist, 0))

    def test_marker_preserved_between_kept_blocks_only(self):
        playlist = _playlist([_segments(CONTENT, 12), _segments(CONTENT, 12, 12),
                              _segments(AD, 2, 0), _segments(CONTENT, 12, 24)])
        filtered, dropped = _drop_spliced_ad_segments(playlist, URL)
        self.assertEqual(dropped, 2)
        self.assertEqual(filtered.count('#EXTINF'), 36)
        self.assertEqual(filtered.count('#EXT-X-DISCONTINUITY'), 1)
        self.assertNotIn(AD.strip('/'), filtered)

    def test_discontinuity_sequence_playlist_untouched(self):
        playlist = _playlist([_segments(AD, 9), _segments(CONTENT, 100, 9)])
        playlist = playlist.replace('#EXT-X-MEDIA-SEQUENCE:0',
                                    '#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-DISCONTINUITY-SEQUENCE:2')
        self.assertEqual(_drop_spliced_ad_segments(playlist, URL), (playlist, 0))


if __name__ == '__main__':
    unittest.main()
