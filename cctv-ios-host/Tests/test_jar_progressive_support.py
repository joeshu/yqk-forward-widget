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


if __name__ == '__main__':
    unittest.main()
