import json
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Plugins' / 'crypto_compat'))
sys.path.insert(0, str(ROOT / 'Plugins'))
import hostcrypto
SPEC = importlib.util.spec_from_file_location(
    'hgtv_public_1_0_5_adapter', ROOT / 'Examples' / 'hgtv-python' / 'hgtv_public_1_0_5.py')
hgtv = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hgtv)


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


def encrypted_fixture(codec=b'hvc1'):
    key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
    iv8 = bytes.fromhex('f0f1f2f3f4f5f6f7')
    plain = b'fixture-video-frame-bytes'
    ctr = hostcrypto.AES_CTR(key, iv8 + b'\0' * 8)
    encrypted = ctr.update(plain)
    ctr.close()
    ftyp = box(b'ftyp', b'isom\0\0\x02\0isomiso2')
    frma = box(b'frma', codec)
    schm = box(b'schm', b'\0\0\0\0cenc\0\x01\0\0')
    tenc = box(b'tenc', b'\0\0\0\0\0\x01\x08' + b'k' * 16)
    sinf = box(b'sinf', frma + schm + box(b'schi', tenc))
    visual_entry = bytearray(78)
    struct.pack_into('>HH', visual_entry, 24, 360, 640)
    config = box(b'hvcC', hevc_config()) if codec == b'hvc1' else box(b'avcC', bytes(12))
    sample_entry = box(b'encv', bytes(visual_entry) + config + sinf)
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
        self.encrypted_path.write_bytes(self.media)
        hgtv._cenc_decrypt(str(self.encrypted_path), str(self.decrypted_path), self.key)

    def tearDown(self):
        self.tmp.cleanup()

    def test_cenc_decrypt_uses_hostcrypto_and_produces_clear_mp4_sample(self):
        output = self.decrypted_path.read_bytes()
        self.assertTrue(hgtv._verify_mp4(str(self.decrypted_path)))
        self.assertEqual(output[self.sample_offset:self.sample_offset + len(self.plain)], self.plain)
        self.assertIn(b'hvc1', output)
        self.assertNotIn(b'encv', output)
        self.assertNotIn(b'senc', output)

    def test_clear_sample_entry_keeps_box_sizes_and_codec_configuration(self):
        output = self.decrypted_path.read_bytes()
        self.assertEqual(output[8:12], self.media[8:12])
        sinf_type = self.media.index(b'sinf')
        self.assertEqual(output[sinf_type:sinf_type + 4], b'free')
        self.assertEqual(output[sinf_type - 4:sinf_type], self.media[sinf_type - 4:sinf_type])
        hvcc = output.index(b'hvcC')
        self.assertEqual(output[hvcc + 4 + 12], 186)  # Preserve encoder profile/level.
        self.assertTrue(hgtv._verify_mp4(str(self.decrypted_path)))

    def test_old_malformed_sinf_cache_is_rejected(self):
        output = bytearray(self.decrypted_path.read_bytes())
        sinf_type = self.media.index(b'sinf')
        output[sinf_type - 4:sinf_type] = b'free'
        output[sinf_type:sinf_type + 4] = bytes(4)
        self.decrypted_path.write_bytes(output)
        self.assertFalse(hgtv._verify_mp4(str(self.decrypted_path)))

    def test_oversized_metadata_is_rejected_without_spider_instance(self):
        path = Path(self.tmp.name, 'large-metadata.mp4')
        ftyp = box(b'ftyp', b'isom' + bytes(4) + b'isom')
        metadata_size = 17 * 1024 * 1024
        with path.open('wb') as stream:
            stream.write(ftyp + struct.pack('>I4s', metadata_size, b'moov'))
            stream.truncate(len(ftyp) + metadata_size)
        for module in (hgtv,):
            self.assertFalse(module._verify_mp4(str(path)))

    def test_encrypted_avc_codec_is_restored_from_frma(self):
        media, key, plain, offset = encrypted_fixture(b'avc1')
        self.encrypted_path.write_bytes(media)
        hgtv._cenc_decrypt(str(self.encrypted_path), str(self.decrypted_path), key)
        output = self.decrypted_path.read_bytes()
        self.assertIn(b'avc1', output)
        self.assertIn(b'avcC', output)
        self.assertNotIn(b'hvc1', output)
        self.assertEqual(output[offset:offset + len(plain)], plain)
        self.assertTrue(hgtv._verify_mp4(str(self.decrypted_path)))

    def test_cenc_decrypt_works_with_hostcrypto_when_pycryptodome_is_absent(self):
        with mock.patch.object(hgtv, '_HAS_CRYPTO', False):
            hgtv._cenc_decrypt(str(self.encrypted_path), str(self.decrypted_path), self.key)
            output = self.decrypted_path.read_bytes()
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
            self.assertEqual([item['name'] for item in result['alternates']], ['1080p', '720p'])

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

    def test_signed_quality_uses_nested_video_meta_and_defaults_to_highest(self):
        items = {
            '0': {'video_meta': "{'definition': '360p', 'vwidth': 360, 'vheight': 640}",
                  'gear_des_key': '2:h265_hvc1|4:360p|5:normal'},
            '1': {'video_meta': '{"definition":"720p","vwidth":720,"vheight":1280}',
                  'gear_des_key': '2:h265_hvc1|4:720p|5:normal'},
            '2': {'video_meta': "{'definition': '1080p', 'vwidth': 1080, 'vheight': 1920}",
                  'gear_des_key': '2:h265_hvc1|4:1080p|5:normal'},
        }
        for module in (hgtv,):
            with self.subTest(version=module.VERSION):
                picked = module._pick_best({'video_list': items}, None)
                self.assertEqual(picked[1], '1080p')
                self.assertEqual(module._pick_best({'video_list': items}, '360p')[1], '360p')
                self.assertIsNone(module._pick_best({'video_list': items}, '480p'))

    def test_signed_model_registers_anonymous_device_and_queries_current_player_api_for_5_tiers(self):
        from contextlib import ExitStack

        episodes = [
            '7701565033376910360',  # first episode
            '7701820244146261016',  # middle episode
            '7701832903004556312',  # late episode
        ]
        qualities = ['360p', '480p', '540p', '720p', '1080p']
        five_tier_model = {
            'video_list': {
                f'video_{idx + 1}': {
                    'definition': q,
                    'main_url': f'https://media.invalid/{q}.mp4',
                    'spade_a': 'fixture',
                    'video_meta': json.dumps({'definition': q, 'vtype': 'h265'}),
                }
                for idx, q in enumerate(qualities)
            }
        }
        for module in (hgtv,):
            with self.subTest(version=module.VERSION):
                # 当前唯一 Python 适配使用签名 multi_video_model 与 ttEncrypt 注册。
                is_new = hasattr(module, '_post_bytes')
                calls = []
                prev_dir = module._DEC_DIR
                module._DEC_DIR = os.path.join(self.tmp.name, f'cache-{module.VERSION}')
                module._DEVICE_SESSION = None
                for vid in episodes:
                    module._SIGN_CACHE.pop(vid, None)

                class Response:
                    def __init__(self, payload):
                        self.payload = payload
                    def __enter__(self): return self
                    def __exit__(self, *_args): return False
                    def read(self, _limit=-1): return self.payload

                def reg_ids():
                    reg_index = sum(1 for c in calls if urlsplit(c['url']).path.endswith('/device_register/'))
                    return f'770199887766550{reg_index}', f'770199887766990{reg_index}'

                def fake_post(url, body, headers, timeout, max_bytes=8 * 1024 * 1024):
                    calls.append({
                        'url': url,
                        'method': 'POST',
                        'body': body,
                        'headers': {key.lower(): value for key, value in headers.items()},
                        'timeout': timeout,
                    })
                    parsed = urlsplit(url)
                    if parsed.path.endswith('/device_register/'):
                        did, iid = reg_ids()
                        return json.dumps({
                            'device_id_str': did,
                            'install_id_str': iid,
                            'device_id': int(did),
                            'install_id': int(iid),
                        }).encode('utf-8')
                    return json.dumps({
                        'code': 0,
                        'data': {
                            'video_model': json.dumps(five_tier_model),
                        }
                    }).encode('utf-8')

                def fake_urlopen(request, timeout):
                    calls.append({
                        'url': request.full_url,
                        'method': request.get_method(),
                        'body': request.data,
                        'headers': {key.lower(): value for key, value in request.header_items()},
                        'timeout': timeout,
                    })
                    parsed = urlsplit(request.full_url)
                    if parsed.path.endswith('/device_register/'):
                        did, iid = reg_ids()
                        return Response(json.dumps({
                            'device_id_str': did,
                            'install_id_str': iid,
                            'device_id': int(did),
                            'install_id': int(iid),
                        }).encode('utf-8'))
                    return Response(json.dumps({
                        'code': 0,
                        'data': {
                            'video_model': json.dumps(five_tier_model),
                        }
                    }).encode('utf-8'))

                try:
                    with ExitStack() as stack:
                        if is_new:
                            stack.enter_context(mock.patch.object(module, '_post_bytes', side_effect=fake_post))
                        else:
                            stack.enter_context(mock.patch.object(module._ureq, 'urlopen', side_effect=fake_urlopen))
                        for vid in episodes:
                            model = module._signed_model(vid)
                            self.assertIsNotNone(model)
                            for q in qualities:
                                picked = module._pick_best(model, q)
                                self.assertIsNotNone(picked, f'missing {q} for episode {vid}')
                                self.assertEqual(picked[1], q)
                            self.assertEqual(module._pick_best(model, None)[1], '1080p')

                    # 1 anonymous device_register + 3 episode video_model requests (reusing registered device)
                    self.assertEqual(len(calls), 4)
                    reg_call = calls[0]
                    reg_url = urlsplit(reg_call['url'])
                    self.assertEqual(reg_call['method'], 'POST')
                    self.assertEqual(reg_url.path, '/service/2/device_register/')
                    if is_new:
                        self.assertEqual(reg_url.hostname, 'log5-applog-lf.fqnovel.com')
                        self.assertEqual(parse_qs(reg_url.query).get('tt_data'), ['a'])
                        # ttEncrypt 体：746305100000 + 32 字节随机数 + AES-CBC 密文
                        self.assertIsInstance(reg_call['body'], bytes)
                        self.assertTrue(reg_call['body'].startswith(bytes.fromhex('746305100000')))
                        self.assertEqual(reg_call['headers'].get('content-type'),
                                         'application/octet-stream;tt-data=a')
                        self.assertEqual(reg_call['headers'].get('log-encode-type'), 'gzip')
                        self.assertEqual(reg_call['headers'].get('accept-encoding'), 'identity')
                    else:
                        self.assertEqual(reg_url.hostname, 'log5-applog.fqnovel.com')
                        reg_body = json.loads(reg_call['body'].decode('utf-8'))
                        self.assertEqual(reg_body['magic_tag'], 'ss_app_log')
                        self.assertEqual(reg_body['header']['aid'], 8662)
                        self.assertEqual(reg_body['header']['package'], 'com.phoenix.read')
                        self.assertNotEqual(module._branch_of(reg_call['url'], reg_call['body'],
                                                              int(reg_call['headers']['x-khronos'])), 1)

                    for idx, vid in enumerate(episodes):
                        play_call = calls[idx + 1]
                        play_url = urlsplit(play_call['url'])
                        self.assertEqual(play_call['method'], 'POST')
                        self.assertEqual(play_url.hostname, 'api5-normal-sinfonlineb.fqnovel.com')
                        query = parse_qs(play_url.query)
                        self.assertEqual(query['device_id'], ['7701998877665501'])
                        self.assertEqual(query['iid'], ['7701998877669901'])
                        body_json = json.loads(play_call['body'].decode('utf-8'))
                        self.assertTrue(body_json['biz_param']['need_all_video_definition'])
                        self.assertTrue(play_call['headers'].get('x-gorgon'))
                        self.assertTrue(play_call['headers'].get('x-helios'))
                        branch = module._branch_of(play_call['url'], play_call['body'],
                                                   int(play_call['headers']['x-khronos']))
                        if is_new:
                            self.assertEqual(play_url.path, '/novel/player/multi_video_model/v1/')
                            self.assertEqual(query['version_code'], ['71332'])
                            self.assertTrue(query.get('cdid'))
                            self.assertNotIn('openudid', query)
                            self.assertNotIn('key_register_ts', query)
                            self.assertNotIn('req_type', query)
                            self.assertEqual(body_json['mixed_video_id_map'], {'1004': [vid]})
                            self.assertNotIn('video_id', body_json)
                            self.assertNotIn('content_type', body_json)
                            self.assertEqual(body_json['biz_param']['video_platform'], 1024)
                            self.assertEqual(body_json['biz_param']['detail_page_version'], 0)
                            self.assertEqual(play_call['headers'].get('user-agent'), module._PLAYBACK_UA)
                            self.assertTrue(play_call['headers'].get('x-medusa'))
                            self.assertEqual(play_call['headers'].get('x-tt-store-region'), 'cn')
                            self.assertNotIn('cookie', play_call['headers'])
                            self.assertNotIn('x-ss-stub', play_call['headers'])
                            self.assertNotIn('x-tt-request-tag', play_call['headers'])
                            self.assertEqual(branch, 0)
                        else:
                            self.assertEqual(play_url.path, '/novel/player/video_model/v1/')
                            self.assertEqual(query['version_code'], ['73532'])
                            self.assertTrue(query.get('cdid'))
                            self.assertTrue(query.get('openudid'))
                            self.assertTrue(query.get('rom_version'))
                            self.assertTrue(query.get('key_register_ts'))
                            self.assertEqual(query.get('req_type'), ['1'])
                            self.assertEqual(body_json['video_id'], vid)
                            self.assertEqual(body_json['content_type'], 1)
                            self.assertEqual(body_json['biz_param']['video_platform'], 3)
                            self.assertTrue(play_call['headers'].get('x-ss-stub'))
                            self.assertIn('install_id=7701998877669901', play_call['headers'].get('cookie', ''))
                            self.assertNotEqual(branch, 1)
                finally:
                    module._DEC_DIR = prev_dir
                    module._DEVICE_SESSION = None

    def test_host_file_proxy_returns_reference_and_preserves_head_length(self):
        for module, path in ((hgtv, self.decrypted_path),):
            spider = module.Spider()
            spider._cctvhost_file_proxy_supported = True
            with mock.patch.object(module, '_decrypt_to_file', return_value=str(path)):
                status, headers, reference = spider.localProxy({
                    'url': 'cenc://67890?q=1080p', 'method': 'HEAD', 'range': 'bytes=2-'})
            self.assertEqual(status, 206)
            self.assertTrue(reference['__cctvhostFileResponse'])
            self.assertEqual(reference['offset'], 2)
            self.assertEqual(reference['length'], path.stat().st_size - 2)
            self.assertEqual(int(headers['Content-Length']), reference['length'])

    def test_missing_public_preview_is_not_replaced_with_full_signed_video(self):
        for module in (hgtv,):
            class HTTP:
                cache = module.BoundedCache()
                def page(self, *_args): return {}
                def probe(self, *_args): raise module.SourceError('not found', 404)
            spider = module.Spider(http=HTTP())
            with mock.patch.object(module, 'resolve_signed') as signed:
                result = spider.playerContent('公开试看（片段）', '12345~67890')
            self.assertEqual(result['error_code'], 'public_preview_unavailable')
            self.assertFalse(result['url'])
            signed.assert_not_called()

    def test_python_spider_writes_decrypted_cache_under_host_data_directory(self):
        for module in (hgtv,):
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



    def test_middle_and_late_episodes_end_to_end_spade_and_cenc_decryption(self):
        import base64
        import hashlib
        from Crypto.Cipher import AES

        seed = b'hongguo-seed-2026'
        seed_b64 = base64.b64encode(seed).decode('ascii')
        h1 = hashlib.sha512(seed).digest()
        h2 = hashlib.sha512(h1 + hgtv._SPADE_CONST).digest()

        def encrypt_spade_url(plain_url):
            pt = plain_url.encode('utf-8')
            pad = 16 - (len(pt) % 16)
            ct = AES.new(h2[:16], AES.MODE_CBC, h2[16:32]).encrypt(pt + bytes([pad] * pad))
            return base64.b64encode(b'\xa8\x00\x01\x00' + ct).decode('ascii')

        spade_a = 'nrMdy1OwG/xSsBv/YoMeyWSFHPxisiv/erAy4U6fA+BOmQ=='
        self.assertEqual(hgtv._content_key(spade_a), self.key.hex())

        qualities = ['360p', '480p', '540p', '720p', '1080p']
        target_episodes = ['7701820244146261016', '7701832903004556312']

        for module in (hgtv,):
            with self.subTest(version=module.VERSION):
                prev_dir = module._DEC_DIR
                module._DEC_DIR = os.path.join(self.tmp.name, f'e2e-{module.VERSION}')
                module._DEVICE_SESSION = None
                for vid in target_episodes:
                    module._SIGN_CACHE.pop(vid, None)

                class Response:
                    def __init__(self, payload):
                        self.payload = payload
                        self.pos = 0
                    def __enter__(self): return self
                    def __exit__(self, *_args): return False
                    def read(self, size=-1):
                        if size is None or size < 0:
                            chunk = self.payload[self.pos:]
                            self.pos = len(self.payload)
                            return chunk
                        chunk = self.payload[self.pos:self.pos + size]
                        self.pos += len(chunk)
                        return chunk

                def model_response(vid):
                    vlist = {}
                    for idx, q in enumerate(qualities):
                        vlist[f'video_{idx + 1}'] = {
                            'definition': q,
                            'main_url': encrypt_spade_url(f'https://v3-reading.qznovelvod.com/{vid}/{q}.mp4'),
                            'spade_a': spade_a,
                            'encrypt_info': {'encrypt': True, 'spade_a': spade_a},
                            'gear_des_key': f'1:encrypt|2:h265_hvc1|4:{q}|5:normal',
                            'video_meta': json.dumps({'definition': q, 'vtype': 'h265', 'vwidth': 1080, 'vheight': 1920}),
                        }
                    return json.dumps({
                        'code': 0,
                        'data': {'key_seed': seed_b64, 'video_model': json.dumps({'key_seed': seed_b64, 'video_list': vlist})},
                    }).encode('utf-8')

                def fake_post(url, body, headers, timeout, max_bytes=8 * 1024 * 1024):
                    u = urlsplit(url)
                    if u.path.endswith('/device_register/'):
                        return json.dumps({
                            'device_id_str': '7701998877665588',
                            'install_id_str': '7701998877669988',
                        }).encode('utf-8')
                    if u.path == '/novel/player/multi_video_model/v1/':
                        req_body = json.loads(body.decode('utf-8'))
                        return model_response(req_body['mixed_video_id_map']['1004'][0])
                    raise AssertionError(f'unexpected URL {url}')

                def fake_urlopen(request, timeout=25):
                    u = urlsplit(request.full_url)
                    if u.hostname == 'v3-reading.qznovelvod.com':
                        return Response(self.media)
                    raise AssertionError(f'unexpected URL {request.full_url}')

                def fake_urlopen_all(request, timeout=25):
                    u = urlsplit(request.full_url)
                    if u.path.endswith('/device_register/'):
                        return Response(json.dumps({
                            'device_id_str': '7701998877665588',
                            'install_id_str': '7701998877669988',
                        }).encode('utf-8'))
                    if u.path == '/novel/player/video_model/v1/':
                        req_body = json.loads(request.data.decode('utf-8'))
                        return Response(model_response(req_body['video_id']))
                    if u.hostname == 'v3-reading.qznovelvod.com':
                        return Response(self.media)
                    raise AssertionError(f'unexpected URL {request.full_url}')

                from contextlib import ExitStack
                try:
                    with ExitStack() as stack:
                        stack.enter_context(mock.patch.object(module, '_ffmpeg_path', return_value=''))
                        if hasattr(module, '_post_bytes'):
                            stack.enter_context(mock.patch.object(module, '_post_bytes', side_effect=fake_post))
                            stack.enter_context(mock.patch.object(module._ureq, 'urlopen', side_effect=fake_urlopen))
                        else:
                            stack.enter_context(mock.patch.object(module._ureq, 'urlopen', side_effect=fake_urlopen_all))
                        for vid in target_episodes:
                            out_file = module._decrypt_to_file(vid, '1080p')
                            self.assertIsNotNone(out_file)
                            self.assertTrue(module._verify_mp4(out_file))
                            clear_bytes = Path(out_file).read_bytes()
                            self.assertEqual(
                                clear_bytes[self.sample_offset:self.sample_offset + len(self.plain)],
                                self.plain,
                            )
                finally:
                    module._DEC_DIR = prev_dir
                    module._DEVICE_SESSION = None



    def test_unencrypted_audio_track_before_encrypted_video_track_is_preserved(self):
        key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
        iv8 = bytes.fromhex('f0f1f2f3f4f5f6f7')
        audio_plain = b'clear-aac-audio-sample-bytes'
        video_plain = b'encrypted-hevc-video-sample-bytes'
        ctr = hostcrypto.AES_CTR(key, iv8 + b'\0' * 8)
        video_enc = ctr.update(video_plain)
        ctr.close()

        ftyp = box(b'ftyp', b'isom\0\0\x02\0isomiso2')
        # Track 1: unencrypted mp4a audio track (no saiz/saio/senc)
        audio_entry = box(b'mp4a', bytes(28))
        a_stsd = box(b'stsd', b'\0' * 4 + struct.pack('>I', 1) + audio_entry)
        a_stsz = box(b'stsz', b'\0' * 4 + struct.pack('>II', 0, 1) + struct.pack('>I', len(audio_plain)))
        a_stsc = box(b'stsc', b'\0' * 4 + struct.pack('>I', 1) + struct.pack('>III', 1, 1, 1))

        # Track 2: encrypted encv video track
        frma = box(b'frma', b'hvc1')
        schm = box(b'schm', b'\0\0\0\0cenc\0\x01\0\0')
        tenc = box(b'tenc', b'\0\0\0\0\0\x01\x08' + b'k' * 16)
        sinf = box(b'sinf', frma + schm + box(b'schi', tenc))
        visual_entry = bytearray(78)
        struct.pack_into('>HH', visual_entry, 24, 360, 640)
        v_entry = box(b'encv', bytes(visual_entry) + box(b'hvcC', hevc_config()) + sinf)
        v_stsd = box(b'stsd', b'\0' * 4 + struct.pack('>I', 1) + v_entry)
        v_stsz = box(b'stsz', b'\0' * 4 + struct.pack('>II', 0, 1) + struct.pack('>I', len(video_plain)))
        v_stsc = box(b'stsc', b'\0' * 4 + struct.pack('>I', 1) + struct.pack('>III', 1, 1, 1))
        v_saiz = box(b'saiz', b'\0' * 4 + b'\x08' + struct.pack('>I', 1))
        v_senc = box(b'senc', b'\0' * 4 + struct.pack('>I', 1) + iv8)

        def build_moov(a_off, v_off, aux_off):
            a_stco = box(b'stco', b'\0' * 4 + struct.pack('>II', 1, a_off))
            a_trak = box(b'trak', box(b'mdia', box(b'minf', box(b'stbl', a_stsd + a_stsz + a_stsc + a_stco))))
            v_stco = box(b'stco', b'\0' * 4 + struct.pack('>II', 1, v_off))
            v_saio = box(b'saio', b'\0' * 4 + struct.pack('>II', 1, aux_off))
            v_trak = box(b'trak', box(b'mdia', box(b'minf', box(b'stbl', v_stsd + v_stsz + v_stsc + v_stco + v_saiz + v_saio + v_senc))))
            return box(b'moov', a_trak + v_trak)

        dummy_moov = build_moov(0, 0, 0)
        aux_off = len(ftyp) + dummy_moov.index(v_senc) + 16
        a_off = len(ftyp) + len(dummy_moov) + 8
        v_off = a_off + len(audio_plain)
        real_moov = build_moov(a_off, v_off, aux_off)
        mp4_bytes = ftyp + real_moov + box(b'mdat', audio_plain + video_enc) + box(b'free', b'\0' * 9000)

        src = Path(self.tmp.name, 'multitrack_enc.mp4')
        dst = Path(self.tmp.name, 'multitrack_dec.mp4')
        src.write_bytes(mp4_bytes)
        hgtv._cenc_decrypt(str(src), str(dst), key)
        out = dst.read_bytes()
        self.assertTrue(hgtv._verify_mp4(str(dst)))
        self.assertEqual(out[a_off:a_off + len(audio_plain)], audio_plain)
        self.assertEqual(out[v_off:v_off + len(video_plain)], video_plain)


if __name__ == '__main__':
    unittest.main()
