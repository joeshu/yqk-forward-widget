import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Plugins' / 'crypto_compat'))
sys.path.insert(0, str(ROOT / 'Plugins'))
import hostcrypto
SPEC = importlib.util.spec_from_file_location(
    'hgtv_public_1_0_5_adapter', ROOT / 'Examples' / 'hgtv-python' / 'hgtv_public_1_0_5.py')
hgtv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hgtv)
SPEC_104 = importlib.util.spec_from_file_location(
    'hgtv_public_1_0_4_adapter', ROOT / 'Examples' / 'hgtv-python-1.0.4' / 'hgtv_public_1_0_4.py')
hgtv104 = importlib.util.module_from_spec(SPEC_104)
SPEC_104.loader.exec_module(hgtv104)


def box(kind, payload):
    return struct.pack('>I4s', len(payload) + 8, kind) + payload


def hevc_config(level=186):
    record = bytearray(23)
    record[0] = 1
    record[12] = level
    record[22] = 1
    # SPS includes emulation-prevention bytes before general_level_idc.
    sps = bytearray.fromhex('420103016000000300000300000300000300ba00')
    sps[18] = level
    array = bytes([0x80 | 33]) + struct.pack('>H', 1) + struct.pack('>H', len(sps)) + sps
    return bytes(record) + array


def encrypted_fixture():
    key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
    iv8 = bytes.fromhex('f0f1f2f3f4f5f6f7')
    plain = b'fixture-video-frame-bytes'
    ctr = hostcrypto.AES_CTR(key, iv8 + b'\0' * 8)
    encrypted = ctr.update(plain)
    ctr.close()
    ftyp = box(b'ftyp', b'isom\0\0\x02\0isomiso2')
    frma = box(b'frma', b'hvc1')
    schm = box(b'schm', b'\0\0\0\0cenc\0\x01\0\0')
    tenc = box(b'tenc', b'\0\0\0\0\0\x01\x08' + b'k' * 16)
    sinf = box(b'sinf', frma + schm + box(b'schi', tenc))
    visual_entry = bytearray(78)
    struct.pack_into('>HH', visual_entry, 24, 360, 640)
    sample_entry = box(b'encv', bytes(visual_entry) + box(b'hvcC', hevc_config()) + sinf)
    stsd = box(b'stsd', b'\0' * 4 + struct.pack('>I', 1) + sample_entry)
    stsz = box(b'stsz', b'\0' * 4 + struct.pack('>II', 0, 1) + struct.pack('>I', len(plain)))
    stsc = box(b'stsc', b'\0' * 4 + struct.pack('>I', 1) + struct.pack('>III', 1, 1, 1))
    saiz = box(b'saiz', b'\0' * 4 + b'\x08' + struct.pack('>I', 1))
    senc = box(b'senc', b'\0' * 4 + struct.pack('>I', 1) + iv8)

    def make_moov(chunk_offset, aux_offset):
        stco = box(b'stco', b'\0' * 4 + struct.pack('>II', 1, chunk_offset))
        saio = box(b'saio', b'\0' * 4 + struct.pack('>II', 1, aux_offset))
        stbl = box(b'stbl', stsd + stsz + stsc + stco + saiz + saio + senc)
        return box(b'moov', box(b'trak', box(b'mdia', box(b'minf', stbl))))

    moov = make_moov(0, 0)
    aux_offset = len(ftyp) + moov.index(senc) + 16
    chunk_offset = len(ftyp) + len(moov) + 8
    moov = make_moov(chunk_offset, aux_offset)
    media = ftyp + moov + box(b'mdat', encrypted) + box(b'free', b'\0' * 9000)
    sample_offset = chunk_offset
    return media, key, plain, sample_offset


class HgtvAdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.media, self.key, self.plain, self.sample_offset = encrypted_fixture()
        self.encrypted_path = Path(self.tmp.name, 'encrypted.mp4')
        self.decrypted_path = Path(self.tmp.name, 'decrypted.mp4')
        self.decrypted_104_path = Path(self.tmp.name, 'decrypted-104.mp4')
        self.encrypted_path.write_bytes(self.media)
        hgtv._cenc_decrypt(str(self.encrypted_path), str(self.decrypted_path), self.key)
        hgtv104._cenc_decrypt(str(self.encrypted_path), str(self.decrypted_104_path), self.key)

    def tearDown(self):
        self.tmp.cleanup()

    def test_cenc_decrypt_uses_hostcrypto_and_produces_clear_mp4_sample(self):
        output = self.decrypted_path.read_bytes()
        self.assertTrue(hgtv._verify_mp4(str(self.decrypted_path)))
        self.assertEqual(output[self.sample_offset:self.sample_offset + len(self.plain)], self.plain)
        self.assertIn(b'hvc1', output)
        self.assertNotIn(b'encv', output)
        self.assertNotIn(b'senc', output)

    def test_python_104_cenc_decrypt_uses_hostcrypto_and_produces_clear_mp4_sample(self):
        output = self.decrypted_104_path.read_bytes()
        self.assertTrue(hgtv104._verify_mp4(str(self.decrypted_104_path)))
        self.assertEqual(output[self.sample_offset:self.sample_offset + len(self.plain)], self.plain)
        self.assertIn(b'hvc1', output)
        self.assertNotIn(b'encv', output)
        self.assertNotIn(b'senc', output)

    def test_cenc_decrypt_normalizes_overreported_hevc_level_for_ios(self):
        for output in (self.decrypted_path.read_bytes(), self.decrypted_104_path.read_bytes()):
            self.assertEqual(output[8:12], b'hvc1')
            hvcc_type = output.index(b'hvcC')
            hvcc_size = struct.unpack_from('>I', output, hvcc_type - 4)[0]
            record = output[hvcc_type + 4:hvcc_type - 4 + hvcc_size]
            self.assertEqual(record[12], 93)  # 360x640, ≤60 fps -> HEVC level 3.1
            pos = 23
            sps_level = None
            for _ in range(record[22]):
                nal_type = record[pos] & 0x3F
                count = struct.unpack_from('>H', record, pos + 1)[0]
                pos += 3
                for _ in range(count):
                    size = struct.unpack_from('>H', record, pos)[0]
                    pos += 2
                    nal = record[pos:pos + size]
                    pos += size
                    if nal_type == 33:
                        rbsp = bytearray()
                        zeros = 0
                        for byte in nal[2:]:
                            if zeros >= 2 and byte == 3:
                                continue
                            rbsp.append(byte)
                            zeros = min(2, zeros + 1) if byte == 0 else 0
                        sps_level = rbsp[12]
            self.assertEqual(sps_level, 93)

    def test_cenc_decrypt_works_with_hostcrypto_when_pycryptodome_is_absent(self):
        for module, output_path in ((hgtv, self.decrypted_path),
                                    (hgtv104, self.decrypted_104_path)):
            with self.subTest(version=module.VERSION), \
                 mock.patch.object(module, '_HAS_CRYPTO', False):
                module._cenc_decrypt(str(self.encrypted_path), str(output_path), self.key)
                output = output_path.read_bytes()
                self.assertEqual(output[self.sample_offset:self.sample_offset + len(self.plain)], self.plain)

    @unittest.skipUnless(shutil.which('node'), 'requires Node to verify the JavaScript CENC path')
    def test_node_cenc_decrypt_and_range_parser_match_python_adapter(self):
        source = ROOT / 'Examples' / 'hgtv-node' / 'hgtv.js'
        test_module = Path(self.tmp.name, 'hgtv-node-test.cjs')
        original = source.read_text()
        marker = 'module.exports = site;'
        self.assertIn(marker, original)
        test_module.write_text(original.replace(
            marker, 'module.exports = {decryptCenc, verifyMp4, parseByteRange};'))
        runner = Path(self.tmp.name, 'run-node-cenc.cjs')
        runner.write_text('''const api=require(process.argv[2]);
          api.decryptCenc(process.argv[3],process.argv[4],Buffer.from(process.argv[5],'hex'));
          if(!api.verifyMp4(process.argv[4]))process.exit(2);
          const range=api.parseByteRange('bytes=2-5',10);
          if(!range||range.start!==2||range.end!==5||!range.partial)process.exit(3);''')
        subprocess.run([shutil.which('node'), str(runner), str(test_module),
                        str(self.encrypted_path), str(Path(self.tmp.name, 'node-decrypted.mp4')),
                        self.key.hex()], check=True, capture_output=True, text=True, timeout=10)
        output = Path(self.tmp.name, 'node-decrypted.mp4').read_bytes()
        self.assertEqual(output[self.sample_offset:self.sample_offset + len(self.plain)], self.plain)
        self.assertNotIn(b'senc', output)

    def test_python_play_uses_lazy_host_proxy_and_range_head(self):
        class HTTP:
            cache = hgtv.BoundedCache()
            def page(self, *_args): return {}
            def compat(self, *_args):
                raise hgtv.SourceError('public fallback unavailable', status=403,
                                       stage='resolve_api', code='public_unavailable')

        spider = hgtv.Spider(http=HTTP())
        spider._cctvhost_proxy_url = 'http://127.0.0.1:18782/proxy'
        with mock.patch.object(hgtv, '_signed_model', return_value={
                'video_list': {'1080p': {'definition': '1080p'}, '720p': {'definition': '720p'}}}), \
             mock.patch.object(hgtv, '_decrypt_to_file', return_value=str(self.decrypted_path)):
            result = spider.playerContent('1080p', '12345~67890')
            self.assertEqual(result['url'], 'cenc://67890?q=1080p')
            self.assertEqual(result['proxy'], 1)
            self.assertEqual(result['verification'], 'signed-cenc-local-proxy')

            partial = spider.localProxy({'url': result['url'], 'method': 'GET',
                                         'range': f'bytes={self.sample_offset + 2}-{self.sample_offset + len(self.plain) - 3}'})
            self.assertEqual(partial[0], 206)
            self.assertEqual(partial[2], self.plain[2:-2])
            self.assertEqual(partial[1]['Content-Range'],
                             f'bytes {self.sample_offset + 2}-{self.sample_offset + len(self.plain) - 3}/{len(self.decrypted_path.read_bytes())}')

            head = spider.localProxy({'url': result['url'], 'method': 'HEAD', 'range': 'bytes=0-0'})
            self.assertEqual(head[0], 206)
            self.assertEqual(head[1]['Content-Length'], '1')
            self.assertEqual(head[2], b'')

            invalid = spider.localProxy({'url': result['url'], 'range': 'bytes=999999-'})
            self.assertEqual(invalid[0], 416)

    def test_python_proxy_accepts_numeric_quality_selected_from_video_list_index(self):
        spider = hgtv.Spider()
        with mock.patch.object(hgtv, '_decrypt_to_file', return_value=str(self.decrypted_path)):
            status, headers, body = spider.localProxy({
                'url': 'cenc://67890?q=4', 'method': 'GET', 'range': 'bytes=0-3'})
        self.assertEqual(status, 206)
        self.assertEqual(headers['Content-Range'], 'bytes 0-3/%d' % self.decrypted_path.stat().st_size)
        self.assertEqual(body, self.decrypted_path.read_bytes()[:4])

    def test_python_104_play_uses_host_proxy_and_returns_media_bytes(self):
        class HTTP:
            cache = hgtv104.BoundedCache()
            def page(self, *_args): return {}
            def compat(self, *_args):
                raise hgtv104.SourceError('public fallback unavailable', status=403,
                                          stage='resolve_api', code='public_unavailable')

        spider = hgtv104.Spider(http=HTTP())
        spider._cctvhost_proxy_url = 'http://127.0.0.1:18782/proxy'
        with mock.patch.object(hgtv104, 'resolve_signed', return_value=(
                'cenc://67890?q=4', hgtv104.ORIGIN + '/', None)), \
             mock.patch.object(hgtv104, '_decrypt_to_file', return_value=str(self.decrypted_104_path)):
            result = spider.playerContent('官网完整播放', '12345~67890')
            self.assertEqual(result['url'], 'cenc://67890?q=4')
            self.assertEqual(result['proxy'], 1)
            response = spider.localProxy({'url': result['url'], 'method': 'GET',
                                          'range': 'bytes=0-3'})
        self.assertEqual(response[0], 206)
        self.assertEqual(response[2], self.decrypted_104_path.read_bytes()[:4])

    def test_python_spider_writes_decrypted_cache_under_host_data_directory(self):
        for module in (hgtv, hgtv104):
            with self.subTest(version=module.VERSION):
                previous = module._DEC_DIR
                try:
                    spider = module.Spider()
                    spider._cctvhost_data_dir = self.tmp.name
                    spider.init()
                    self.assertEqual(module._DEC_DIR, os.path.join(
                        os.path.realpath(self.tmp.name), 'hgtv-python-cache'))
                finally:
                    module._DEC_DIR = previous


if __name__ == '__main__':
    unittest.main()
