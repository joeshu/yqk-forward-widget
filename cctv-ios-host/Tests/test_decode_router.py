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
                     'MediaPlaybackDecodeRouteAttemptedWebView',
                     'MediaPlaybackDecodeRouteAttemptedMPV'):
            self.assertIn(name, self.router_h)
            self.assertIn(name, self.router_m)
        self.assertIn('MediaPlaybackDecodeRouteNextForResult', self.router_h)
        self.assertIn('MediaPlaybackDecodeRouteNone', self.router_h)
        for route in ('AVPlayer', 'CicadaPlayer', 'WebView', 'MPV'):
            self.assertIn(f'MediaPlaybackDecodeRoute{route}', self.router_h)

    def test_router_uses_mime_for_extensionless_urls(self):
        # 无扩展名地址（如豆儿·瓜子）靠 Content-Type/mime 判定，不只看扩展名。
        self.assertIn('contentType', self.router_m)
        self.assertIn('mimeType', self.router_m)

    def test_parser_pages_go_to_webview_without_native_probe(self):
        self.assertIn('if (requiresWebPlayback) {', self.router_m)
        self.assertIn('MediaPlaybackDecodeRouteAttemptedWebView', self.router_m)
        self.assertIn('MediaPlaybackDecodeRouteWebView', self.router_m)

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

    def test_adapter_unified_path_fixes_and_ports_direct_engine(self):
        # 直连 Cicada 引擎已删除，统一走适配器 + 路由；以下断言钉住
        # 移植时修掉的适配器问题与搬过来的直连能力。
        # Step 0(1)：画面比例按 CicadaScalingMode 映射（0=Fill、1=Fit、2=AspectFill）。
        self.assertIn('AVLayerVideoGravityResizeAspectFill]) mode = 2;', self.adapter_m)
        self.assertIn('AVLayerVideoGravityResize]) mode = 0;', self.adapter_m)
        self.assertIn('int mode = 1;', self.adapter_m)
        # Step 0(2)：seekMode 传 CICADA_SEEKMODE_ACCURATE（0x01），不再传 0。
        self.assertIn('MAX(0, time), 0x01)', self.adapter_m)
        # Step 0(3)：CicadaConfig.networkTimeout 单位是毫秒，秒数要 ×1000。
        self.assertIn('(int)llround(self.networkTimeout * 1000.0)', self.adapter_m)
        # Step 0(4)：长按 3x 不再被静默截断到 2.0。
        self.assertIn('MIN(3.0f, MAX(0.5f, rate))', self.adapter_m)
        # Step 1(1)：prepare 可指定硬解开关，默认硬件优先。
        self.assertIn('- (void)prepareWithHardwareDecoder:(BOOL)enableHardwareDecoder;', self.adapter_h)
        self.assertIn('prepareWithHardwareDecoder:!self.cicadaAdapterSoftwareDecodeFallbackAttempted',
                      read_source('MediaPlaybackViewController.m'))
        # Step 1(2)(3)：下载速度与视频尺寸回调已接进适配器 delegate。
        self.assertIn('onCurrentDownLoadSpeed:', self.adapter_m)
        self.assertIn('didUpdateDownloadSpeed:', self.adapter_h)
        self.assertIn('onVideoSizeChanged:', self.adapter_m)
        self.assertIn('didUpdateVideoSize:', self.adapter_h)
        # Step 1(4)(5)：Cicada 失败无下一路时自动换线路；位置回调做进度采样。
        player = read_source('MediaPlaybackViewController.m')
        self.assertIn('tryNextLineForAutomaticFallback:@"cicada_playback_failed"', player)
        self.assertIn('cicada_software_decode_fallback', player)
        self.assertIn('HostPlaybackProgressSample(&self->_progressEvidence,CACurrentMediaTime(),position,self.cicadaAdapter.rate',
                      player)
        # Step 2：直连引擎已删干净（VC 不再 import CicadaSDK.h、不再有
        # CicadaPlayer 实例与直连回调方法）。
        self.assertNotIn('#import "CicadaSDK.h"', player)
        self.assertNotIn('CicadaPlayer *cicadaPlayer', player)
        self.assertNotIn('tearDownCicadaPlayer', player)
        self.assertNotIn('playCicadaResult:', player)
        self.assertNotIn('setGestureSurfaceForCicada:', player)
        self.assertNotIn('onVideoRendered:', player)

    def test_adapter_teardown_clears_delegate_and_destroys_player(self):
        # 拆解先摘 delegate 再 stop/destroy，避免回调落到已释放的适配器。
        destroy = self.adapter_m[self.adapter_m.index('- (void)destroy'):][:1200]
        self.assertIn('setDelegate:', destroy)
        self.assertIn('stop', destroy)
        self.assertIn('destroy', destroy)
        self.assertIn('invalidate', destroy)

    def test_adapter_matches_cicada_binary_instance_and_abi_contracts(self):
        # CicadaUrlSource.urlWithString: 在真机二进制中是实例方法（-），而非类方法（+）
        self.assertIn('id instance = [[sourceClass alloc] init];', self.adapter_m)
        self.assertIn('[instance respondsToSelector:NSSelectorFromString(@"urlWithString:")]', self.adapter_m)
        self.assertIn('MediaPlaybackCicadaClass(@"CicadaPlayerView")', self.adapter_m)
        self.assertIn('[NSString stringWithFormat:@"%@: %@", key, value]', self.adapter_m)
        self.assertIn('- (void)onPlayerEvent:(id)player eventType:(NSUInteger)eventType', self.adapter_m)
        self.assertIn('methodSignatureForSelector:', self.adapter_m)
        binary = ROOT / 'Frameworks' / 'CicadaPlayerSDK.framework' / 'CicadaPlayerSDK'
        if binary.exists():
            raw = binary.read_bytes()
            self.assertIn(b'-[CicadaUrlSource urlWithString:]', raw)
            self.assertNotIn(b'+[CicadaUrlSource urlWithString:]', raw)
            self.assertIn(b'onPlayerEvent:eventType:', raw)

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



    def test_router_supports_probed_container_and_magic_sniffer(self):
        self.assertIn('MediaPlaybackSniffContainerFormat', self.router_h)
        self.assertIn('MediaPlaybackSniffContainerFormat', self.router_m)
        self.assertIn('probedContainer', self.router_m)
        self.assertIn('probedMIME', self.router_m)
        probe_h = read_source('HLSRouteProbe.h')
        probe_m = read_source('HLSRouteProbe.m')
        self.assertIn('sniffContainerMagic:', probe_h)
        self.assertIn('cctvhost.hls.route.probe', probe_m)
        inspection_m = read_source('ResourceContentInspection.m')
        self.assertIn('ResourcePythonRegex(void)', inspection_m)
        self.assertIn('ResourceAnchorsRegex(void)', inspection_m)


