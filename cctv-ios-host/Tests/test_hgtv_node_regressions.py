import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which('node')


def box(kind, payload):
    return struct.pack('>I4s', len(payload) + 8, kind) + payload


def encrypted_fixture(codec=b'hvc1'):
    key = '2b7e151628aed2a6abf7158809cf4f3c'
    iv = bytes.fromhex('f0f1f2f3f4f5f6f7')
    plain = b'fixture-video-frame-bytes'
    encrypted = bytes.fromhex('6a46c3c22fab02076f979950f4de2d70cec2f9df88a0195693')
    ftyp = box(b'ftyp', b'isom\0\0\x02\0isomiso2')
    # Leave the original level byte intact: this regression concerns box layout.
    config = bytearray(23)
    config[0], config[12] = 1, 186
    sinf = box(b'sinf', box(b'frma', codec) + box(b'schm', b'\0' * 4 + b'cenc' + b'\0' * 4))
    entry = box(b'encv', bytes(78) + box(b'hvcC', config) + sinf)
    stsd = box(b'stsd', b'\0' * 4 + struct.pack('>I', 1) + entry)
    stsz = box(b'stsz', b'\0' * 4 + struct.pack('>III', 0, 1, len(plain)))
    stsc = box(b'stsc', b'\0' * 4 + struct.pack('>IIII', 1, 1, 1, 1))
    saiz = box(b'saiz', b'\0' * 4 + b'\x08' + struct.pack('>I', 1))
    senc = box(b'senc', b'\0' * 4 + struct.pack('>I', 1) + iv)

    def moov(chunk, aux):
        stco = box(b'stco', b'\0' * 4 + struct.pack('>II', 1, chunk))
        saio = box(b'saio', b'\0' * 4 + struct.pack('>II', 1, aux))
        return box(b'moov', box(b'trak', box(b'mdia', box(b'minf', box(
            b'stbl', stsd + stsz + stsc + stco + saiz + saio + senc)))))

    header = moov(0, 0)
    chunk = len(ftyp) + len(header) + 8
    aux = len(ftyp) + header.index(senc) + 16
    data = ftyp + moov(chunk, aux) + box(b'mdat', encrypted)
    return data, key, plain, chunk, len(sinf)


