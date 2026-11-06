import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import struct
import sys
import threading
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Plugins' / 'crypto_compat'))
sys.path.insert(0, str(ROOT / 'Plugins'))
spec = importlib.util.spec_from_file_location(
    'example_encrypted_media', ROOT / 'Plugins' / 'example-encrypted-media.py')
example = importlib.util.module_from_spec(spec)
spec.loader.exec_module(example)


def box(kind, payload):
    return struct.pack('>I4s', len(payload) + 8, kind) + payload


def make_cenc_mp4():
    key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
    iv = bytes.fromhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff')
    clear_sample = b'fixture encrypted video sample'
    cipher = example.hostcrypto.AES_CTR(key, iv)
    encrypted_sample = cipher.update(clear_sample)
    cipher.close()

    ftyp = box(b'ftyp', b'isom\x00\x00\x02\x00isomiso2')
    frma = box(b'frma', b'hvc1')
    schm = box(b'schm', b'\x00\x00\x00\x00cenc\x00\x01\x00\x00')
    tenc = box(b'tenc', b'\x00\x00\x00\x00\x00\x01\x10' + b'k' * 16)
    schi = box(b'schi', tenc)
    sinf = box(b'sinf', frma + schm + schi)
    sample_entry = box(b'encv', b'\x00' * 78 + sinf)
    stsd = box(b'stsd', b'\x00' * 4 + struct.pack('>I', 1) + sample_entry)
    stsz = box(b'stsz', b'\x00' * 4 + struct.pack('>II', 0, 1) + struct.pack('>I', len(clear_sample)))
    stsc = box(b'stsc', b'\x00' * 4 + struct.pack('>I', 1) + struct.pack('>III', 1, 1, 1))
    senc = box(b'senc', b'\x00' * 4 + struct.pack('>I', 1) + iv)
    def make_moov(chunk_offset):
        stco = box(b'stco', b'\x00' * 4 + struct.pack('>II', 1, chunk_offset))
        stbl = box(b'stbl', stsd + stsz + stsc + stco + senc)
        minf = box(b'minf', stbl)
        mdia = box(b'mdia', minf)
        return box(b'moov', box(b'trak', mdia))

    moov = make_moov(0)
    sample_offset = len(ftyp) + len(moov) + 8
    moov = make_moov(sample_offset)
    media = ftyp + moov + box(b'mdat', encrypted_sample)
    return media, key.hex(), clear_sample, sample_offset


class ExampleEncryptedMediaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.media, cls.key, cls.plain, cls.sample_offset = make_cenc_mp4()

        class FixtureHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                start, end = 0, len(cls.media) - 1
                value = self.headers.get('Range', '')
                if value:
                    unit, requested = value.split('=', 1)
                    left, right = requested.split('-', 1)
                    if unit != 'bytes' or not left:
                        self.send_error(416)
                        return
                    start, end = int(left), int(right)
                if start < 0 or end < start or end >= len(cls.media):
                    self.send_response(416)
                    self.send_header('Content-Range', f'bytes */{len(cls.media)}')
                    self.end_headers()
                    return
                body = cls.media[start:end + 1]
                self.send_response(206)
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(cls.media)}')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Accept-Ranges', 'bytes')
                self.end_headers()
                if self.command != 'HEAD':
                    self.wfile.write(body)

            def do_HEAD(self):
                self.do_GET()

            def log_message(self, *_):
                pass

        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f'http://127.0.0.1:{cls.server.server_port}/fixture.mp4'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(2)

    def test_local_proxy_decrypts_cenc_and_patches_mp4_box_types(self):
        spider = example.Spider()
        spider.items['ep-1'] = {
            'id': 'ep-1', 'title': 'Fixture', 'url': self.url,
            'key': self.key, 'headers': {},
        }
        response = spider.localProxy({'url': 'cenc://ep-1', 'method': 'GET'})
        self.assertEqual(response[0], 200)
        self.assertEqual(response[1]['Content-Length'], str(len(self.media)))
        output = response[2]
        self.assertEqual(output[self.sample_offset:self.sample_offset + len(self.plain)], self.plain)
        self.assertIn(b'hvc1', output)
        self.assertNotIn(b'encv', output)
        self.assertNotIn(b'sinf', output)
        self.assertNotIn(b'senc', output)

    def test_local_proxy_honors_ranges_head_and_unsatisfiable_ranges(self):
        spider = example.Spider()
        spider.items['ep-1'] = {
            'id': 'ep-1', 'title': 'Fixture', 'url': self.url,
            'key': self.key, 'headers': {},
        }
        sample_end = self.sample_offset + len(self.plain) - 1
        partial = spider.localProxy({'url': 'cenc://ep-1', 'method': 'GET',
                                     'range': f'bytes={self.sample_offset + 3}-{sample_end - 2}'})
        self.assertEqual(partial[0], 206)
        self.assertEqual(partial[1]['Content-Range'],
                         f'bytes {self.sample_offset + 3}-{sample_end - 2}/{len(self.media)}')
        self.assertEqual(partial[2], self.plain[3:-2])
        head = spider.localProxy({'url': 'cenc://ep-1', 'method': 'HEAD', 'range': 'bytes=0-0'})
        self.assertEqual(head[0], 206)
        self.assertEqual(head[2], b'')
        invalid = spider.localProxy({'url': 'cenc://ep-1', 'range': f'bytes={len(self.media)}-'})
        self.assertEqual(invalid[0], 416)


if __name__ == '__main__':
    unittest.main()
