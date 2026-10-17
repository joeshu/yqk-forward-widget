import concurrent.futures
import datetime
import importlib.util
import pathlib
import sys
import threading
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from ysp_hls import parse_media, render_media, rewrite_uris, select_variant, UnsafePlaylist
SPEC = importlib.util.spec_from_file_location('ysp_live_hls_tests', ROOT / 'ysp-live-v9.5.9.py')
live = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = live
SPEC.loader.exec_module(live)
parse_media, render_media, rewrite_uris, select_variant, UnsafePlaylist = (
    live.parse_media, live.render_media, live.rewrite_uris, live.select_variant, live.UnsafePlaylist)


def playlist(start=0, count=3, *, sequence=None, origin='https://cdn.example/', pdt=True, key=''):
    lines = ['#EXTM3U', '#EXT-X-VERSION:6', '#EXT-X-TARGETDURATION:6', '#EXT-X-MEDIA-SEQUENCE:' + str(start if sequence is None else sequence)]
    if key:
        lines.append(key)
    for index in range(start, start + count):
        if pdt:
            stamp = datetime.datetime(2026, 10, 17, tzinfo=datetime.timezone.utc) + datetime.timedelta(seconds=index * 6)
            lines.append('#EXT-X-PROGRAM-DATE-TIME:' + stamp.isoformat())
        lines.extend(('#EXTINF:6,', origin + str(index) + '.ts?sig=old'))
    return '\n'.join(lines) + '\n'


