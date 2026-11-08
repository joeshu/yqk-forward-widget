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
    def test_l1_sibling_script_association_contract(self):
        """Verifies that MediaBrowserViewController includes fallback sibling mapping."""
        mb = (SOURCES / 'MediaBrowserViewController.m').read_text(encoding='utf-8')
        self.assertIn('MediaBrowserFallbackSupportedSite', mb)
        self.assertIn('MediaBrowserStationCoreName', mb)
        self.assertIn('iOS 脚本适配 · 已关联', mb)

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
        self.assertIn('Android/JAR 适配引擎 · iOS 原生执行', store_code)
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
        self.assertIn('fbArgs[@"_jar_fallback"]=@YES;', api_code)

        # Verify empty ext csp_* site resolves to built-in CMS host instead of empty URL
        empty_engine = AppVideoEngine('csp_Gz360', '')
        self.assertTrue(empty_engine.base_url.startswith('https://'))
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
        self.assertIn('resolveMacCMSStreamByTitleForResult', mp_code)



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
        self.assertEqual(_extract_stream_from_html(html_atob), 'https://cdn.example/atob/index.m3u8')

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


if __name__ == '__main__':


    unittest.main()
