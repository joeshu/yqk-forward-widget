"""解码路由与 Cicada 适配器的合同测试。

只做源码静态断言（仓库既定模式）+ 一项二进制证据交叉核对：
alivcffmpeg 构建的 demuxer/decoder 清单以其内嵌的 configure 串为准，
路由表必须与之相符——格式覆盖不是凭印象写的。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_source(name):
    return (ROOT / 'Sources' / name).read_text()


class DecodeRouterContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.router_h = read_source('MediaPlaybackDecodeRouter.h')
        cls.router_m = read_source('MediaPlaybackDecodeRouter.m')
        cls.adapter_h = read_source('MediaPlaybackCicadaAdapter.h')
        cls.adapter_m = read_source('MediaPlaybackCicadaAdapter.m')
        cls.headers_m = read_source('MediaPlaybackHeaders.m')

    # ---- 路由表：Cicada 覆盖 ----

    def test_router_covers_cicada_formats(self):
        # FLV / DASH / MKV / WebM / 3GP / RTMP 必须在 Cicada 判定里。
        for ext in ('flv', 'mpd', 'mkv', 'webm', '3gp'):
            self.assertIn(f'@"{ext}"', self.router_m, f'Cicada 判定缺扩展名 {ext}')
        self.assertIn('rtmp://', self.router_m)
        self.assertIn('video/x-flv', self.router_m)
        self.assertIn('application/dash+xml', self.router_m)
        self.assertIn('video/x-matroska', self.router_m)

    def test_router_sends_unsupported_containers_to_webview_only(self):
        # AVI / WMV / RMVB：两路原生引擎都明确不支持，只能走 WebView。
        for ext in ('avi', 'wmv', 'rmvb'):
            self.assertIn(f'@"{ext}"', self.router_m, f'WebView-only 判定缺扩展名 {ext}')
        self.assertIn('MediaPlaybackResultRequiresWebViewOnly', self.router_h)
        self.assertIn('video/x-msvideo', self.router_m)
        self.assertIn('video/x-ms-wmv', self.router_m)

    def test_router_keeps_avplayer_first_for_its_formats(self):
        # AVPlayer 支持的格式判定不动（MediaPlaybackHeaders.m 的既有逻辑）。
        for ext in ('m3u8', 'mp4', 'm4v', 'mov', 'mp3', 'aac', 'ts'):
            self.assertIn(f'@"{ext}"', self.headers_m)
        # 路由函数先问 AVPlayer，再问 Cicada。
        self.assertIn('MediaPlaybackResultSupportsAVPlayer(result)', self.router_m)
        self.assertIn('MediaPlaybackResultSupportsCicadaPlayer(result)', self.router_m)

    def test_router_has_attempted_mask_and_priority_function(self):
        # 回退链靠 attempted 位掩码防循环；优先级函数是唯一决策入口。
        for name in ('MediaPlaybackDecodeRouteAttemptedAVPlayer',
                     'MediaPlaybackDecodeRouteAttemptedCicadaPlayer',
                     'MediaPlaybackDecodeRouteAttemptedWebView'):
            self.assertIn(name, self.router_h)
            self.assertIn(name, self.router_m)
        self.assertIn('MediaPlaybackDecodeRouteNextForResult', self.router_h)
        self.assertIn('MediaPlaybackDecodeRouteNone', self.router_h)
        for route in ('AVPlayer', 'CicadaPlayer', 'WebView'):
            self.assertIn(f'MediaPlaybackDecodeRoute{route}', self.router_h)

    def test_router_uses_mime_for_extensionless_urls(self):
        # 无扩展名地址（如豆儿·瓜子）靠 Content-Type/mime 判定，不只看扩展名。
        self.assertIn('contentType', self.router_m)
        self.assertIn('mimeType', self.router_m)

    # ---- 适配器：零链接依赖 ----

    def test_adapter_has_no_link_time_sdk_dependency(self):
        # ui-smoke 构建不链接 CicadaPlayerSDK 且无 dynamic_lookup：
        # 直接引用任一 SDK 符号都会在链接期失败。只允许运行时查找。
        self.assertNotIn('#import "CicadaSDK.h"', self.adapter_m)
        self.assertNotIn('#import <CicadaPlayerSDK/', self.adapter_m)
        self.assertNotIn('[CicadaPlayer ', self.adapter_m)
        self.assertNotIn('[CicadaConfig ', self.adapter_m)
        self.assertNotIn('[CicadaUrlSource ', self.adapter_m)
        self.assertNotIn('CicadaPlayer *', self.adapter_m)
        self.assertNotIn('CicadaConfig *', self.adapter_m)
        # 类查找走封装的 MediaPlaybackCicadaClass(name)，内部是 NSClassFromString。
        self.assertIn('MediaPlaybackCicadaClass(@"CicadaPlayer")', self.adapter_m)
        self.assertIn('NSClassFromString(name)', self.adapter_m)
        self.assertIn('respondsToSelector', self.adapter_m)

    def test_adapter_implements_confirmed_delegate_selectors(self):
        # 以下 5 个 selector 在 CicadaPlayerSDK 二进制中以字符串形式确认。
        for selector in ('onError:errorModel:',
                         'onCurrentPositionUpdate:position:',
                         'onLoadingProgress:progress:',
                         'onPlayerStatusChanged:oldStatus:newStatus:',
                         'onVideoSizeChanged:width:height:rotation:'):
            self.assertIn(selector, self.adapter_m, f'缺已确认的回调 {selector}')

    def test_adapter_has_polling_fallback_and_first_frame_watchdog(self):
        # 回调缺失时绝不静默黑屏：1 秒位置轮询兜底首帧/完成判定，
        # 20 秒首帧看门狗兜底报错走下一路。
        self.assertIn('pollTimer', self.adapter_m)
        self.assertIn('PositionPollInterval', self.adapter_m)
        self.assertIn('firstFrameWatchdog', self.adapter_m)
        self.assertIn('FirstFrameTimeout', self.adapter_m)
        self.assertIn('handleFirstFrame', self.adapter_m)
        self.assertIn('handleCompletion', self.adapter_m)

    def test_adapter_exposes_full_vod_controls(self):
        # 回退路径的体验要完整：播放/暂停、seek、倍速、时长/进度、销毁。
        for method in ('- (void)prepare;', '- (void)start;', '- (void)pause;',
                       '- (void)stop;', '- (void)destroy;',
                       '- (void)seekToTime:', '- (void)setRate:',
                       'currentPosition', 'duration'):
            self.assertIn(method, self.adapter_h, f'缺 VOD 控制接口 {method}')
        self.assertIn('setDelegate:', self.adapter_m)
        self.assertIn('setEnableHardwareDecoder:', self.adapter_m)

    def test_adapter_teardown_clears_delegate_and_destroys_player(self):
        # 拆解先摘 delegate 再 stop/destroy，避免回调落到已释放的适配器。
        destroy = self.adapter_m[self.adapter_m.index('- (void)destroy'):][:1200]
        self.assertIn('setDelegate:', destroy)
        self.assertIn('stop', destroy)
        self.assertIn('destroy', destroy)
        self.assertIn('invalidate', destroy)

    def test_adapter_passes_source_headers_to_cicada_config(self):
        # 猫源常需 Referer / UA 才能出流：适配器必须把请求头带进 CicadaConfig。
        self.assertIn('setHttpHeaders:', self.adapter_m)
        self.assertIn('setUserAgent:', self.adapter_m)
        self.assertIn('setReferer:', self.adapter_m)
        self.assertIn('setNetworkTimeout:', self.adapter_m)

    # ---- 二进制证据交叉核对 ----

    def test_ffmpeg_build_capabilities_match_router_tables(self):
        binary = ROOT / 'Frameworks' / 'alivcffmpeg.framework' / 'alivcffmpeg'
        if not binary.exists():
            self.skipTest('alivcffmpeg 二进制不在仓库中')
        data = binary.read_bytes()
        # configure 串很长（decoder 在 demuxer 之前），直接在整个二进制里找，
        # 不用固定窗口切片，避免截断。
        demuxers = set(m.decode() for m in re.findall(rb'--enable-demuxer=([a-z0-9_]+)', data))
        decoders = set(m.decode() for m in re.findall(rb'--enable-decoder=([a-z0-9_]+)', data))
        self.assertTrue(demuxers, '二进制中找不到 --enable-demuxer= 配置')
        self.assertTrue(decoders, '二进制中找不到 --enable-decoder= 配置')
        # 该构建实际有的 demuxer / decoder（路由表以此为准）。
        for name in ('flv', 'live_flv', 'mov', 'mpegts', 'matroska'):
            self.assertIn(name, demuxers, f'ffmpeg 构建缺 demuxer {name}')
        for name in ('h264', 'hevc', 'mpeg4', 'aac', 'mp3'):
            self.assertIn(name, decoders, f'ffmpeg 构建缺 decoder {name}')
        # 该构建明确没有的——路由表不得把它们算进 Cicada 覆盖。
        for name in ('avi', 'asf', 'rm'):
            self.assertNotIn(name, demuxers, f'ffmpeg 构建竟有 demuxer {name}')
        for name in ('vp8', 'vp9', 'av1'):
            self.assertNotIn(name, decoders, f'ffmpeg 构建竟有 decoder {name}')
        # 路由表与之相符：Cicada 覆盖含 flv/mkv，WebView-only 含 avi/wmv/rmvb。
        self.assertIn('@"flv"', self.router_m)
        self.assertIn('@"mkv"', self.router_m)
        self.assertIn('@"avi"', self.router_m)
        self.assertIn('@"rmvb"', self.router_m)

    # ---- 集成补丁说明 ----

    def test_integration_patch_doc_exists(self):
        # 集成补丁说明在仓库内（cctv-ios-host/Docs/），CI 上也能取到；
        # 不要指向工作区外的绝对路径，CI 机器上没有那个文件。
        patch = pathlib.Path(__file__).resolve().parent.parent / 'Docs' / 'CICADA-VOD-INTEGRATION-PATCH.md'
        self.assertTrue(patch.exists(), '集成补丁说明缺失：cctv-ios-host/Docs/CICADA-VOD-INTEGRATION-PATCH.md')
        text = patch.read_text()
        for anchor in ('playResult:', 'recordPlaybackFailureForItem:',
                       'stopObservingCurrentPlayback',
                       'MediaPlaybackDecodeRouteNextForResult',
                       'MediaPlaybackCicadaAdapter'):
            self.assertIn(anchor, text, f'补丁说明缺锚点 {anchor}')


if __name__ == '__main__':
    unittest.main()
