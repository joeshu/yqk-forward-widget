import functools
import http.client
import http.server
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request

PLUGINS = Path(__file__).resolve().parents[1] / 'Plugins'
sys.path.insert(0, str(PLUGINS))
from host_dash import DashError, parse_mpd, byte_range
from host_media_url import http_url
from host_media_runtime import MediaRuntime
from host_media_relay import MediaRelay

spec = importlib.util.spec_from_file_location('dash_test_service', PLUGINS / 'media-service.py')
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


def mpd(template, **attrs):
    extra = ' '.join(f'{k}="{v}"' for k, v in attrs.items())
    return f'''<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT6S" {extra}>
    <Period><AdaptationSet mimeType="video/mp4" codecs="avc1.42c00b"><Representation id="v1" bandwidth="200000" width="160" height="90">
    {template}</Representation></AdaptationSet></Period></MPD>'''.encode()


class DashManifestTests(unittest.TestCase):
    def test_signed_unicode_address_keeps_existing_bytes(self):
        value = 'https://cdn.example/中文/第%20一集.mpd?sig=a%2Bb%2fc+z&tag=中文&x=1&x=2'
        result = http_url(value)
        self.assertIn('/%E4%B8%AD%E6%96%87/', result)
        self.assertIn('sig=a%2Bb%2fc+z&tag=', result)
        self.assertTrue(result.endswith('&x=1&x=2'))
        self.assertEqual(http_url(result), result)
        self.assertEqual(http_url('https://[::1]:443/a'), 'https://[::1]:443/a')
        self.assertEqual(http_url('https://例子.测试/a'), 'https://xn--fsqu00a.xn--0zwm56d/a')

    def test_timeline_template_and_duration(self):
        data = mpd('<SegmentTemplate timescale="1000" startNumber="7" initialization="init-$RepresentationID$.mp4" media="chunk-$Number%05d$-$Time$.m4s"><SegmentTimeline><S t="0" d="2000" r="2"/></SegmentTimeline></SegmentTemplate>')
        track = parse_mpd(data, 'https://cdn.example/中文/a.mpd')['tracks'][0]
        self.assertTrue(track['segments'][0][0].endswith('chunk-00007-0.m4s'))
        self.assertEqual([s[1] for s in track['segments']], [2, 2, 2])
        self.assertEqual(track['number'], 7)

    def test_template_inheritance_and_negative_repeat(self):
        data = b'''<MPD mediaPresentationDuration="PT6S"><Period>
        <AdaptationSet mimeType="audio/mp4" codecs="mp4a.40.2"><SegmentTemplate timescale="1000" initialization="init-$RepresentationID$.mp4" media="$Time$.m4s"><SegmentTimeline><S d="2000" r="-1"/></SegmentTimeline></SegmentTemplate>
        <Representation id="a" bandwidth="60000"><SegmentTemplate startNumber="4"/></Representation></AdaptationSet></Period></MPD>'''
        track = parse_mpd(data, 'https://cdn.example/a.mpd')['tracks'][0]
        self.assertEqual(len(track['segments']), 3)
        self.assertEqual(track['number'], 4)
        self.assertEqual(track['segments'][-1][0], 'https://cdn.example/4000.m4s')

    def test_segment_list_ranges_and_limits(self):
        data = mpd('<BaseURL>video.mp4</BaseURL><SegmentList duration="3"><Initialization range="0-99"/><SegmentURL mediaRange="100-199"/><SegmentURL mediaRange="200-399"/></SegmentList>')
        track = parse_mpd(data, 'https://cdn.example/a.mpd')['tracks'][0]
        self.assertEqual(track['init'], 'https://cdn.example/video.mp4')
        self.assertEqual(byte_range(track['init_range']), '100@0')
        self.assertEqual(byte_range(track['segments'][1][2]), '200@200')
        with self.assertRaises(DashError):
            byte_range('20-10')
        with self.assertRaises(DashError):
            parse_mpd(mpd('<SegmentTemplate duration="1" timescale="100000000" initialization="i.mp4" media="$Number$.m4s"/>'), 'https://cdn.example/a.mpd')

    def test_drm_bad_xml_and_unknown_layout_are_explicit(self):
        for data, message in [
            (mpd('<ContentProtection schemeIdUri="urn:uuid:test"/>'), 'requires_license'),
            (mpd('<SegmentBase/>'), 'segment_base_unsupported'),
            (b'<!DOCTYPE foo><MPD/>', 'manifest_invalid'),
            (b'<html>access denied</html>', 'manifest_invalid'),
            (mpd('<SegmentTemplate/>', type='dynamic'), 'timeline_required')]:
            with self.subTest(message=message), self.assertRaisesRegex(DashError, message):
                parse_mpd(data, 'https://cdn.example/a.mpd')


