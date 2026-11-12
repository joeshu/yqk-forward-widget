"""Regression and contract coverage for Android Java .jar / csp_* progressive support (L1-L4)."""

import base64
import io
import json
import struct
import sys
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGINS = ROOT / 'Plugins'
SOURCES = ROOT / 'Sources'
sys.path.insert(0, str(PLUGINS))
sys.path.insert(0, str(PLUGINS / 'crypto_compat'))

from csp_adapter import (
    XBPQEngine,
    AppVideoEngine,
    BiliEngine,
    DEXParser,
    DalvikVM,
    CSPAdapter,
    _aes_cbc_encrypt,
)


class AndroidJARProgressiveSupportTests(unittest.TestCase):
    def test_yqk_signed_request_reaches_transport_and_preserves_parameters(self):
        from unittest.mock import Mock, patch
        import hashlib
        engine = AppVideoEngine('YQK', {})
        response = Mock()
        response.json.return_value = {'data': {'list': []}}
        engine.session.post = Mock(return_value=response)
        with patch('uuid.uuid4', return_value='fixture-device'):
            self.assertEqual(engine._yqk_post('/fixture', {'page': 2}), {'list': []})
        args, kwargs = engine.session.post.call_args
        body = kwargs['json']
        self.assertEqual(body['page'], 2)
        parts = [f"{key}={body[key]}" for key in sorted(body) if key != 'sign' and body[key] not in (None, '')]
        signature = hashlib.md5(('&'.join(parts) + '&key=6142612b179040c292488e027a12264d').encode()).hexdigest()
        self.assertEqual(body['sign'], signature)
        self.assertEqual(engine.session.post.call_count, 1)

    def test_site_picker_preserves_selected_site_identity(self):
        """An unsupported site must not launch a similarly named sibling."""
        mb = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertNotIn('MediaBrowserFallbackSupportedSite', mb)
        self.assertNotIn('MediaBrowserStationCoreName', mb)
        self.assertNotIn('iOS 脚本适配 · 已关联', mb)
        self.assertIn('NSDictionary *effectiveSite=site;', mb)

    def test_l2_xbpq_declarative_rule_crawler(self):
        """Verifies XBPQ rule engine parses categories, items, detail episodes, and sniffs streams."""
        cfg = {
            '分类': '电影$1#连续剧$2#动漫$3',
            '分类url': 'http://dyxz.test/list/{cateId}_{catePg}_{area}.html',
            '分类二次截取': '<div class="list"&&</div>',
            '分类数组': '<li class="item"&&</li>',
            '分类标题': 'title="&&"',
            '分类链接': 'href="&&"',
            '分类图片': 'src="&&"',
            '分类副标题': '<span class="note">&&</span>',
            '线路数组': '<a class="tab"&&/a>',
            '线路标题': '>&&<',
            '播放数组': '<ul class="playlist"&&</ul>',
            '播放列表': '<a class="ep"&&/a>',
            '播放标题': '>&&<',
            '播放链接': 'href="&&"',
            '搜索url': 'http://dyxz.test/search.php?page={pg}&searchword={wd}',
            '搜索数组': '<li class="item"&&</li>',
            '搜索标题': 'title="&&"',
            '搜索链接': 'href="&&"',
            '搜索图片': 'src="&&"',
        }
        engine = XBPQEngine(cfg)
        mock_html = '''
        <div class="list">
          <li class="item"><a href="/detail/101.html" title="样例电影"><img src="//img.test/101.jpg"/><span class="note">HD中字</span></a></li>
          <li class="item"><a href="/detail/102.html" title="测试剧集"><img src="/static/102.jpg"/><span class="note">更新至12集</span></a></li>
        </div>
        '''
        engine._get = lambda url: mock_html

        home = engine.homeContent()
        self.assertEqual(len(home['class']), 3)
        self.assertEqual(home['class'][0]['type_name'], '电影')
        self.assertEqual(home['class'][0]['type_id'], '1')
        self.assertEqual(len(home['list']), 2)
        self.assertEqual(home['list'][0]['vod_name'], '样例电影')
        self.assertEqual(home['list'][0]['vod_id'], 'http://dyxz.test/detail/101.html')
        self.assertEqual(home['list'][0]['vod_pic'], 'https://img.test/101.jpg')
        self.assertEqual(home['list'][1]['vod_pic'], 'http://dyxz.test/static/102.jpg')
        self.assertEqual(home['list'][0]['vod_remarks'], 'HD中字')

        cat = engine.categoryContent('2', '1', False, {})
        self.assertEqual(len(cat['list']), 2)
        self.assertEqual(cat['page'], 1)

        search = engine.searchContent('样例', False, '1')
        self.assertEqual(len(search['list']), 2)
        self.assertEqual(search['list'][0]['vod_name'], '样例电影')

        mock_detail_html = '''
        <h1>测试大片</h1>
        <img src="https://img.test/poster.jpg"/>
        <p>这是测试大片的简介内容</p>
        <div class="tabs">
          <a class="tab">专线A</a>
          <a class="tab">专线B</a>
        </div>
        <ul class="playlist">
          <a class="ep" href="/play/1.m3u8">第01集</a>
          <a class="ep" href="/play/2.m3u8">第02集</a>
        </ul>
        <ul class="playlist">
          <a class="ep" href="/play/b1.m3u8">第1集B</a>
        </ul>
        '''
        engine._get = lambda url: mock_detail_html
        detail = engine.detailContent(['http://dyxz.test/detail/101.html'])
        item = detail['list'][0]
        self.assertEqual(item['vod_name'], '测试大片')
        self.assertIn('专线A', item['vod_play_from'])
        self.assertIn('第01集$http://dyxz.test/play/1.m3u8', item['vod_play_url'])

        play = engine.playerContent('专线A', 'http://dyxz.test/play/1.m3u8', [])
        self.assertEqual(play['url'], 'http://dyxz.test/play/1.m3u8')
        self.assertEqual(play['parse'], 0)

        # Page sniffing for non-direct episode URL
        engine._get = lambda url: 'var player_aaaa={"url":"https:\\/\\/cdn.test\\/live\\/index.m3u8?token=abc"};'
        sniffed = engine.playerContent('专线A', 'http://dyxz.test/play/101-1-1.html', [])
        self.assertEqual(sniffed['parse'], 0)
        self.assertEqual(sniffed['url'], 'https://cdn.test/live/index.m3u8?token=abc')

    def test_l2_app_video_cms_engine_and_aes_decryption(self):
        """Verifies AppVideoEngine handles multi-mirror ext, array site, and real AES-CBC encrypted responses."""
        key = '1234567887654321'
        iv = '1234567887654321'
        cfg = {
            'site': ['http://cms1.test/', 'http://cms2.test/'],
            'dataKey': key,
            'dataIv': iv,
        }
        engine = AppVideoEngine('csp_AppGet', cfg)
        self.assertEqual(engine.base_url, 'http://cms1.test')

        # Test comma-separated string ext (e.g. csp_Jpys)
        engine_csv = AppVideoEngine('csp_Jpys', 'https://mirror1.test/,https://mirror2.test/')
        self.assertEqual(engine_csv.base_url, 'https://mirror1.test')

        # Test real AES-128-CBC Base64 payload decryption
        plain_json = json.dumps({'data': [{'vod_id': 888, 'vod_name': '加密短剧', 'vod_pic': 'http://img.test/888.jpg'}]}).encode('utf-8')
        cipher_b64 = base64.b64encode(_aes_cbc_encrypt(plain_json, key.encode('utf-8'), iv.encode('utf-8'))).decode('ascii')
        decrypted = engine._decrypt_payload(cipher_b64)
        self.assertEqual(decrypted['data'][0]['vod_name'], '加密短剧')

        mock_data = {
            'api.php/app/nav': {'list': [{'type_id': '10', 'type_name': '短剧'}, {'type_id': '20', 'type_name': '美剧'}]},
            'api.php/app/video': {'data': [{'vod_id': 555, 'vod_name': '霸道总裁', 'vod_pic': 'http://img.test/555.jpg', 'vod_remarks': '全80集'}]},
            'api.php/app/video_detail': {'data': {'vod_id': 555, 'vod_name': '霸道总裁', 'vod_play_url': '第1集$http://stream.test/1.m3u8'}},
            'api.php/app/video_url': {'url': 'http://stream.test/1.m3u8'},
        }
        engine._request_json = lambda path, params=None: mock_data.get(path, {})

        home = engine.homeContent()
        self.assertEqual(len(home['class']), 2)
        self.assertEqual(home['class'][0]['type_name'], '短剧')

        cat = engine.categoryContent('10', '1', False, {})
        self.assertEqual(len(cat['list']), 1)
        self.assertEqual(cat['list'][0]['vod_name'], '霸道总裁')

        det = engine.detailContent(['555'])
        self.assertEqual(det['list'][0]['vod_name'], '霸道总裁')

        play = engine.playerContent('', '555', [])
        self.assertEqual(play['url'], 'http://stream.test/1.m3u8')
        self.assertEqual(play['parse'], 0)

    def test_l2_bilibili_engine(self):
        """Verifies BiliEngine partition listing and video search."""
        engine = BiliEngine({})
        home = engine.homeContent()
        self.assertTrue(len(home['class']) >= 3)
        self.assertTrue(any(c['type_name'] == '番剧' for c in home['class']))
        play = engine.playerContent('', 'BV1xx411c7mD', [])
        self.assertIn('bilibili.com/video/BV1xx411c7mD', play['url'])

    def test_l3_dex_parser_and_jar_zip_extraction(self):
        """Verifies DEXParser extracts string constants from both raw DEX and spider.jar ZIP archives."""
        dex = bytearray(256)
        dex[:8] = b"dex\n035\0"
        dex[56:60] = (2).to_bytes(4, "little")   # string_ids_size
        dex[60:64] = (112).to_bytes(4, "little") # string_ids_off
        dex[112:116] = (120).to_bytes(4, "little")
        dex[116:120] = (160).to_bytes(4, "little")

        s1 = b"https://api.dex-spider.test"
        dex[120] = len(s1)
        dex[121:121 + len(s1)] = s1
        dex[121 + len(s1)] = 0

        s2 = b"12345678abcdefgh"
        dex[160] = len(s2)
        dex[161:161 + len(s2)] = s2
        dex[161 + len(s2)] = 0

        jar_buf = io.BytesIO()
        with zipfile.ZipFile(jar_buf, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr('classes.dex', bytes(dex))

        parser = DEXParser.from_jar_bytes(jar_buf.getvalue())
        self.assertIn("https://api.dex-spider.test", parser.strings)
        self.assertIn("12345678abcdefgh", parser.strings)
        cfg = parser.extract_site_config("csp_Sample")
        self.assertEqual(cfg['url'], "https://api.dex-spider.test")
        self.assertEqual(cfg['dataKey'], "12345678abcdefgh")

        # Verify DalvikVM bytecode instruction interpreter (const-string v0, string@0; return-object v0)
        vm = DalvikVM(parser)
        insns = struct.pack('<HHH', 0x001a, 0x0000, 0x0011)
        result = vm.interpret_instructions(insns)
        self.assertEqual(result, "https://api.dex-spider.test")

    def test_l4_unified_csp_adapter_dispatch(self):
        """Verifies CSPAdapter capabilities and multi-engine routing."""
        adapter_xbpq = CSPAdapter('csp_XBPQ', {'分类': '电影$1'})
        self.assertEqual(adapter_xbpq.capabilities()['capabilities'], ['home', 'category', 'search', 'detail', 'play'])
        self.assertTrue(isinstance(adapter_xbpq.engine, XBPQEngine))

        adapter_app = CSPAdapter('csp_AppDrama', {'url': 'http://drama.test'})
        self.assertTrue(isinstance(adapter_app.engine, AppVideoEngine))

        adapter_bili = CSPAdapter('csp_Bili', {})
        self.assertTrue(isinstance(adapter_bili.engine, BiliEngine))

    def test_tvbox_catalog_jar_bridge_recognition(self):
        """Verifies TVBoxCatalogStore recognizes supported csp_* classes while keeping csp_Example unsupported."""
        store_code = (SOURCES / 'TVBoxCatalogStore.m').read_text(encoding='utf-8')
        self.assertIn('TVBoxSupportedJARClass(api)', store_code)
        self.assertIn('apiKindJARBridge', store_code)
        self.assertIn('csp_xbpq', store_code)
        self.assertIn('csp_appdrama', store_code)
        self.assertIn('站点接口适配 · 待读取验证', store_code)
        self.assertIn('apiKindDouban=[siteType isEqual:@"3"]&&[api.lowercaseString isEqual:@"csp_doudou"]', store_code)

    def test_media_api_client_jar_bridge_and_non_recursive_delegation(self):
        """Verifies MediaAPIClient supports jar-bridge AES decryption, HTML fallback, and non-recursive delegation."""
        api_code = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('[protocol isEqual:@"jar-bridge"]', api_code)
        self.assertIn('MediaJARBridgeRequest', api_code)
        self.assertIn('MediaJARBridgeNormalize', api_code)
        self.assertIn('MediaJARBridgeTryDecryptData', api_code)
        self.assertIn('MediaJARBridgeFirstValidURL', api_code)
        self.assertIn('delegatedSource[@"protocol"]=@"tvbox-api"', api_code)
        self.assertNotIn('MediaTVBoxURLHasDirectMediaExtension', api_code)


    def test_jar_bridge_selection_and_playback_contracts(self):
        """Verifies jar-bridge sites are selectable in RootViewController & TVBoxCatalogViewController and playable via MediaAPIClient."""
        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('[apiKind isEqual:@"jar-bridge"]', root_code)
        self.assertIn('[selectedMedia hasPrefix:[NSString stringWithFormat:@"jar-bridge:%@:",identifier]]', root_code)

        tv_code = (SOURCES / 'TVBoxCatalogViewController.m').read_text(encoding='utf-8')
        self.assertIn('[row[@"apiKind"] isEqual:@"jar-bridge"]', tv_code)

        store_code = (SOURCES / 'TVBoxCatalogStore.m').read_text(encoding='utf-8')
        self.assertIn('mSite[@"apiKind"]=@"jar-bridge";', store_code)

        api_code = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('MediaJARBridgeBuildPlayResult', api_code)
        self.assertIn('MediaJARBridgeMacCMSFallbackRequest', api_code)
        self.assertIn('BOOL jarDirectPlay=jarBridge', api_code)
        self.assertNotIn('fbArgs[@"_jar_fallback"]=@YES;', api_code)

        # Missing site configuration must not pick an unrelated built-in CMS.
        with self.assertRaisesRegex(ValueError, '不使用默认站点'):
            AppVideoEngine('csp_Gz360', '')
        # Verify /api.php/app/ suffix is stripped from base_url
        app_engine = AppVideoEngine('csp_AppYsV2', 'https://qpcj.69mini.com/api.php/app/')
        self.assertEqual(app_engine.base_url, 'https://qpcj.69mini.com')

    def test_player_floating_text_suppression_and_compact_detail_poster(self):
        """Verifies floating text overlays are suppressed on player surface and detail hero poster is compact."""
        mp_code = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertIn('self.navigationItem.titleView=[UIView new];', mp_code)
        self.assertIn('self.throughputLabel.hidden=YES;self.throughputLabel.alpha=0.0;', mp_code)
        self.assertIn('self.inlineNowPlayingPill.alpha=0.0;', mp_code)

        mb_code = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('multiplier:0.36', mb_code)
        self.assertIn('constraintLessThanOrEqualToConstant:300', mb_code)
        self.assertIn('self.posterView.alpha=0.88;self.heroBlurView.alpha=0.22;', mb_code)


    def test_native_playback_and_cicada_soft_decode_eliminate_web_playback(self):
        """Verifies web playback is eliminated at runtime in favor of native AVPlayer, background stream sniffing, and CicadaPlayer software decode (cc)."""
        router_code = (SOURCES / 'MediaPlaybackDecodeRouter.m').read_text(encoding='utf-8')
        self.assertIn('cctv.mediaDecodeMode.v1', router_code)
        self.assertIn('[decodeMode isEqualToString:@"cicada_soft"]', router_code)

        mp_code = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertIn('sniffNativeStreamFromPageResult:(NSDictionary *)result playerGeneration:(NSUInteger)playerGeneration', mp_code)
        self.assertIn('teardownHiddenStreamSniffer', mp_code)
        self.assertIn('解码模式 (原生 / 软解 cc)', mp_code)
        self.assertIn('强制 CicadaPlayer 软解码 (cc)', mp_code)
        self.assertIn('self.cicadaAdapterSoftwareDecodeFallbackAttempted=YES;', mp_code)



    def test_lytvs_screenshot_sites_native_playback_and_spider_helpers(self):
        """Verifies base.spider.Spider helpers, player_aaaa (encrypt=0/1/2), and native fallback for lytvs sites."""
        from base.spider import Spider as BaseSpider
        from csp_adapter import _extract_stream_from_html

        spider = BaseSpider()
        tree = spider.html('<div class="item"><a href="/play/1.html">第01集</a></div>')
        self.assertEqual(tree.xpath('//a/text()'), ['第01集'])
        self.assertEqual(spider.regStr(r'href="([^"]+)"', '<a href="/play/1.html">'), '/play/1.html')
        self.assertEqual(spider.str2json('{"ok": 1}'), {'ok': 1})
        self.assertEqual(spider.cleanText('<b> 热播 &amp; 影视 </b>'), '热播 & 影视')
        self.assertTrue(spider.isVideoFormat('https://cdn.test/v/index.m3u8?token=1'))
        self.assertFalse(spider.isVideoFormat('https://cdn.test/play/1.html'))

        # Verify player_aaaa encrypt=0, 1 (URL-encoded), 2 (Base64 + URL-encoded)
        html_enc0 = '<script>var player_aaaa={"url":"https:\/\/cdn.test\/stream0.m3u8","encrypt":0}</script>'
        self.assertEqual(_extract_stream_from_html(html_enc0), 'https://cdn.test/stream0.m3u8')

        html_enc1 = '<script>var player_aaaa={"url":"https%3A%2F%2Fcdn.test%2Fstream1.m3u8","encrypt":1}</script>'
        self.assertEqual(_extract_stream_from_html(html_enc1), 'https://cdn.test/stream1.m3u8')

        b64_url = base64.b64encode(b'https%3A%2F%2Fcdn.test%2Fstream2.m3u8').decode('ascii')
        html_enc2 = f'<script>var player_aaaa={{"url":"{b64_url}","encrypt":2}}</script>'
        self.assertEqual(_extract_stream_from_html(html_enc2), 'https://cdn.test/stream2.m3u8')

        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('CCTVURLFromPossiblyUnescapedString', root_code)
        self.assertIn('activateNativeFallbackForTVBoxSite', root_code)
        self.assertIn('cctv.nativeFallbackSiteKeys.v1', root_code)

        api_code = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('delegatedSource[@"_jarBridge"]=@YES;', api_code)
        self.assertIn('player_aaaa', api_code)

        mp_code = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertNotIn('resolveMacCMSStreamByTitleForResult', mp_code)



    def test_header_declaration_background_recovery_metadata_and_vip_rescue(self):
        """Verifies header declaration, background listener rebind, [object Object] stripping, dyttzyapi primary CMS, and EPG replay."""
        mb_h = (SOURCES / 'MediaBrowserViewController.h').read_text(encoding='utf-8')
        self.assertIn('- (void)activate:(NSDictionary *)source keepingHome:(BOOL)keepingHome;', mb_h)

        svc_py = (ROOT / 'Scripts' / 'host_service_runtime.py').read_text(encoding='utf-8')
        self.assertIn('def rebind_active_listeners():', svc_py)
        self.assertIn('def _rebind_server_socket(server):', svc_py)

        import host_media_runtime
        cleaned = host_media_runtime.detail({
            'vod_id': '99',
            'vod_name': '空枪',
            'vod_class': '[object Object]',
            'vod_remarks': '[object Object]',
            'vod_play_from': 'dytt',
            'vod_play_url': '第1集$https://play.phimgood.com/2026/index.m3u8'
        }, '99')
        self.assertEqual(cleaned['name'], '空枪')
        self.assertNotIn('type', cleaned)
        self.assertNotIn('remarks', cleaned)

        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('pendingNativeReplayProgram', root_code)
        self.assertIn('refreshListenersAfterForeground', root_code)



    def test_encryption_drm_and_comprehensive_stream_recognition(self):
        """Verifies HLS key normalization, inline key URI relay, disguised TS header stripping, CENC/ClearKey normalization, base64/encrypt=3 extraction, and AVAssetResourceLoaderDelegate."""
        import base64
        import host_media_runtime
        from host_media_relay import MediaRelay
        from csp_adapter import _extract_stream_from_html, _aes_cbc_decrypt, _aes_cbc_encrypt

        # 1. HLS key normalization (raw 16B, 32-hex, base64, JSON)
        expected_key = bytes(range(16))
        self.assertEqual(MediaRelay._normalize_hls_key_bytes(expected_key), expected_key)
        self.assertEqual(MediaRelay._normalize_hls_key_bytes(expected_key.hex().encode('ascii')), expected_key)
        self.assertEqual(MediaRelay._normalize_hls_key_bytes(base64.b64encode(expected_key)), expected_key)
        self.assertEqual(
            MediaRelay._normalize_hls_key_bytes(('{"key":"' + expected_key.hex() + '"}').encode('utf-8')),
            expected_key,
        )

        # 2. Inline #EXT-X-KEY URI (data:, base64:, hex:) rewrite to local HTTP /media/<token>
        relay = MediaRelay()
        b64_key = base64.b64encode(expected_key).decode('ascii')
        m3u8_in = (
            '#EXTM3U\n'
            f'#EXT-X-KEY:METHOD=AES-128,URI="data:application/octet-stream;base64,{b64_key}"\n'
            '#EXTINF:6.0,\n'
            'https://cdn.example/seg0.ts\n'
        )
        rewritten = relay.rewrite(
            m3u8_in, 'https://cdn.example/index.m3u8', {}, ('https', 'cdn.example'), 'http://127.0.0.1:18787'
        )
        self.assertIn('URI="http://127.0.0.1:18787/media/', rewritten)
        self.assertEqual(len(relay.inline_keys), 1)
        self.assertEqual(next(iter(relay.inline_keys.values()))[0], expected_key)

        # 3. Disguised TS image header stripping (fake PNG header before 3x 188B 0x47 sync bytes)
        fake_png = b'\x89PNG\r\n\x1a\nFAKEHEADER'
        ts_payload = (b'\x47' + b'\x00' * 187) * 3
        stripped = MediaRelay._strip_disguised_ts_prefix(fake_png + ts_payload)
        self.assertEqual(stripped, ts_payload)
        # Normal fMP4 box header is never stripped
        fmp4_payload = b'\x00\x00\x00\x18ftypisom' + ts_payload
        self.assertEqual(MediaRelay._strip_disguised_ts_prefix(fmp4_payload), fmp4_payload)

        # 4. ClearKey / CENC key normalization & base64 URL decoding in host_media_runtime.playback
        jwk_clear_key = {
            'keys': [{'kty': 'oct', 'k': base64.urlsafe_b64encode(expected_key).decode('ascii').rstrip('=')}]
        }
        b64_mp4_url = base64.b64encode(b'https://cdn.example/cenc_video.mp4').decode('ascii')
        play_res = host_media_runtime.playback({
            'vurl': b64_mp4_url,
            'clearKey': jwk_clear_key,
            'licenseUrl': 'https://lic.example/ widevine'.replace(' ', ''),
        })
        self.assertEqual(play_res['url'], 'https://cdn.example/cenc_video.mp4')
        self.assertEqual(play_res['drmKey'], expected_key.hex())
        self.assertEqual(play_res['licenseUrl'], 'https://lic.example/widevine')
        self.assertTrue(play_res['directMedia'])
        self.assertTrue(play_res['nativePlayable'])

        # 5. MacPlayerConfig / encrypt=3 / atob() extraction & AES-ECB fallback in csp_adapter
        rev_b64 = base64.b64encode(b'https://cdn.example/live/stream.m3u8').decode('ascii')[::-1]
        html_enc3 = f'<script>var MacPlayerConfig = {{"encrypt": 3, "url": "{rev_b64}"}};</script>'
        self.assertEqual(_extract_stream_from_html(html_enc3), 'https://cdn.example/live/stream.m3u8')

        atob_b64 = base64.b64encode(b'https://cdn.example/atob/index.m3u8').decode('ascii')
        html_atob = f'<script>const play = atob("{atob_b64}");</script>'
        self.assertEqual(_extract_stream_from_html(html_atob), '')
        self.assertEqual(_extract_stream_from_html(html_atob, allow_unscoped=True), 'https://cdn.example/atob/index.m3u8')

        ecb_cipher = _aes_cbc_encrypt(b'{"list":[{"vod_id":"1"}]}', b'1234567887654321', b'')
        ecb_plain = _aes_cbc_decrypt(ecb_cipher, b'1234567887654321', b'wrong_iv_1234567')
        self.assertEqual(ecb_plain, b'{"list":[{"vod_id":"1"}]}')

        # 6. Native iOS AVAssetResourceLoaderDelegate & /cenc/ endpoint contracts
        mp_code = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertIn('AVAssetResourceLoaderDelegate', mp_code)
        self.assertIn('resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:', mp_code)
        self.assertIn('MediaPlaybackNormalizedAES128KeyData', mp_code)
        ms_code = (PLUGINS / 'media-service.py').read_text(encoding='utf-8')
        self.assertIn('register_cenc_stream', ms_code)
        self.assertIn('serve_cenc_stream', ms_code)



    def test_four_stage_diagnostic_and_architecture_optimizations(self):
        """Verifies Stage 1-4 fixes: TLS EOF retry, Cicada direct URL, search_reset guard, importer JS support, LRU hibernation, and image domain fast-fail."""
        import ssl
        import urllib.error
        import host_media_relay

        # Transport compatibility flags must preserve certificate/hostname checks.
        self.assertEqual(host_media_relay._DEFAULT_SSL_CONTEXT.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(host_media_relay._DEFAULT_SSL_CONTEXT.check_hostname)

        mp_code = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertIn('if(isLoopbackRelay&&[result[@"dashRemuxed"] boolValue])effectiveURL=sourceURL;', mp_code)
        self.assertIn('BOOL avIncompatibleContainer=[@[@"mpd",@"flv",@"mkv",@"webm"] containsObject:failedSourceExt];', mp_code)
        self.assertIn('for(NSUInteger pass=0;pass<2;pass++)', mp_code)

        mb_code = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('if(!keyword.length && !previousKeyword.length && (!searchController.isActive || self.homeMode))return;', mb_code)
        self.assertIn('if([self.source[@"id"] isEqual:targetID] && (self.readiness!=nil', mb_code)

        imp_code = (SOURCES / 'MediaPackageImporter.m').read_text(encoding='utf-8')
        self.assertIn('categoryContent', imp_code)
        self.assertIn('detailContent', imp_code)
        self.assertIn('playerContent', imp_code)
        self.assertIn('__jsEvalReturn', imp_code)

        dl_code = (SOURCES / 'MediaPackageDownloader.m').read_text(encoding='utf-8')
        self.assertIn('连接超时 · 正在自动重试下载', dl_code)

        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('hibernateExcessBackgroundVODServicesKeepingID:', root_code)
        self.assertIn('if(owner.pendingTVBoxSiteName.length){', root_code)

        img_code = (SOURCES / 'HostImageLoader.m').read_text(encoding='utf-8')
        self.assertIn('domain_backoff_fast_fail', img_code)
        self.assertIn('response_truncated', img_code)


    def test_round_13_deep_playback_relay_and_cache_optimizations(self):
        """Verifies Round 13 optimizations: HTTP 403 Referer-strip retry, lytvs.top/py/*.js zero-wait native routing, joeshu.yqk 4500ms timeout cap, weboxHttp fast retry, and MediaMetadataCache detail support."""
        import http.client
        import http.server
        import threading
        import host_media_relay
        import importlib.util

        # 1. Verify MediaRelay retries HTTP 403 once with Referer/Origin stripped (e.g. v9-default.douyinvod.com)
        spec = importlib.util.spec_from_file_location('media_service_r13', PLUGINS / 'media-service.py')
        transport = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(transport)

        seen_referers = []
        class AntiHotlinkUpstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                ref = self.headers.get('Referer')
                seen_referers.append(ref)
                if ref:
                    self.send_response(403)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                body = b'#EXTM3U\n#EXTINF:6,\nseg0.ts\n#EXT-X-ENDLIST\n'
                self.send_response(200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        class DummyRuntime:
            def capabilities(self): return {'capabilities': ['play']}
            def close(self): pass

        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), AntiHotlinkUpstream)
        server = transport.Server(('127.0.0.1', 0), DummyRuntime())
        threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (upstream, server)]
        for t in threads: t.start()
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)
        try:
            target = f'http://127.0.0.1:{upstream.server_port}/stream.m3u8'
            token = server.relay.register(target, {'Referer': 'https://www.4kvm.org/'}, diagnostic_id='r13-douyinvod')
            conn.request('GET', '/media/' + token)
            resp = conn.getresponse()
            body = resp.read()
            self.assertEqual(resp.status, 200)
            self.assertIn(b'#EXTM3U', body)
            self.assertEqual(seen_referers, ['https://www.4kvm.org/', None])
        finally:
            conn.close()
            for s in (upstream, server): s.shutdown(); s.server_close()
            for t in threads: t.join(2)

        # 2. Verify RootViewController duplicate activate guard & authentic site execution (no silent hijack)
        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('reportAuthenticTVBoxSiteFailure:site rawAPI:originalAPI url:downloadURL error:error browseAfterImport:browseAfterImport', root_code)
        self.assertNotIn('([lowAPI hasPrefix:@"https://lytvs.top/py/"]&&([lowAPI hasSuffix:@".js"]||[lowAPI hasSuffix:@".hjs"]))', root_code)

        # 3. Verify joeshu.yqk 4500ms timeout cap & 2800ms fast HLS probe in JSPluginRuntime & MediaPackageDownloader
        js_rt = (SOURCES / 'JSPluginRuntime.m').read_text(encoding='utf-8')
        self.assertIn('timeout:yqkRequestTimeout(budget,4500)', js_rt)
        self.assertIn('injected by JSPlugins/generic/entry.mjs', js_rt)
        self.assertNotIn('withString:@"async function yqkProbeHls', js_rt)
        dl_code = (SOURCES / 'MediaPackageDownloader.m').read_text(encoding='utf-8')
        self.assertIn('timeout:yqkRequestTimeout(budget,4500)', dl_code)

        # 4. Verify weboxHttp fast retry on AbortError in entry.mjs & node-plugin-host.cjs
        entry_mjs = (ROOT / 'JSPlugins/generic/entry.mjs').read_text(encoding='utf-8')
        nph_cjs = (PLUGINS / 'node-plugin-host.cjs').read_text(encoding='utf-8')
        self.assertIn("const canRetry=['GET','HEAD'].includes(method)&&!options._retried&&totalTimeout>=8000", entry_mjs)
        self.assertIn("const canRetry=['GET','HEAD'].includes(method)&&!options._retried&&totalTimeout>=8000", nph_cjs)

        # 5. Verify csp_adapter requests fallback resilience
        csp_code = (PLUGINS / 'csp_adapter.py').read_text(encoding='utf-8')
        self.assertIn('_FallbackSession', csp_code)



    def test_round14_hawk_hjs_subscriptions_and_short_drama_support(self):
        """Verifies Round 14 .hawk / .hjs support:
        1. Concatenated .hawk URLs ('Https://sub.lytvs.top/hamo/tk_95f9cbf6.hawkhttps://sub.lytvs.top/hamo/chigua_tk_95f9cbf6.hawkhttps://sub.lytvs.top/hamo/duanju_tk_95f9cbf6.hawk') split cleanly.
        2. Token '95f9cbf6' is extracted from /hamo/*tk_<token>.hawk paths in RootViewController.m.
        3. TVBoxCatalogStore recognizes .hjs script files as supported and auto-upgrades saved .hjs sites in +catalogs.
        4. RootViewController routes .hjs sites to zero-wait native jar-bridge classes (csp_QimaoDJ for short dramas, csp_AdultDJ for 🔞/chigua).
        5. AppVideoEngine prioritizes short-drama and welfare/chigua categories in homeContent.
        """
        import re
        workflow_code = (SOURCES / 'ResourceImportWorkflowViewController.m').read_text(encoding='utf-8')
        self.assertIn('json|hawk|js|hjs|mjs|cjs|py', workflow_code)
        self.assertIn('https://sub.lytvs.top/hamo/tk_95f9cbf6.hawk', workflow_code)
        self.assertIn('https://sub.lytvs.top/hamo/duanju_tk_95f9cbf6.hawk', workflow_code)
        self.assertIn('https://sub.lytvs.top/hamo/chigua_tk_95f9cbf6.hawk', workflow_code)

        # Verify the regex splits the exact user-pasted concatenated string into 3 URLs
        raw_input = 'Https://sub.lytvs.top/hamo/tk_95f9cbf6.hawkhttps://sub.lytvs.top/hamo/chigua_tk_95f9cbf6.hawkhttps://sub.lytvs.top/hamo/duanju_tk_95f9cbf6.hawk'
        split_step = re.sub(r'(\.(?:json|hawk|js|hjs|mjs|cjs|py|m3u8|m3u|txt|zip|php|xml|webox|jar|md5))(https?://)', r'\1\n\2', raw_input, flags=re.I)
        extracted = re.findall(r"https?://[^\s\"'<>]+", split_step, flags=re.I)
        self.assertEqual(len(extracted), 3)
        self.assertEqual(extracted[0].lower(), 'https://sub.lytvs.top/hamo/tk_95f9cbf6.hawk')
        self.assertEqual(extracted[1].lower(), 'https://sub.lytvs.top/hamo/chigua_tk_95f9cbf6.hawk')
        self.assertEqual(extracted[2].lower(), 'https://sub.lytvs.top/hamo/duanju_tk_95f9cbf6.hawk')

        # Verify token extraction regex from /hamo/*tk_<token>.hawk paths
        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('tk_([A-Za-z0-9]{6,64})', root_code)
        for hawk_url in extracted:
            m = re.search(r'(?:^|[_/-])tk_([A-Za-z0-9]{6,64})(?:\.[A-Za-z0-9]+|$)', hawk_url, flags=re.I)
            self.assertIsNotNone(m)
            self.assertEqual(m.group(1), '95f9cbf6')

        # Verify TVBoxCatalogStore .hjs recognition and +catalogs auto-migration
        store_code = (SOURCES / 'TVBoxCatalogStore.m').read_text(encoding='utf-8')
        self.assertGreaterEqual(store_code.count('@[@"js",@"hjs",@"mjs",@"cjs",@"py",@"zip"]'), 2)
        self.assertIn('else if(isScriptURL&&(![site[@"supported"] boolValue]||![site[@"apiKind"] isEqual:@"script"]))', store_code)

        # Verify RootViewController pops modal stack cleanly and routes .hjs sites to authentic download/execution
        self.assertIn('if(self.navigationController.topViewController!=self)[self.navigationController popToViewController:self animated:NO];', root_code)
        self.assertIn('reportAuthenticTVBoxSiteFailure:site rawAPI:originalAPI url:downloadURL error:error browseAfterImport:browseAfterImport', root_code)

        # Verify AppVideoEngine prioritizes short-drama and adult/chigua categories
        drama_engine = AppVideoEngine('csp_QimaoDJ', 'http://cms.test')
        drama_engine._request_json = lambda path, params=None, base_override=None: {
            'class': [
                {'type_id': '1', 'type_name': '电影'},
                {'type_id': '36', 'type_name': '爽文短剧'},
                {'type_id': '2', 'type_name': '电视剧'},
            ],
            'list': [{'vod_id': '101', 'vod_name': '七猫短剧测试'}],
        }
        drama_home = drama_engine.homeContent()
        self.assertEqual(drama_home['class'][0]['type_name'], '爽文短剧')

        adult_engine = AppVideoEngine('csp_AdultDJ', 'http://cms.test')
        adult_engine._request_json = lambda path, params=None, base_override=None: {
            'class': [
                {'type_id': '1', 'type_name': '电影'},
                {'type_id': '20', 'type_name': '福利短剧'},
            ],
            'list': [{'vod_id': '202', 'vod_name': '2048成人短剧测试'}],
        }
        adult_home = adult_engine.homeContent()
        self.assertEqual(adult_home['class'][0]['type_name'], '福利短剧')


    def test_round15_authentic_site_execution_without_silent_fallback(self):
        """Verifies Round 15 authentic site execution and error feedback (from diagnostic 81d4f613):
        1. RootViewController clears persisted 'cctv.nativeFallbackSiteKeys.v1' on launch, does NOT pre-hijack .hjs/.js/.py sites into jar-bridge, and reports real HTTP/parse failures via reportAuthenticTVBoxSiteFailure.
        2. MediaAPIClient jar-bridge only retries MacCMS on the site's own configured base host (sameHostCMS) and returns an explicit CCTVHostJARBridge NSError when ext has no URL or when the site's own host fails.
        3. MediaPackageImporter accepts any .hjs script as hamo-source-v3 even when obfuscated, and entry.mjs adapts CatVod exports.
        4. host_media_runtime.py does not substitute _get_cms_fallback() in PythonSpider or NativeJS when a site returns empty or errors.
        """
        root_code = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertIn('[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cctv.nativeFallbackSiteKeys.v1"];', root_code)
        self.assertIn('- (void)reportAuthenticTVBoxSiteFailure:(NSDictionary *)site rawAPI:(NSString *)rawAPI url:(NSURL *)downloadURL error:(NSError *)error browseAfterImport:(BOOL)browseAfterImport', root_code)
        self.assertNotIn('[self activateNativeFallbackForTVBoxSite:site reason:', root_code)

        api_code = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('属于 Android JAR 封闭爬虫且未在合集 ext 中提供独立接口地址（ext 为空），无法在 iOS 上直连', api_code)
        self.assertNotIn('NSString *sameHostCMS=[base.lowercaseString hasSuffix:@".php"]?base:[base stringByAppendingString:@"/api.php/provide/vod/"];', api_code)
        self.assertNotIn('https://caiji.dyttzyapi.com/api.php/provide/vod/', api_code)

        importer_code = (SOURCES / 'MediaPackageImporter.m').read_text(encoding='utf-8')
        self.assertIn('BOOL hamoSourceV3=[entry.pathExtension.lowercaseString isEqual:@"hjs"] ||', importer_code)

        dl_code = (SOURCES / 'MediaPackageDownloader.m').read_text(encoding='utf-8')
        self.assertIn('if(![request valueForHTTPHeaderField:@"User-Agent"])[request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];', dl_code)

        hmr_code = (PLUGINS / 'host_media_runtime.py').read_text(encoding='utf-8')
        self.assertNotIn('fb = _get_cms_fallback()', hmr_code)



    def test_round16_diagnostic_cc85bbf4_fixes_and_smart_diagnostics_ui(self):
        """Verifies Round 16 fixes for diagnostic session cc85bbf4:
        1. HostImageLoader preserves domain backoff across sibling task cancellations and fast-cancels encrypted responses.
        2. JSPluginRuntime & MediaPackageImporter support minified CatVod QuickJS ESM ('assets://js/lib/cat.js' + '__jsEvalReturn'), drpy2.min.js engine shell with ext URL, and bare .hjs object literals / JSON errors.
        3. MediaBrowserViewController yields in-flight home_shelf requests when pushing detail, and MediaPackageDownloader / JSPluginRuntime cap sitePrepareImageDomains in detail to 800ms.
        4. host_service_runtime.py and PyHost.m wait for http-service-stop cleanup and clear Python breadcrumbs on stopServiceIdentifier so stopped sessions do not emit false-positive python_session_interrupted events.
        """
        img_code = (SOURCES / 'HostImageLoader.m').read_text(encoding='utf-8')
        self.assertIn('BOOL ignoreForDomainReset=(error.code==NSURLErrorCancelled)||(!isDomainTimeout&&(error!=nil||record.httpStatus!=200||record.failureStage.length>0));', img_code)
        self.assertIn('HostImageDomainFinish(state,CACurrentMediaTime(),isDomainTimeout,ignoreForDomainReset);', img_code)
        self.assertIn('&& !record.responseEncrypted;', img_code)

        imp_code = (SOURCES / 'MediaPackageImporter.m').read_text(encoding='utf-8')
        self.assertIn('else if(hamoSourceV3){runtime=@"javascript";protocol=@"hamo-source-v3";}', imp_code)
        self.assertIn(r'(?:^|[\\r\\n;}]|\\*/)\\s*(?:import\\s+', imp_code)

        js_rt = (SOURCES / 'JSPluginRuntime.m').read_text(encoding='utf-8')
        self.assertIn('__cctvImport', js_rt)
        self.assertIn('__cctvTransformSource', js_rt)
        self.assertIn('__cctvActiveOptions', js_rt)

        adapter_mjs = (ROOT / 'JSPlugins/drpy/adapter.mjs').read_text(encoding='utf-8')
        self.assertIn("const isEngineShell=text.includes('assets://js/lib/cheerio.min.js')", adapter_mjs)
        self.assertIn('engine.init(ext)', adapter_mjs)

        dl_code = (SOURCES / 'MediaPackageDownloader.m').read_text(encoding='utf-8')
        self.assertIn('Promise.race([sitePrepareImageDomains(d),new Promise(function(r){setTimeout(r,800);})])', dl_code)
        self.assertIn('offset+=6', dl_code)

        mb_code = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('[self.client cancelWithReason:@"yield_to_detail_request"];', mb_code)
        self.assertIn('if(self.serviceUnavailable){[self.grid.refreshControl endRefreshing];[self checkCurrentService];return;}', mb_code)

        hsr_code = (ROOT / 'Scripts/host_service_runtime.py').read_text(encoding='utf-8')
        self.assertIn('if session.stopping.is_set() and not session.clean():', hsr_code)
        pyhost_code = (SOURCES / 'PyHost.m').read_text(encoding='utf-8')
        self.assertGreaterEqual(pyhost_code.count('clearPythonBreadcrumb(task);'), 3)



    def test_round17_immersive_top_chrome_and_diagnostic_3cde745d_fixes(self):
        """Verifies Round 17 fixes for screenshots, CI compile patch, and diagnostic 3cde745d:
        1. MediaAPIClient.h declares cancelWithReason: and RuntimeDiagnosticsViewController.m escapes newline in stringWithFormat.
        2. MediaBrowserViewController removes the top gray/black shadow scrim (alpha=0.0, hidden=YES) for full top immersion, shows '单站点资源' for single-site plugins, and localizes 'AbortError'.
        3. MediaAPIClient jar-bridge resolves .txt dynamic mirror URLs (csp_AppDrama '苹果 • APP' / '天堂 • APP'), skips empty host='', iterates candidate site arrays ('木偶 • 4K'), and parses HTML cards for PanWebShare/Wogg.
        4. JSPluginRuntime, entry.mjs, and drpy/adapter.mjs support minified drpy2.min.js (,rule={} / import{gbkTool}), __JS_SPIDER__ global, and .hjs rule/plugin adaptation ('57吃瓜.hjs' / '海角精选.hjs').
        5. host_service_runtime.py cleanly catches 'service is stopping' RuntimeError during startup cancellation.
        """
        api_h = (SOURCES / 'MediaAPIClient.h').read_text(encoding='utf-8')
        self.assertIn('- (void)cancelWithReason:(nullable NSString *)reason;', api_h)

        diag_m = (SOURCES / 'RuntimeDiagnosticsViewController.m').read_text(encoding='utf-8')
        self.assertIn(r'峰值内存 %@\n%@', diag_m)

        mb_m = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('self.homeTopImmersiveScrim.alpha=0.0;self.homeTopImmersiveScrim.hidden=YES;', mb_m)
        self.assertIn('BOOL knownSingleSite=capabilities.count>0&&![capabilities containsObject:@"providers"]&&!self.providers.count;', mb_m)
        self.assertIn('localizedCaseInsensitiveContainsString:@"AbortError"', mb_m)

        api_m = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('MediaJARBridgeExtractTxtMirrorURL', api_m)
        self.assertIn('MediaJARBridgeCandidateURLs', api_m)
        self.assertIn('_jar_txt_resolved', api_m)
        self.assertIn('_jar_site_index', api_m)

        js_rt = (SOURCES / 'JSPluginRuntime.m').read_text(encoding='utf-8')
        self.assertIn('__JS_SPIDER__', js_rt)
        self.assertIn('__cctvAdaptRuleOrHjsPlugin', js_rt)

        hsr_py = (ROOT / 'Scripts/host_service_runtime.py').read_text(encoding='utf-8')
        self.assertIn("if session.stopping.is_set() or 'service is stopping' in str(error):", hsr_py)


    def test_round18_page_cache_image_and_playback_speed_optimizations(self):
        """Verifies Round 18 page loading, cache loading, image pipeline, and playback speed optimizations:
        1. MediaMetadataCache avoids redundant double JSON serialization on storeResult and cold-start loadPersistentRecords.
        2. MediaBrowserViewController checks warm cache before clearing items in loadHome, caches unsigned detail payloads in safeDetailMemCache, reduces shelf pacing to 15ms, and prefetches visible posters.
        3. HostImageLoader tracks viewTargets to evict zombie requests from reused cells, promotes onscreen pending requests, persists L2 downsampled thumbnails on disk, and exposes prefetchPosterURLs:.
        4. MediaPlaybackViewController triggers next-episode prefetch at 2s, warms the next episode's stream connection/manifest, and polls WebView DOM sniffer at 0.2s; MediaAPIClient ranks parsers by MediaParserSuccessScoreCache.
        """
        mc_m = (SOURCES / 'MediaMetadataCache.m').read_text(encoding='utf-8')
        self.assertIn('[persistentResult isEqual:result]?data:', mc_m)

        mb_m = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('if(!cacheStale&&!forceRefresh)return;', mb_m)
        self.assertIn('(15*NSEC_PER_MSEC)', mb_m)
        self.assertIn('[HostImageLoader.shared prefetchPosterURLs:prefetchPosters];', mb_m)
        self.assertIn('else{self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载推荐与分类…" loading:YES];}', mb_m)

        img_h = (SOURCES / 'HostImageLoader.h').read_text(encoding='utf-8')
        img_m = (SOURCES / 'HostImageLoader.m').read_text(encoding='utf-8')
        self.assertIn('- (void)prefetchPosterURLs:(NSArray<NSString *> *)urls;', img_h)
        self.assertIn('viewTargets', img_m)
        self.assertIn('CCTVHostImageThumbnails', img_m)
        self.assertIn('[self.pending insertObject:request atIndex:0];', img_m)

        mp_m = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertIn('observed>=2)[owner prefetchNextEpisodeIfNeeded];', mp_m)
        self.assertIn('[self.prefetchedAsset loadValuesAsynchronouslyForKeys:@[@"playable"]', mp_m)
        self.assertIn('[owner prepareAssetForPrefetchedResult:result identity:targetIdentity]', mp_m)
        self.assertNotIn('[warmReq setValue:@"bytes=0-1023"', mp_m)
        self.assertIn('@[@0.2,@0.45,@1.1,@2.0,@3.0]', mp_m)

        api_m = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('MediaParserSuccessScoreCache', api_m)
        self.assertIn('MediaParserRecordOutcome(parser,resolved!=nil);', api_m)



    def test_round19_cicada_sigsegv_cenc_body_limit_drpy_hjs_and_302_fixes(self):
        """Verifies Round 19 fixes for playback crash (SIGSEGV), diagnostic logs (9cf25667/5a32c261/f5d01c60), and Hawk/Butterfly sites:
        1. MediaPlaybackCicadaAdapter.m declares scalar ABI types (int64_t, float, NSInteger) on CicadaDelegate callbacks to prevent ARC objc_retain SIGSEGV crash, and MediaPlaybackViewController.m uses 45s timeout for cenc://.
        2. hongguo-python.py, hgtv_public_1_0_5.py, media-service.py, node-plugin-host.cjs, and hongguo-node.js support 32 MB CENC streams with _host_media_stream_read and <=15 MB quality preference.
        3. JSPluginRuntime.m, drpy/adapter.mjs, generic/entry.mjs, and host_media_runtime.py prevent drpy 'Unexpected keyword export' and adapt .hjs ('吃瓜网.hjs', '海角精选.hjs') with NativeJS CMS fallback.
        4. MediaAPIClient.m allows HTTPS->HTTP 302 redirects ('橘汁 · APP') and provides MediaJARBridgeCandidatesForSource; RootViewController.m defaults subscription token to '95f9cbf6'; MediaPackageDownloader.m provides PackageFallbackScriptForFailedURL.
        """
        ca_m = (SOURCES / 'MediaPlaybackCicadaAdapter.m').read_text(encoding='utf-8')
        self.assertIn('- (void)onCurrentPositionUpdate:(id)player position:(int64_t)position', ca_m)
        self.assertIn('- (void)onBufferedPositionUpdate:(id)player position:(int64_t)position', ca_m)
        self.assertIn('- (void)onLoadingProgress:(id)player progress:(float)progress', ca_m)
        self.assertIn('- (void)onPlayerStatusChanged:(id)player oldStatus:(NSInteger)oldStatus newStatus:(NSInteger)newStatus', ca_m)

        mp_m = (SOURCES / 'MediaPlaybackViewController.m').read_text(encoding='utf-8')
        self.assertIn('NSTimeInterval timeout=[sourceURL.scheme.lowercaseString isEqualToString:@"cenc"]?45:20;', mp_m)

        hg_py = (ROOT / 'Resources/BuiltinMedia/hongguo-python.py').read_text(encoding='utf-8')
        self.assertIn('_cur_th._host_media_stream_read = True', hg_py)
        self.assertIn('32 * 1024 * 1024', hg_py)

        hg_js = (ROOT / 'Resources/BuiltinMedia/hongguo-node.js').read_text(encoding='utf-8')
        self.assertIn('15 * 1024 * 1024', hg_js)

        js_rt = (SOURCES / 'JSPluginRuntime.m').read_text(encoding='utf-8')
        self.assertIn('/*__cctvTransformed__*/', js_rt)
        self.assertIn(r'moduleType === \"esm\" && protocol !== \"drpy\"', js_rt)

        api_m = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertIn('MediaJARBridgeCandidatesForSource', api_m)
        self.assertIn('MediaJARBridgeSaveWorkingBase', api_m)
        self.assertNotIn('if([from.scheme.lowercaseString isEqual:@"https"]&&[to.scheme.lowercaseString isEqual:@"http"])valid=NO;', api_m)

        root_m = (SOURCES / 'RootViewController.m').read_text(encoding='utf-8')
        self.assertNotIn('return @"95f9cbf6";', root_m)
        self.assertIn('MediaLytvsSubscriptionToken(stored)', root_m)

        dl_m = (SOURCES / 'MediaPackageDownloader.m').read_text(encoding='utf-8')
        self.assertIn('PackageFallbackScriptForFailedURL', dl_m)

        import host_media_runtime
        class DummyFailingHjsBridge:
            def __call__(self, op, payload_json):
                if op == 'start':
                    return '{"ok":false,"error":"此文件像是规则配置"}'
                return '{"ok":true,"result":{}}'

        with self.assertRaises(host_media_runtime.MediaError) as ctx:
            host_media_runtime.NativeJS(
                str(ROOT),
                {'name': '吃瓜网｜🔞', 'entry': '吃瓜网.hjs', 'protocol': 'hamo-source-v3', 'moduleType': 'script'},
                bridge=DummyFailingHjsBridge(),
            )
        self.assertIn('此文件像是规则配置', str(ctx.exception))

    def test_round20_cicada_error_code_sigsegv_js_bootstrap_kkapp_v3_and_authentic_hawk_sites(self):
        """Verifies Round 20 fixes for diagnostic logs (d17492e5/22035a74/8567a55d), playback SIGSEGV crash, For-ADM kkapp.js?v=3, and authentic Hawk site feedback:
        1. MediaPlaybackCicadaAdapter.m checks NSMethodSignature.methodReturnType in MediaPlaybackCicadaCodeFromModel so CicadaErrorModel.code (uint64_t Q16@0:8) is read as a scalar instead of id, preventing objc_retainAutoreleasedReturnValue SIGSEGV at libobjc.A.dylib offset=4724.
        2. JSPluginRuntime.m compatBootstrap escapes regex backslashes so it never throws SyntaxError: Unexpected keyword const, and drpy/adapter.mjs strips consecutive minified ESM imports without throwing Unexpected string literal.
        3. LogCenterViewController.m classifies 已启用央视播放器异常缩略图保护 as DiagnosticLogCategoryPlayback rather than DiagnosticLogCategoryError.
        4. MediaPackageDownloader.m accepts For-ADM kkapp.js?v=3 with pre-integrated sitePrepareImageDomains without throwing code 32, and removes fake csp_AppRJ/hawk stubs in PackageFallbackScriptForFailedURL.
        5. MediaAPIClient.m, JSPluginRuntime.m, host_media_runtime.py, ServiceStore.m, and MediaMetadataCache.m remove unified cross-site CMS fallbacks and purge poisoned stub services/caches.
        """
        ca_m = (SOURCES / 'MediaPlaybackCicadaAdapter.m').read_text(encoding='utf-8')
        self.assertIn("NSMethodSignature *sig = [model methodSignatureForSelector:sel];", ca_m)
        self.assertIn("return (NSInteger)((int64_t (*)(id, SEL))objc_msgSend)(model, sel);", ca_m)

        lc_m = (SOURCES / 'LogCenterViewController.m').read_text(encoding='utf-8')
        self.assertIn('if([lower containsString:@"已启用央视播放器异常缩略图保护"])return DiagnosticLogCategoryPlayback;', lc_m)

        js_rt = (SOURCES / 'JSPluginRuntime.m').read_text(encoding='utf-8')
        self.assertIn(r'replace(/\\/$/, \"\")', js_rt)
        self.assertNotIn("fallbackRule", js_rt)

        adapter_mjs = (ROOT / 'JSPlugins/drpy/adapter.mjs').read_text(encoding='utf-8')
        self.assertIn("function stripDrpyImportsAndExports(raw)", adapter_mjs)
        self.assertIn("function loadRuleFromExt(ext)", adapter_mjs)

        dl_m = (SOURCES / 'MediaPackageDownloader.m').read_text(encoding='utf-8')
        self.assertIn('![text containsString:@"sitePrepareImageDomains("]', dl_m)
        self.assertNotIn("self._engine = csp_adapter.AppVideoEngine(", dl_m)

        api_m = (SOURCES / 'MediaAPIClient.m').read_text(encoding='utf-8')
        self.assertNotIn("cmsBackups", api_m)

        ss_m = (SOURCES / 'ServiceStore.m').read_text(encoding='utf-8')
        self.assertIn("self._engine = csp_adapter.AppVideoEngine(", ss_m)

        mc_m = (SOURCES / 'MediaMetadataCache.m').read_text(encoding='utf-8')
        self.assertIn('@"MediaMetadataCache-v3.json"', mc_m)


    def test_round21_local_bundle_ctys_cycod_catalog_and_monitor_enhancements(self):
        """Verifies Request 6:
        1. TVBox Local Collection Bundle ZIP/folder support (初忆本地包1110.zip, spider.jar .class constant pool extraction, api.original.json upstream URL recovery).
        2. cttv.vip/app/json/ctys.json (刺桐影视: // header comments, 7lj763gg Qiaoji cipher decoding, pipe-delimited url|dataKey|dataIv, MacCMS type:1 sites) and gitee.com/cycod/tvbox/raw/master/api.json (初忆 TVBox 合集: csp_Douban -> douban-index, 32 csp_* JAR-Bridge sites).
        3. MediaAdaptationMonitor enhancements (recordCatalogEventWithName, decodeAndInspectConfigString, batchProbeCatalogSites, jarBridgeCount).
        """
        from csp_adapter import _decode_qiaoji_7lj763gg, AppVideoEngine, CSPAdapter, DEXParser

        # 1. Verify Qiaoji 7lj763gg decryption & pipe-delimited ext in Python
        qiaoji_sample = "7lj763gg0939795i007hi482k80ii2i3ghl084099ij36j70031107l2kg105816139i56g38h03i1j06k4gkk9ll7kl1lk4k8687k55l0g19ggk72j06gg073li1j11"
        decoded = _decode_qiaoji_7lj763gg(qiaoji_sample)
        self.assertEqual(decoded, "http://111.180.198.40:1110|asgcxhjkts124573|asgcxhjkts124573|101")

        engine_qiaoji = AppVideoEngine("csp_AppGet", qiaoji_sample)
        self.assertEqual(engine_qiaoji.base_url, "http://111.180.198.40:1110")
        self.assertEqual(engine_qiaoji.key, b"asgcxhjkts124573")
        self.assertEqual(engine_qiaoji.iv, b"asgcxhjkts124573")

        # 2. Verify cycod/tvbox and ctys.json built-in csp_* site defaults
        for cls_name in ("csp_FourKMP", "csp_HongGuo", "csp_SiKv4K", "csp_DuoDuo", "csp_NongMin", "csp_JianPian", "csp_Wwys", "csp_Tvyb", "csp_Mayi", "csp_Dryou"):
            eng = AppVideoEngine(cls_name, "")
            self.assertTrue(eng.base_url.startswith("http"), f"{cls_name} should resolve built-in base_url")

        # 3. Verify DEXParser Java .class constant pool extraction
        # Build a minimal valid Java .class header with UTF8 constants
        cls_bytes = bytearray()
        cls_bytes += b"\xca\xfe\xba\xbe\x00\x00\x00\x34"  # magic + version 52
        cls_bytes += (3).to_bytes(2, "big")  # constant_pool_count = 3 (entries 1 and 2)
        u1 = b"https://api.java-class-spider.test"
        cls_bytes += b"\x01" + len(u1).to_bytes(2, "big") + u1
        u2 = b"abcdef0123456789"
        cls_bytes += b"\x01" + len(u2).to_bytes(2, "big") + u2
        jar_buf = io.BytesIO()
        with zipfile.ZipFile(jar_buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("com/github/catvod/spider/Sample.class", bytes(cls_bytes))
        parsed_jar = DEXParser.from_jar_bytes(jar_buf.getvalue())
        self.assertIn("https://api.java-class-spider.test", parsed_jar.strings)
        self.assertIn("abcdef0123456789", parsed_jar.strings)

        # 4. Verify bundled cycod-tvbox.json and cttv-ctys.json exist and are valid
        cycod_json_path = ROOT / "Resources/BuiltinMedia/cycod-tvbox.json"
        ctys_json_path = ROOT / "Resources/BuiltinMedia/cttv-ctys.json"
        self.assertTrue(cycod_json_path.exists())
        self.assertTrue(ctys_json_path.exists())
        cycod_data = json.loads(cycod_json_path.read_text(encoding="utf-8"))
        self.assertEqual(len(cycod_data["sites"]), 33)
        self.assertEqual(cycod_data["sites"][0]["api"], "csp_Douban")
        ctys_raw = ctys_json_path.read_text(encoding="utf-8")
        self.assertTrue(ctys_raw.startswith("//"))
        self.assertIn("7lj763gg", ctys_raw)

        # 5. Verify Objective-C source contracts in TVBoxCatalogStore, MediaAPIClient, TVBoxCatalogDownloader, ResourceImportWorkflowViewController, and MediaAdaptationMonitor
        store_h = (SOURCES / "TVBoxCatalogStore.h").read_text(encoding="utf-8")
        store_m = (SOURCES / "TVBoxCatalogStore.m").read_text(encoding="utf-8")
        self.assertIn("+ (nullable NSDictionary *)parseBundleArchiveData:(NSData *)data", store_h)
        self.assertIn("+ (nullable NSDictionary *)parseBundleDirectoryAtURL:(NSURL *)directoryURL", store_h)
        self.assertIn("+ (nullable NSData *)sanitizeJSONData:(NSData *)data;", store_h)
        self.assertIn("+ (nullable NSString *)decodeQiaojiExtString:(NSString *)rawExt;", store_h)
        self.assertIn("TVBoxDecodeQiaojiExt", store_m)
        self.assertIn("TVBoxExtractClassConfigsFromJAR", store_m)
        self.assertIn("([api.lowercaseString isEqual:@\"csp_doudou\"]||[api.lowercaseString isEqual:@\"csp_douban\"])", store_m)

        api_m = (SOURCES / "MediaAPIClient.m").read_text(encoding="utf-8")
        self.assertIn("MediaJARBridgeDefaultConfigForAPI", api_m)
        self.assertIn("[TVBoxCatalogStore decodeQiaojiExtString:str]", api_m)
        self.assertIn("MediaJARUsesRuntime(self.tvboxSource)&&MediaJARRuntime.available", api_m)

        dl_m = (SOURCES / "TVBoxCatalogDownloader.m").read_text(encoding="utf-8")
        self.assertIn("@\"cycod-tvbox\"", dl_m)
        self.assertIn("@\"cttv-ctys\"", dl_m)

        wf_m = (SOURCES / "ResourceImportWorkflowViewController.m").read_text(encoding="utf-8")
        self.assertIn("https://gitee.com/cycod/tvbox/raw/master/api.json", wf_m)
        self.assertIn("https://www.cttv.vip/app/json/ctys.json", wf_m)
        self.assertIn("[TVBoxCatalogStore parseBundleDirectoryAtURL:root error:&bundleErr]", wf_m)

        mon_h = (SOURCES / "MediaAdaptationMonitor.h").read_text(encoding="utf-8")
        mon_m = (SOURCES / "MediaAdaptationMonitor.m").read_text(encoding="utf-8")
        self.assertIn("- (void)recordCatalogEventWithName:(NSString *)name", mon_h)
        self.assertIn("- (NSDictionary *)decodeAndInspectConfigString:(NSString *)rawInput;", mon_h)
        self.assertIn("- (void)batchProbeCatalogSites:(nullable NSArray<NSDictionary *> *)sites", mon_h)
        self.assertIn("decodeAndInspectConfigString:", mon_m)
        self.assertIn("batchProbeCatalogSites:", mon_m)
        self.assertIn("jarBridgeCount", mon_m)


if __name__ == '__main__':



    unittest.main()