@unittest.skipUnless(NODE, 'requires Node.js')
class HgtvNodeRegressions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.folder = Path(self.tmp.name)
        source = (ROOT / 'Examples/hgtv-node/hgtv.js').read_text()
        self.module = self.folder / 'hgtv-test.cjs'
        self.module.write_text(source.replace('module.exports = site;', '''
module.exports = {site, decryptCenc, verifyMp4, pickBest, qualityCandidates, fetchModel, signedRequest,
  registerDevice, ensureDeviceSession, branchOf,
  videoMetadata, episodesFrom, replaceSinf, decryptVideo,
  setModel: fn => fetchModel = fn, setHtml: fn => siteHtml = fn,
  setHttp: fn => httpText = fn, setDecrypt: fn => ensureDecrypted = fn};
'''))

    def tearDown(self):
        self.tmp.cleanup()

    def node(self, body, *args):
        result = subprocess.run([NODE, '-e', '''
const api = require(process.argv[1]);
const fs = require('node:fs');
const assert = require('node:assert/strict');
(async () => {''' + body + '''
})().catch(error => { console.error(error.stack); process.exit(1); });
''', str(self.module), *map(str, args)], cwd=self.folder,
            check=True, capture_output=True, text=True, timeout=15)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def decrypt(self, codec=b'hvc1'):
        data, key, plain, offset, sinf_size = encrypted_fixture(codec)
        src, dst = self.folder / 'enc.mp4', self.folder / 'clear.mp4'
        src.write_bytes(data)
        self.node('''api.decryptCenc(process.argv[2], process.argv[3],
          Buffer.from(process.argv[4], 'hex'));
          assert.equal(api.verifyMp4(process.argv[3]), true);''', src, dst, key)
        return data, dst, plain, offset, sinf_size

    def test_cenc_rewrite_preserves_box_sizes_original_codec_and_media(self):
        for codec in (b'hvc1', b'avc1'):
            with self.subTest(codec=codec):
                data, dst, plain, offset, sinf_size = self.decrypt(codec)
                clear = dst.read_bytes()
                original_sinf_type = data.index(b'sinf')
                self.assertEqual(len(clear), len(data))
                self.assertEqual(clear[offset:offset + len(plain)], plain)
                self.assertEqual(struct.unpack_from('>I', clear, original_sinf_type - 4)[0], sinf_size)
                self.assertEqual(clear[original_sinf_type:original_sinf_type + 4], b'free')
                self.assertEqual(clear[original_sinf_type + 4:original_sinf_type - 4 + sinf_size], bytes(sinf_size - 8))
                self.assertEqual(clear[data.index(b'encv'):data.index(b'encv') + 4], codec)
                self.assertEqual(clear[clear.index(b'hvcC') + 4 + 12], 186)

    def test_verifier_rejects_previously_cached_corrupt_sinf_and_encrypted_entries(self):
        data, dst, _, _, sinf_size = self.decrypt()
        clear = bytearray(dst.read_bytes())
        sinf_pos = data.index(b'sinf')
        clear[sinf_pos - 4:sinf_pos] = b'free'
        clear[sinf_pos:sinf_pos - 4 + sinf_size] = bytes(sinf_size - 4)
        corrupt = self.folder / 'old-cache.mp4'
        corrupt.write_bytes(clear)
        encrypted = self.folder / 'enc.mp4'
        self.node('''assert.equal(api.verifyMp4(process.argv[2]), false);
          assert.equal(api.verifyMp4(process.argv[3]), false);''', corrupt, encrypted)

    def test_bad_cache_is_downloaded_again_instead_of_reused(self):
        data, dst, _, _, sinf_size = self.decrypt()
        corrupt = bytearray(dst.read_bytes())
        pos = data.index(b'sinf')
        corrupt[pos - 4:pos] = b'free'
        corrupt[pos:pos - 4 + sinf_size] = bytes(sinf_size - 4)
        cache = self.folder / 'hgtv-js-cache'
        cache.mkdir()
        old = cache / '123_1080p.mp4'
        old.write_bytes(corrupt)
        self.node('''let downloads = 0;
          api.setModel(async () => ({video_list: {0: {definition: '1080p', main_url: 'https://media.invalid/full.mp4'}}}));
          api.setHttp(async () => { downloads++; return {status: 200, body: fs.readFileSync(process.argv[2])}; });
          const result = await api.decryptVideo('123', '1080p');
          assert.equal(downloads, 1); assert.equal(api.verifyMp4(result), true);
          assert.deepEqual(fs.readFileSync(result), fs.readFileSync(process.argv[2]));''', dst)

    def test_detail_uses_every_episode_from_matching_ssr_series(self):
        sid = '7701226234214108185'
        episodes = [str(7701227778389068824 + i) for i in range(300)]
        detail = {'series_id': sid, 'series_name': '完整目录', 'episode_cnt': 300,
                  'vid_list': episodes, 'series_cover': 'https://cover.invalid/image'}
        router = {'loaderData': {'detail_page': {'seriesDetail': detail,
                  'recommendations': {'vid_list': ['9999999999999999999']}}}}
        html = '<script>_ROUTER_DATA = ' + json.dumps(router) + ';</script>'
        html += '<a href="/player/9999999999999999999/8888888888888888888">推荐</a>'
        fixture = self.folder / 'detail.html'
        fixture.write_text(html)
        self.node('''const html = fs.readFileSync(process.argv[2], 'utf8');
          api.setHtml(async () => html);
          const result = (await api.site.detail(process.argv[3])).list[0];
          const eps = result.vod_play_url.split('#');
          assert.equal(eps.length, 300); assert.equal(result.catalog_complete, true);
          assert.equal(result.vod_play_from, '官网完整播放');
          assert.equal(eps[0].split('$')[1], process.argv[3] + '~' + process.argv[4]);
          assert.equal(eps.at(-1).split('$')[1], process.argv[3] + '~' + process.argv[5]);
          assert.equal(result.vod_name, '完整目录');''', fixture, sid, episodes[0], episodes[-1])

    def test_detail_link_fallback_requests_player_catalogue_first(self):
        self.node('''const sid = '1234567890123456789';
          const link = n => '<a href="/player/' + sid + '/' + (1234567890123456789n + BigInt(n)).toString() + '">集</a>';
          const requests = [];
          api.setHtml(async path => { requests.push(path); return path.startsWith('/detail') ? link(0) : link(0) + link(1) + link(2); });
          const result = (await api.site.detail(sid)).list[0];
          assert.equal(result.vod_play_url.split('#').length, 3);
          assert.deepEqual(requests, ['/detail?series_id=' + sid, '/player/' + sid]);''')

    def test_home_cover_device_register_and_current_video_model_route(self):
        self.node('''const sid='1234567890123456789';
          const episodes=['7701565033376910360','7701820244146261016','7701832903004556312'];
          const qualities=['360p','480p','540p','720p','1080p'];
          api.setHtml(async () => '<a href="/detail?series_id=' + sid + '">' +
            '<img class="empty_play" src="https://img.invalid/empty_play.png">' +
            '<img alt="poster" data-src="https://img.invalid/poster.jpg">' +
            '<span class="pc-title">测试封面</span></a>');
          const home=await api.site.home();
          assert.equal(home.list.length,1);
          assert.equal(home.list[0].vod_pic,'https://img.invalid/poster.jpg');

          const calls=[];
          let regCount=0;
          let playCount=0;
          api.setHttp(async (url, options) => {
            calls.push({url, options});
            const u=new URL(url);
            if(u.pathname.endsWith('/device_register/')){
              regCount++;
              const did=`770199887766550${regCount}`;
              const iid=`770199887766990${regCount}`;
              return {status:200,body:Buffer.from(JSON.stringify({
                device_id_str:did,install_id_str:iid,device_id:Number(did),install_id:Number(iid)
              }))};
            }
            playCount++;
            if(playCount===1)return {status:200,body:Buffer.alloc(0)};
            const vlist={};
            qualities.forEach((q, idx)=>{
              vlist['video_'+(idx+1)]={definition:q,main_url:'https://media.invalid/'+q+'.mp4',spade_a:'fixture'};
            });
            return {status:200,body:Buffer.from(JSON.stringify({
              code:0,data:{video_model:JSON.stringify({video_list:vlist})}
            }))};
          });

          for(const vid of episodes){
            const model=await api.fetchModel(vid);
            assert.ok(model && model.video_list);
            assert.deepEqual(api.qualityCandidates(model).map(c=>c.q), ['1080p','720p','540p','480p','360p']);
            assert.equal(api.pickBest(model).q,'1080p');
          }
          // Episode 1: register (#1) -> play (#1 empty) -> re-register (#2) -> play (#2 ok)
          // Episode 2 (middle) & Episode 3 (late): reuse registered device (#2) directly!
          assert.equal(regCount,2);
          assert.equal(playCount,4);
          const playCalls=calls.filter(c=>new URL(c.url).pathname==='/novel/player/video_model/v1/');
          assert.equal(playCalls.length,4);
          for(const call of playCalls){
            const u=new URL(call.url);
            assert.equal(u.hostname,'api5-normal-sinfonlineb.fqnovel.com');
            assert.equal(u.pathname,'/novel/player/video_model/v1/');
            assert.equal(u.searchParams.get('version_code'),'73532');
            assert.ok(u.searchParams.get('cdid'));
            assert.ok(u.searchParams.get('openudid'));
            assert.ok(u.searchParams.get('rom_version'));
            assert.ok(u.searchParams.get('key_register_ts'));
            assert.equal(u.searchParams.get('req_type'),'1');
            assert.equal(call.options.method,'POST');
            assert.ok(call.options.headers['x-gorgon']);
            assert.ok(call.options.headers['x-helios']);
            assert.ok(call.options.headers['x-ss-stub']);
            assert.notEqual(api.branchOf(call.url,call.options.body,Number(call.options.headers['x-khronos'])),1);
          }
          // Verify first failed attempt used device #1, and subsequent calls reused device #2 across episodes
          assert.equal(new URL(playCalls[0].url).searchParams.get('device_id'),'7701998877665501');
          assert.equal(new URL(playCalls[1].url).searchParams.get('device_id'),'7701998877665502');
          assert.equal(new URL(playCalls[2].url).searchParams.get('device_id'),'7701998877665502');
          assert.equal(new URL(playCalls[3].url).searchParams.get('device_id'),'7701998877665502');''')

    def test_play_lists_all_actual_qualities_and_rejects_missing_quality(self):
        self.node('''const rows = {};
          ['360p','480p','540p','720p','1080p'].forEach((q, i) => {
            rows[i] = {video_meta: i % 2 ? JSON.stringify({definition:q}) : "{'definition': '" + q + "', 'vtype': 'h265'}"};
          });
          rows[5] = {video_meta: "{'definition': '2160p', 'vtype': 'bytevc2'}"};
          api.setModel(async () => ({video_list: rows}));
          const result = await api.site.play('官网完整播放', '11~22');
          assert.equal(result.url, 'cenc://22?q=1080p'); assert.equal(result.preview, false);
          assert.deepEqual(result.alternates.map(q => q.name), ['1080p','720p','540p','480p','360p']);
          assert.equal(result.alternates.every(q => q.proxy && q.format === 'mp4'), true);
          assert.equal(api.pickBest({video_list:rows}, '1440p'), null);
          assert.equal((await api.site.play('红果1440p', '22')).url, '');
          assert.equal((await api.site.play('官网公开试看', '22')).url, '');
          const missing = await api.site.localProxy({url:'cenc://22?q=1440p'});
          assert.equal(missing[0], 502); assert.match(missing[2], /requested quality 1440p is unavailable/);''')

    def test_proxy_file_response_allows_complete_files_above_serialized_body_limit(self):
        _, dst, _, _, _ = self.decrypt()
        with dst.open('ab') as out:
            out.write(box(b'free', bytes(17 * 1024 * 1024)))
        self.node('''api.setDecrypt(async () => process.argv[2]);
          for (const method of ['GET','HEAD']) {
            const result = await api.site.localProxy({url:'cenc://22?q=1080p', method});
            assert.equal(result[0], 200); assert.equal(result[2].__cctvhostFileResponse, true);
            assert.equal(result[2].length, fs.statSync(process.argv[2]).size);
          }''', dst)



    def test_middle_and_late_episodes_end_to_end_spade_and_cenc_decryption(self):
        data, _, plain, offset, _ = self.decrypt()
        enc_fixture = self.folder / 'cdn-encrypted.mp4'
        enc_fixture.write_bytes(data)
        self.node("""const crypto = require('node:crypto');
          const encMedia = fs.readFileSync(process.argv[2]);
          const expectedPlain = Buffer.from(process.argv[3], 'hex');
          const sampleOffset = Number(process.argv[4]);
          const seed = Buffer.from('hongguo-seed-2026', 'utf8');
          const spadeConst = Buffer.from(
            '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524' +
            'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58', 'hex');
          const h1 = crypto.createHash('sha512').update(seed).digest();
          const h2 = crypto.createHash('sha512').update(Buffer.concat([h1, spadeConst])).digest();
          function encryptSpadeUrl(plainUrl) {
            const pt = Buffer.from(plainUrl, 'utf8');
            const pad = 16 - (pt.length % 16);
            const padded = Buffer.concat([pt, Buffer.alloc(pad, pad)]);
            const cipher = crypto.createCipheriv('aes-128-cbc', h2.subarray(0, 16), h2.subarray(16, 32));
            cipher.setAutoPadding(false);
            const ct = Buffer.concat([cipher.update(padded), cipher.final()]);
            return Buffer.concat([Buffer.from([0xa8, 0x00, 0x01, 0x00]), ct]).toString('base64');
          }
          const spadeA = 'nrMdy1OwG/xSsBv/YoMeyWSFHPxisiv/erAy4U6fA+BOmQ==';
          const qualities = ['360p', '480p', '540p', '720p', '1080p'];
          const episodes = ['7701820244146261016', '7701832903004556312'];
          let regCalls = 0;
          api.setHttp(async (url, opts) => {
            const u = new URL(url);
            if (u.pathname.endsWith('/device_register/')) {
              regCalls++;
              return {status: 200, body: Buffer.from(JSON.stringify({
                device_id_str: '7701998877665588', install_id_str: '7701998877669988'
              }))};
            }
            if (u.pathname === '/novel/player/video_model/v1/') {
              const reqBody = JSON.parse(opts.body.toString('utf8'));
              const vid = reqBody.video_id;
              const vlist = {};
              qualities.forEach((q, idx) => {
                vlist['video_' + (idx + 1)] = {
                  definition: q,
                  main_url: encryptSpadeUrl('https://v3-reading.qznovelvod.com/' + vid + '/' + q + '.mp4'),
                  spade_a: spadeA,
                  encrypt_info: {encrypt: true, spade_a: spadeA},
                  gear_des_key: '1:encrypt|2:h265_hvc1|4:' + q + '|5:normal',
                  video_meta: JSON.stringify({definition: q, vtype: 'h265'})
                };
              });
              return {status: 200, body: Buffer.from(JSON.stringify({
                code: 0,
                data: {key_seed: seed.toString('base64'), video_model: JSON.stringify({key_seed: seed.toString('base64'), video_list: vlist})}
              }))};
            }
            if (u.hostname === 'v3-reading.qznovelvod.com') {
              return {status: 200, body: encMedia};
            }
            throw Error('unexpected URL ' + url);
          });

          for (const vid of episodes) {
            const playInfo = await api.site.play('官网完整播放', '7701226234214108185~' + vid);
            assert.equal(playInfo.url, 'cenc://' + vid + '?q=1080p');
            assert.deepEqual(playInfo.alternates.map(a => a.name), ['1080p', '720p', '540p', '480p', '360p']);
            const proxyRes = await api.site.localProxy({url: playInfo.url, method: 'GET'});
            assert.equal(proxyRes[0], 200);
            assert.equal(proxyRes[2].__cctvhostFileResponse, true);
            assert.equal(api.verifyMp4(proxyRes[2].path), true);
            const clearBytes = fs.readFileSync(proxyRes[2].path);
            assert.deepEqual(clearBytes.subarray(sampleOffset, sampleOffset + expectedPlain.length), expectedPlain);
          }
          assert.equal(regCalls, 1);
        """, enc_fixture, plain.hex(), offset)


if __name__ == '__main__':
    unittest.main()