@unittest.skipUnless(shutil.which('ffmpeg'), 'ffmpeg is used only to generate/decode test media')
class DashPlaybackTests(unittest.TestCase):
    def test_http_dash_to_hls_decodes_audio_video_with_headers_on_every_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / '中文'; folder.mkdir()
            generated = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=10', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
                '-t', '4', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '20', '-c:a', 'aac',
                '-f', 'dash', '-seg_duration', '2', '-use_timeline', '1', '-use_template', '1', str(folder / 'manifest.mpd')], capture_output=True, text=True, timeout=20)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            requests = []
            class Upstream(http.server.SimpleHTTPRequestHandler):
                def do_GET(self):
                    requests.append((self.path, dict(self.headers)))
                    if self.headers.get('Referer') != 'https://source.example/' or self.headers.get('X-Media') != 'fixture':
                        self.send_error(403); return
                    super().do_GET()
                def log_message(self, *_): pass
            upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Upstream, directory=tmp))
            upthread = threading.Thread(target=upstream.serve_forever, daemon=True); upthread.start()
            address = f'http://127.0.0.1:{upstream.server_port}/中文/manifest.mpd?sig=a%2Bb+z'
            class Engine:
                def call(self, operation, args):
                    return {'url': address, 'headers': {'Referer': 'https://source.example/', 'X-Media': 'fixture'}, 'format': 'mpd'}
                def close(self): pass
            server = service.Server(('127.0.0.1', 0), MediaRuntime(Engine()))
            worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
            client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=10)
            try:
                client.request('POST', '/api/v1/play', json.dumps({'id': 'episode'}), {'Content-Type': 'application/json'})
                response = client.getresponse(); value = json.loads(response.read())
                self.assertEqual(response.status, 200, value)
                result = value['data']
                self.assertTrue(result['dashRemuxed'])
                self.assertEqual(result['originalURL'], address)
                self.assertEqual(result['playbackEngine'], 'avplayer')
                master = urllib.request.urlopen(result['url']).read().decode()
                self.assertIn('TYPE=AUDIO', master)
                self.assertIn('CODECS=', master)
                decoded = subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'info', '-i', result['url'], '-map', '0:v:0', '-map', '0:a:0', '-f', 'null', '-'], capture_output=True, text=True, timeout=25)
                self.assertEqual(decoded.returncode, 0, decoded.stderr)
                self.assertRegex(decoded.stderr, r'Video:.*h264')
                self.assertRegex(decoded.stderr, r'Audio:.*aac')
                self.assertIn('frame=', decoded.stderr)
                self.assertTrue(any('.m4s' in path for path, _ in requests))
                for path, headers in requests:
                    self.assertNotIn('中文', path)
                    self.assertIn('sig=a%2Bb+z', path)
                    self.assertEqual(headers.get('Referer'), 'https://source.example/')
                    self.assertEqual(headers.get('X-Media'), 'fixture')
            finally:
                client.close(); server.shutdown(); server.server_close(); worker.join(2)
                upstream.shutdown(); upstream.server_close(); upthread.join(2)


if __name__ == '__main__':
    unittest.main()