class HlsTests(unittest.TestCase):
    def channel(self):
        return live.Channel('test', 'Test', 'sid', 'pid', 'fhd')

    def test_uri_attributes_and_redirect_base(self):
        text = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4",BYTERANGE="20@0"\n#EXTINF:6,\none.m4s\n'
        out = rewrite_uris(text, 'https://redirect.example/new/list.m3u8')
        for path in ('key.bin', 'init.mp4', 'one.m4s'):
            self.assertIn('https://redirect.example/new/' + path, out)

    def test_quality_and_separate_audio(self):
        master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=640x360\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080\nhigh.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720\nmid.m3u8\n'
        self.assertEqual(select_variant(master), 'high.m3u8')
        self.assertEqual(select_variant(master, 'shd'), 'mid.m3u8')
        self.assertIsNone(select_variant(master, 'auto'))
        self.assertIsNone(select_variant(master.replace('BANDWIDTH=1000000', 'AUDIO="audio",BANDWIDTH=1000000')))

    def test_fetch_uses_effective_redirect_url(self):
        body = b'#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXTINF:6,\none.ts\n'
        with mock.patch.object(live, 'fetch_urllib_bytes', return_value=(200, {}, body, 'https://redirect.example/final/list.m3u8')):
            result = live.fetch_abs_playlist('https://original.example/old/list.m3u8')
        self.assertIn('https://redirect.example/final/one.ts', result)
        self.assertIn('URI="https://redirect.example/final/key"', result)

    def test_aes_implicit_iv_uses_source_sequence_after_renumbering(self):
        media = parse_media(playlist(100, 2, key='#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key"'))
        out = render_media(media, sequences=[500, 501])
        self.assertIn('IV=0x' + format(100, '032x'), out)
        self.assertIn('IV=0x' + format(101, '032x'), out)
        self.assertIn('#EXT-X-MEDIA-SEQUENCE:500', out)

    def test_range_map_and_discontinuity_survive_trim(self):
        text = '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:10\n#EXT-X-DISCONTINUITY-SEQUENCE:3\n#EXT-X-MAP:URI="https://cdn.example/init"\n#EXT-X-DISCONTINUITY\n#EXTINF:6,\n#EXT-X-BYTERANGE:100@0\nhttps://cdn.example/movie.mp4\n#EXTINF:6,\n#EXT-X-BYTERANGE:100\nhttps://cdn.example/movie.mp4\n'
        media = parse_media(text)
        out = render_media(media, media.segments[1:], [11])
        self.assertIn('#EXT-X-MAP:', out)
        self.assertIn('#EXT-X-BYTERANGE:100@100', out)
        self.assertIn('#EXT-X-DISCONTINUITY-SEQUENCE:4', out)
        self.assertNotEqual(media.segments[0].identity, media.segments[1].identity)

    def test_complex_encryption_never_silently_renumbers(self):
        media = parse_media(playlist(100, 2, key='#EXT-X-KEY:METHOD=SAMPLE-AES,URI="https://cdn.example/key"'))
        with self.assertRaises(UnsafePlaylist):
            render_media(media, sequences=[500, 501])

    def test_first_pdt_is_inherited_after_trimming(self):
        text = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-PROGRAM-DATE-TIME:2026-10-17T00:00:00Z\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n'
        media = parse_media(text)
        trimmed = render_media(media, media.segments[1:])
        self.assertIn('#EXT-X-PROGRAM-DATE-TIME:2026-10-17T00:00:06+00:00', trimmed)

    def test_jce_resigning_updates_existing_segment_first(self):
        ch = self.channel()
        first = live._FetchedSegments(playlist(0, 3))
        second = live._FetchedSegments(playlist(0, 3).replace('sig=old', 'sig=new'))
        with mock.patch.object(live, 'jce_fetch', side_effect=[first, second]):
            live.jce_refresh(ch)
            sequence = ch.seq
            live.jce_refresh(ch)
        self.assertEqual(ch.seq, sequence)
        self.assertTrue(all('sig=new' in segment[3] for segment in ch.segments.values()))

    def test_jce_normalizes_pdt_timezones_and_local_sequence(self):
        ch = self.channel()
        first = live._FetchedSegments(playlist(0, 2, sequence=0))
        later = live._FetchedSegments(playlist(1, 2, sequence=0).replace('2026-10-17T00:00:06+00:00', '2026-10-17T08:00:06+08:00'))
        with mock.patch.object(live, 'jce_fetch', side_effect=[first, later]):
            live.jce_refresh(ch)
            live.jce_refresh(ch)
        self.assertEqual(ch.seq, 3)
        result = parse_media(live.build_playlist(ch, holdback=False))
        self.assertEqual(len(result.segments), 3)
        self.assertEqual(result.sequence, 1)
        self.assertEqual(len(ch.segments), 3)

    def test_jce_preserves_implicit_iv_when_source_window_restarts_at_zero(self):
        ch = self.channel()
        key = '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key"'
        fetched = live._FetchedSegments(playlist(50, 3, sequence=0, key=key))
        with mock.patch.object(live, 'jce_fetch', return_value=fetched):
            live.jce_refresh(ch)
        out = live.build_playlist(ch, holdback=False)
        self.assertIn('#EXT-X-MEDIA-SEQUENCE:1', out)
        for original_seq in (0, 1, 2):
            self.assertIn('IV=0x' + format(original_seq, '032x'), out)

    def test_frozen_media_does_not_renew_success_or_cache_timestamp(self):
        ch = self.channel()
        fetched = live._FetchedSegments(playlist(0, 3))
        with mock.patch.object(live, 'jce_fetch', return_value=fetched), mock.patch.object(live.time, 'monotonic', return_value=100):
            live.jce_refresh(ch)
            live.build_playlist(ch, holdback=False)
        built_at = ch.last_built_time
        with mock.patch.object(live, 'jce_fetch', return_value=fetched), mock.patch.object(live.time, 'monotonic', return_value=200):
            with self.assertRaises(live.FrozenPlaylistError):
                live.jce_refresh(ch)
        self.assertTrue(ch.media_stalled)
        self.assertEqual(ch.last_built_time, built_at)
        self.assertEqual(ch._media_progress['jce'][2], 100)

    def test_source_boundary_shared_by_head_and_multiple_gets(self):
        ch = self.channel()
        initial = live.publish_channel_playlist(ch, playlist(0, 3), 'device')
        epoch = ch.source_epoch
        headed = live.publish_channel_playlist(ch, playlist(3, 3), 'backup', head_only=True)
        self.assertEqual(headed, initial)
        self.assertEqual(ch.source_epoch, epoch)
        changed = live.publish_channel_playlist(ch, playlist(3, 3), 'backup')
        repeated = live.publish_channel_playlist(ch, playlist(3, 3), 'backup')
        self.assertEqual(changed, repeated)
        self.assertEqual(changed.splitlines().count('#EXT-X-DISCONTINUITY'), 1)
        moved = live.publish_channel_playlist(ch, playlist(4, 3), 'backup')
        self.assertNotIn('\n#EXT-X-DISCONTINUITY\n', moved)
        self.assertIn('#EXT-X-DISCONTINUITY-SEQUENCE:1', moved)
        self.assertGreater(parse_media(moved).sequence, parse_media(changed).sequence)

    def test_switch_aes_preserves_original_iv(self):
        ch = self.channel()
        live.publish_channel_playlist(ch, playlist(100, 3), 'device')
        key = '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key"'
        result = live.publish_channel_playlist(ch, playlist(103, 2, sequence=0, key=key), 'backup')
        self.assertIn('#EXT-X-MEDIA-SEQUENCE:103', result)
        self.assertIn('IV=0x' + format(0, '032x'), result)
        self.assertIn('IV=0x' + format(1, '032x'), result)

    def test_switch_entry_stays_trimmed_on_every_reload(self):
        ch = self.channel()
        live.publish_channel_playlist(ch, playlist(10, 3), 'device')
        candidate = playlist(0, 15)
        first = live.publish_channel_playlist(ch, candidate, 'backup')
        second = live.publish_channel_playlist(ch, candidate, 'backup')
        self.assertEqual(first, second)
        self.assertEqual(len(parse_media(second).segments), 2)
        self.assertIn('#EXT-X-DISCONTINUITY', second)

    def test_unaligned_switch_keeps_near_live_edge_on_every_reload(self):
        ch = self.channel()
        live.publish_channel_playlist(ch, playlist(10, 3, pdt=False), 'device')
        candidate = playlist(0, 15, origin='https://backup.example/', pdt=False)
        first = live.publish_channel_playlist(ch, candidate, 'backup')
        second = live.publish_channel_playlist(ch, candidate, 'backup')
        self.assertEqual(first, second)
        self.assertEqual(len(parse_media(second).segments), 3)
        self.assertTrue(ch.source_restart_required)

    def test_jce_to_bk_is_a_real_source_transition(self):
        ch = self.channel()
        live.publish_channel_playlist(ch, playlist(0, 3), 'backup')
        self.assertEqual(ch.source_epoch, 0)
        ch.mode = 'bk'
        changed = live.publish_channel_playlist(ch, playlist(3, 3), 'backup')
        self.assertEqual(ch.source_epoch, 1)
        self.assertEqual(ch._publication['source'], 'backup:bk')
        self.assertIn('\n#EXT-X-DISCONTINUITY\n', changed)

    def test_discontinuity_sequence_is_not_discontinuity(self):
        text = '#EXTM3U\n#EXT-X-DISCONTINUITY-SEQUENCE:12\n#EXTINF:6,\na.ts\n'
        self.assertIn('\n#EXT-X-DISCONTINUITY\n', live.inject_hls_discontinuity(text))

    def test_shared_refresh_retains_task_after_wait_timeout(self):
        started, release = threading.Event(), threading.Event()
        calls = []
        def fetch():
            calls.append(1)
            started.set()
            release.wait(2)
            return 'shared-result'
        self.assertIsNone(live.coalesce_refresh('timeout-test', fetch, timeout=0))
        self.assertTrue(started.wait(1))
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(live.coalesce_refresh, 'timeout-test', fetch) for _ in range(6)]
            time.sleep(0.03)
            release.set()
            results = [future.result(2) for future in futures]
        self.assertEqual(calls, [1])
        self.assertEqual(results, ['shared-result'] * 6)

    def test_shared_refresh_propagates_error_to_every_waiter(self):
        started, release = threading.Event(), threading.Event()
        def fetch():
            started.set()
            release.wait(2)
            raise ValueError('shared failure')
        live.coalesce_refresh('error-test', fetch, timeout=0)
        started.wait(1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(live.coalesce_refresh, 'error-test', fetch) for _ in range(2)]
            time.sleep(0.03)
            release.set()
            for future in futures:
                with self.assertRaisesRegex(ValueError, 'shared failure'):
                    future.result(2)

    def test_catchup_iso_range_and_invalid_inputs(self):
        now = int(datetime.datetime(2026, 10, 17, 12, tzinfo=datetime.timezone.utc).timestamp())
        with mock.patch.object(live.time, 'time', return_value=now):
            parsed = live.parse_catchup_query('playseek=2026-10-17T01:00:00Z-2026-10-17T02:00:00Z')
            self.assertEqual(parsed[1] - parsed[0], 3600)
            self.assertIsNone(live.parse_catchup_query('quality=fhd'))
            self.assertIsNotNone(live.parse_catchup_query('playseek=20261017090000-20261017100000'))
            for query in ('start=', 'start=junk', 'end=20261017090000', 'start=20261017100000&end=20261017090000', 'start=20261018100000', 'start=20261001090000', 'start=20261017090000&start=20261017090000'):
                with self.subTest(query=query), self.assertRaises(live.CatchupError):
                    live.parse_catchup_query(query)


if __name__ == '__main__':
    unittest.main()