class MPVRouteWiringContracts(unittest.TestCase):
    """MPV 点播路由接通契约：验证 MediaPlaybackViewController 真正启动 MPV adapter，
    且 MPV 失败时按候选链 AVPlayer → MPV → Cicada → WebView 正确回退到 Cicada。"""

    @classmethod
    def setUpClass(cls):
        cls.vc = read_source('MediaPlaybackViewController.m')
        cls.router_m = read_source('MediaPlaybackDecodeRouter.m')
        cls.mpv_h = read_source('MediaPlaybackMPVAdapter.h')
        cls.mpv_m = read_source('MediaPlaybackMPVAdapter.m')

    def test_router_candidate_chain_includes_mpv_between_avplayer_and_cicada(self):
        # 候选链顺序必须是 AVPlayer → MPV → Cicada → WebView。
        candidates_line = [l for l in self.router_m.split('\n')
                           if 'MediaPlaybackDecodeRoute candidates' in l]
        self.assertTrue(candidates_line, '路由候选链声明缺失')
        chain = candidates_line[0]
        idx_av = chain.index('AVPlayer')
        idx_mpv = chain.index('MPV')
        idx_cicada = chain.index('CicadaPlayer')
        idx_web = chain.index('WebView')
        self.assertLess(idx_av, idx_mpv, 'MPV 必须排在 AVPlayer 之后')
        self.assertLess(idx_mpv, idx_cicada, 'MPV 必须排在 Cicada 之前')
        self.assertLess(idx_cicada, idx_web, 'Cicada 必须排在 WebView 之前')

    def test_router_skips_mpv_when_disabled(self):
        # MediaPlaybackMPVRouteEnabled 为 NO 时跳过 MPV 候选。
        self.assertIn('MediaPlaybackMPVRouteEnabled()', self.router_m)
        self.assertIn('route == MediaPlaybackDecodeRouteMPV && !MediaPlaybackMPVRouteEnabled()', self.router_m)

    def test_playresult_dispatches_mpv_route_to_cicada_path(self):
        # playResult: 必须把 MediaPlaybackDecodeRouteMPV 分发到 startCicadaPlaybackWithResult:，
        # 不能落入 AVPlayer 路径。
        self.assertIn(
            'initialRoute==MediaPlaybackDecodeRouteCicadaPlayer||initialRoute==MediaPlaybackDecodeRouteMPV',
            self.vc, 'playResult: 未把 MPV 路由分发到 startCicadaPlaybackWithResult:')

    def test_cicada_path_sets_correct_attempted_bit_for_mpv(self):
        # startCicadaPlaybackWithResult: 必须根据 useMPV 设置 MPV 或 Cicada 位掩码，
        # 不再无条件只设 Cicada 位。
        self.assertIn('useMPV?MediaPlaybackDecodeRouteAttemptedMPV:MediaPlaybackDecodeRouteAttemptedCicadaPlayer',
                      self.vc, 'startCicadaPlaybackWithResult: 未按 useMPV 设置正确的路由位掩码')

    def test_cicada_path_avoids_mpv_retry_after_failure(self):
        # useMPV 必须检查 AttemptedMPV 位，避免 MPV 失败后重复创建 MPV adapter。
        self.assertIn('!(self.attemptedRoutes&MediaPlaybackDecodeRouteAttemptedMPV)',
                      self.vc, 'useMPV 未检查 AttemptedMPV 位以防止 MPV 回退后重试')

    def test_cicada_failure_handles_mpv_and_cicada_fallback_routes(self):
        # advanceFromCicadaFailureWithError: 必须处理 nextRoute==MPV 和 nextRoute==CicadaPlayer，
        # 调用 startCicadaPlaybackWithResult: 而不是跳过。
        self.assertIn(
            'nextRoute==MediaPlaybackDecodeRouteMPV||nextRoute==MediaPlaybackDecodeRouteCicadaPlayer',
            self.vc, 'advanceFromCicadaFailureWithError: 未处理 MPV/Cicada 回退路由')

    def test_mpv_adapter_implements_full_lifecycle(self):
        # MPV adapter 必须实现 prepare/start/pause/stop/destroy 完整生命周期。
        for method in ('- (void)prepare;', '- (void)prepareWithHardwareDecoder:',
                       '- (void)start;', '- (void)pause;', '- (void)stop;', '- (void)destroy;',
                       '- (void)seekToTime:', '- (void)setRate:'):
            self.assertIn(method, self.mpv_h, f'MPV adapter 缺接口 {method}')

    def test_mpv_adapter_has_first_frame_watchdog_and_failure_callback(self):
        # MPV adapter 必须有首帧看门狗和失败回调，使 VC 能在 MPV 失败时回退。
        self.assertIn('firstFrameWatchdog', self.mpv_m)
        self.assertIn('FirstFrameTimeout', self.mpv_m)
        self.assertIn('handleFirstFrameTimeout', self.mpv_m)
        self.assertIn('handleFailureWithCode:', self.mpv_m)
        self.assertIn('didFailWithError:', self.mpv_m)

    def test_mpv_adapter_destroy_releases_handle(self):
        # destroy 必须摘除 delegate、终止 mpv handle、防止回调落到已释放的 adapter。
        destroy = self.mpv_m[self.mpv_m.index('- (void)destroy'):][:1200]
        self.assertIn('self.destroyed = YES', destroy)
        self.assertIn('self.delegate = nil', destroy)
        self.assertIn('terminate_destroy', destroy)
        self.assertIn('cancelFirstFrameWatchdog', destroy)

    def test_mpv_adapter_uses_generation_safe_delegate(self):
        # VC 的 delegate 回调必须检查 adapter 身份（generation 隔离），
        # 防止旧 MPV adapter 的回调影响新 adapter。
        self.assertIn('if(adapter!=self.cicadaAdapter)return;', self.vc,
                      'VC delegate 回调缺少 adapter 身份检查')

    def test_mpv_adapter_dlopen_isolation(self):
        # MPV adapter 通过 dlopen RTLD_LOCAL 隔离 C 符号，不静态链接任何 libmpv/FFmpeg 符号。
        self.assertIn('RTLD_NOW | RTLD_LOCAL', self.mpv_m)
        self.assertNotIn('#import <mpv/', self.mpv_m)
        self.assertNotIn('#import "mpv/', self.mpv_m)


if __name__ == '__main__':
    unittest.main()
