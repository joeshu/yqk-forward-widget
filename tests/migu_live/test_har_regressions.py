"""Offline regression checks. HARs stay external and are never replayed online."""
import base64
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest
from urllib.parse import parse_qs, urljoin, urlsplit

spec = importlib.util.spec_from_file_location('migu_release', Path(__file__).resolve().parents[2] / 'migu/migu-live-v0.8.8.py')
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)

PID = '631780532'
SEED = '0123456789abcdef0123456789abcdef'
STAMP = '20261020214402'
URL = f'http://mgsp-ws2.live.miguvideo.com:8088/live.m3u8?ProgramID={PID}&puData={SEED}&timestamp={STAMP}'


def payload(rid='SUCCESS', rate=2, url=URL):
    return {'code': '200', 'rid': rid, 'body': {'content': {'contId': PID},
            'auth': {'authResult': 'SUCCESS'}, 'urlInfo': {'rateType': rate, 'url': url}}}


class RegressionTests(unittest.TestCase):
    def resolve(self, responses, settings=None, observer=None):
        calls = []
        class Client:
            def __init__(self, *args, **kwargs):
                pass
            def get(self, url, **kwargs):
                calls.append((parse_qs(urlsplit(url).query), kwargs.get('headers', {})))
                return json.dumps(responses.pop(0)).encode(), {}
        result = m.android_play_url(PID, settings or m.AndroidSettings(user_id='1234567890', token='test-token', rate_type=9), Client, observer)
        return result, calls

    def test_cdn_ports_and_host_boundaries(self):
        for role in ('stream', 'media'):
            for host in ('mgsp-ws2.live.miguvideo.com', 'mgsp-cty2.live.miguvideo.com'):
                m.validate_url(f'http://{host}:8088/live.m3u8', role)
            for host in ('miguvideo.com.evil.example', '127.0.0.1'):
                with self.assertRaises(m.UpdateError):
                    m.validate_url(f'http://{host}:8088/live.m3u8', role)
        with self.assertRaises(m.UpdateError):
            m.validate_url('http://mgsp-ws2.live.miguvideo.com:9000/live.m3u8', 'media')
        with self.assertRaises(m.UpdateError):
            m.validate_url('https://play-pre.miguvideo.com/playurl/v1/play/playurl', 'api')

    def test_fallback_uses_final_request_account_and_signature(self):
        observations = []
        result, calls = self.resolve([payload('TIPS_NEED_MEMBER', 4), payload('TIPS_NEED_MEMBER', 3),
                                      payload('TIPS_NEED_MEMBER', 2), payload()], observer=observations.append)
        self.assertEqual([c[0]['rateType'][0] for c in calls], ['9', '4', '3', '2'])
        self.assertTrue(all(c[1].get('UserToken') == 'test-token' for c in calls[:3]))
        self.assertNotIn('UserToken', calls[-1][1])
        proof = parse_qs(urlsplit(result).query)['ddCalcu'][0]
        self.assertEqual(proof, m.dd_calcu(SEED, PID, 2, '', timestamp=STAMP))
        self.assertEqual(observations[0]['requested_quality'], 2)
        self.assertFalse(observations[0]['account_sent'])

    def test_guest_legacy_does_not_repeat_same_request(self):
        responses = [payload('TIPS_NEED_MEMBER')]
        with self.assertRaisesRegex(m.MiguApiError, 'MIGU_MEMBERSHIP_REQUIRED'):
            self.resolve(responses, m.AndroidSettings(rate_type=9))
        self.assertFalse(responses)

    def test_denials_are_not_retried(self):
        for rid, error in [('COPYRIGHT_AREA_INVALID', 'MIGU_REGION_RESTRICTED'),
                           ('NEED_LOGIN', 'MIGU_LOGIN_REQUIRED'), ('USER_NOT_LOGIN', 'MIGU_LOGIN_REQUIRED')]:
            with self.subTest(rid=rid), self.assertRaisesRegex(m.MiguApiError, error):
                self.resolve([payload(rid)])

    def test_complete_url_is_preserved(self):
        complete = URL + '&ddCalcu=already-signed&sv=10004&ct=android'
        result, calls = self.resolve([payload(url=complete)])
        self.assertEqual(result, complete)
        self.assertEqual(len(calls), 1)

    def test_channel_mismatch_is_rejected(self):
        with self.assertRaisesRegex(m.MiguApiError, 'MIGU_CHANNEL_MISMATCH'):
            self.resolve([payload(url=URL.replace(PID, '641886683'))])

    def test_native_rejects_empty_or_duplicate_proof(self):
        for suffix in ('&ddCalcu=', '&ddCalcu=a&ddCalcu=b'):
            class Client:
                def __init__(self, *args, **kwargs): pass
                def get(self, *args, **kwargs): return json.dumps(payload(url=URL + suffix)).encode(), {}
            with self.assertRaisesRegex(m.FetchError, 'MIGU_PLAY_URL_FORMAT_CHANGED'):
                m.native_play_url(PID, Client, m.NativeAuth.load(environ={}))

    def test_manifest_uri_attributes_and_segment_queries(self):
        raw = b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin?x=1&y=2"\n#EXTINF:6,\nseg.ts?encrypt=one&x=2\n'
        rewritten = m.rewrite_manifest(raw, URL).decode()
        self.assertIn('URI="http://mgsp-ws2.live.miguvideo.com:8088/key.bin?x=1&y=2"', rewritten)
        self.assertIn('http://mgsp-ws2.live.miguvideo.com:8088/seg.ts?encrypt=one&x=2', rewritten)


class AttachmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = sorted(Path(os.environ['MIGU_HAR_DIR']).glob('*.har')) if os.environ.get('MIGU_HAR_DIR') else []
        if len(cls.files) != 6:
            raise unittest.SkipTest('Set MIGU_HAR_DIR to the directory containing the six HAR attachments')

    def test_all_captures_offline(self):
        counts = {'hls': 0, 'epg': 0, 'vod': 0, 'history': 0}
        for path in self.files:
            entry = json.loads(path.read_text())['log']['entries'][0]
            content = entry['response']['content']
            raw = content['text'].encode()
            if content.get('encoding') == 'base64': raw = base64.b64decode(raw)
            url = entry['request']['url']
            if '.m3u8' in url:
                kind, refs = m.hls_references(raw, url)
                self.assertEqual(kind, 'media')
                rewritten = m.rewrite_manifest(raw, url)
                _, absolute_refs = m.hls_references(rewritten, url)
                self.assertEqual(refs, absolute_refs)
                for ref, line in zip(refs, [s.strip() for s in raw.decode().splitlines() if s.strip() and not s.startswith('#')]):
                    self.assertEqual(ref, urljoin(url, line))
                    self.assertEqual(urlsplit(ref).query, urlsplit(line).query)
                counts['hls'] += 1
            elif 'program-sc' in url:
                pid = urlsplit(url).path.split('/')[-2]
                now = datetime(2026, 10, 20, 14, tzinfo=timezone.utc)
                rows = m.official_programmes(pid, raw, now)
                self.assertTrue(rows)
                xml, stats, _ = m.render_epg({pid: rows}, now)
                self.assertEqual(stats['programmes'], len(rows))
                self.assertIn(b'+0800', xml)
                counts['epg'] += 1
            elif 'play-pre' in url:
                data = json.loads(raw)
                self.assertEqual(data['body']['urlInfo']['videoType'], 'vod')
                counts['vod'] += 1
            else:
                self.assertIn('user-play-history', url)
                counts['history'] += 1
        self.assertEqual(counts, {'hls': 2, 'epg': 1, 'vod': 2, 'history': 1})


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]], verbosity=2)
