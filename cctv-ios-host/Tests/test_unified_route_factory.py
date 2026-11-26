"""T07 统一路由/工厂：候选计算 + 引擎工厂 + 描述符 + 直播接线的测试。

两部分：
(1) 行为测试——Python 模型忠实复刻 MediaPlaybackDecodeRouter.m 的候选
    计算（门禁顺序、链顺序、preferCicada、live 排除、直连媒体不进 WebView、
    cenc 本地代理只查 result["url"]），真实执行并断言输出。
(2) 源码合同测试——锁住接线：候选函数/拒绝原因/直播变体存在，描述符
    调路由不自建表，工厂按 route 建核且 MPV 禁用不实例化，VC 工厂传
    route 且引擎名真实，直播调 NextForLiveResult，终态 helper 共用。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_source(name):
    return (ROOT / 'Sources' / name).read_text()


# ---- Python 模型：复刻 MediaPlaybackDecodeRouter.m -------------------
# 位掩码与 MediaPlaybackDecodeRouter.h 一致。
ATTEMPTED_AV = 1 << 0
ATTEMPTED_CICADA = 1 << 1
ATTEMPTED_WEBVIEW = 1 << 2
ATTEMPTED_MPV = 1 << 3

AV = 'AVPlayer'
MPV = 'MPV'
CICADA = 'CicadaPlayer'
WEBVIEW = 'WebView'
NONE = 'None'

NETWORK_TRANSPORTS = ('http', 'https', 'rtmp', 'rtmps')
UNSUPPORTED_CONTAINERS = ('avi', 'wmv', 'asf', 'rm', 'rmvb')
UNSUPPORTED_VIDEO_CODECS = ('vp8', 'vp9', 'av1', 'h263', 'wmv', 'rv')
AV_FORMATS = ('hls', 'm3u8', 'm3u', 'mpegurl', 'mp4', 'm4v', 'mov', 'mp3',
              'm4a', 'aac', 'mpeg-ts', 'mpegts', 'ts', 'fmp4', 'cmaf', 'm4s',
              'f4v', 'wav', 'flac', 'alac', 'ac3', 'eac3')
AV_EXTS = ('m3u8', 'm3u', 'mp4', 'm4v', 'mov', 'm4a', 'mp3', 'aac', 'ts',
          'm4s', 'f4v', 'wav', 'flac', 'ac3', 'eac3')
CICADA_FORMATS = ('flv', 'live_flv', 'mpd', 'dash', 'mpeg-dash', 'mkv',
                  'matroska', 'webm', '3gp', '3gpp', 'rtmp')
CICADA_EXTS = ('mpd', 'flv', 'mkv', 'webm', '3gp', '3gpp')
CICADA_MIMES = ('application/dash+xml', 'video/x-flv', 'video/x-matroska',
                'video/webm', 'video/3gpp', 'video/3gpp2',
                'application/x-rtmp')
WEBVIEW_ONLY_MIMES = ('video/x-msvideo', 'video/x-ms-wmv', 'video/x-ms-asf',
                      'application/vnd.rn-realmedia', 'audio/x-pn-realaudio',
                      'video/vnd.rn-realvideo')


def _lower(value):
    return value.strip().lower() if isinstance(value, str) else ''


def _ext(url):
    if not isinstance(url, str):
        return ''
    path = url.split('?', 1)[0].split('#', 1)[0].rstrip('/')
    tail = path.rsplit('/', 1)[-1]
    return tail.rsplit('.', 1)[-1].lower() if '.' in tail else ''


def _scheme(url):
    if not isinstance(url, str) or '://' not in url:
        return ''
    return url.split('://', 1)[0].lower()


def _format(result):
    return _lower(result.get('probedContainer') or result.get('format')
                  or result.get('mediaType') or result.get('playbackType'))


def _mime(result):
    mime = _lower(result.get('probedMIME') or result.get('contentType')
                  or result.get('content_type') or result.get('mimeType')
                  or result.get('mime'))
    return mime.split(';', 1)[0].strip()


def _raw_url(result):
    return result.get('originalURL') if isinstance(
        result.get('originalURL'), str) else result.get('url', '')


def supports_cicada(result):
    if not isinstance(result, dict) or result.get('dashRemuxed'):
        return False
    if _lower(result.get('playbackEngine')) == 'cicada':
        return True
    fmt, mime = _format(result), _mime(result)
    raw = _raw_url(result)
    if (fmt in CICADA_FORMATS or _ext(raw) in CICADA_EXTS
            or mime in CICADA_MIMES or fmt in CICADA_MIMES
            or _scheme(raw) in ('rtmp', 'rtmps', 'udp')):
        return True
    if not _ext(raw) and isinstance(raw, str) and raw:
        low = raw.lower()
        if any(t in low for t in ('.flv?', 'format=flv', 'type=flv',
                                  'format=mpd', '.mpd?')):
            return True
    return False


def supports_av(result):
    if not isinstance(result, dict):
        return False
    if result.get('dashRemuxed'):
        return True
    if (_lower(result.get('playbackEngine')) == 'cicada'
            or supports_cicada(result)):
        return False
    if result.get('nativePlayable'):
        return True
    fmt, mime = _format(result), _mime(result)
    if fmt in AV_FORMATS or mime in (
            'application/vnd.apple.mpegurl', 'application/x-mpegurl',
            'audio/mpegurl', 'video/mp4', 'application/mp4',
            'video/quicktime', 'audio/mp4', 'audio/x-m4a', 'audio/mpeg',
            'audio/aac', 'audio/wav', 'audio/flac', 'video/x-m4v',
            'video/mp2t'):
        return True
    raw = _raw_url(result)
    if _ext(raw) in AV_EXTS:
        return True
    if not _ext(raw) and isinstance(raw, str) and raw:
        low = raw.lower()
        if any(t in low for t in ('.m3u8', '.mp4', '/m3u8/', '/hls/',
                                  '/cenc/', 'format=m3u8', 'type=m3u8',
                                  'ctype=m3u8', 'playtype=m3u8',
                                  'format=hls', 'type=hls', 'ext=m3u8',
                                  'ext=mp4', 'format=mp4', 'playtype=mp4',
                                  'ctype=mp4', 'type=mp4', '.ts?',
                                  'mime=video')):
            return True
    return False


def supports_native(result):
    return supports_av(result) or supports_cicada(result)


def is_direct_media(result):
    if not isinstance(result, dict):
        return False
    if result.get('directMedia'):
        return True
    if supports_native(result):
        return True
    mime = _mime(result)
    if mime.startswith('video/') or mime.startswith('audio/'):
        return True
    if _format(result) in ('mpd', 'dash', 'flv', 'mkv', 'avi', 'webm',
                           'wmv', 'rmvb'):
        return True
    raw = _raw_url(result)
    if _ext(raw) in ('mpd', 'flv', 'mkv', 'avi', 'webm', 'wmv', 'rmvb',
                     'm3u8', 'mp4'):
        return True
    if not _ext(raw) and isinstance(raw, str) and raw:
        low = raw.lower()
        if any(t in low for t in ('.m3u8', '.mp4', '.flv', '.mpd')):
            return True
    return False


def requires_webview_only(result, mpv_enabled=True):
    if not isinstance(result, dict):
        return False
    if mpv_enabled:
        return False
    if _format(result) in UNSUPPORTED_CONTAINERS:
        return True
    if _mime(result) in WEBVIEW_ONLY_MIMES:
        return True
    return _ext(_raw_url(result)) in UNSUPPORTED_CONTAINERS


def rejection_reason(result, mpv_enabled=True):
    """与 MediaPlaybackDecodeRouteRejectionReasonForResult 同顺序。"""
    if not isinstance(result, dict):
        return 'unsupported_transport'
    if requires_webview_only(result, mpv_enabled):
        return 'unsupported_container'
    codec = result.get('videoCodec')
    if isinstance(codec, str) and codec.lower() in UNSUPPORTED_VIDEO_CODECS:
        return 'unsupported_video_codec'
    # 传输只看 result["url"]：红果 cenc 本地代理的 originalURL 是 cenc://，
    # 可播地址在 url 字段里，查 originalURL 会误杀它。
    url = result.get('url') if isinstance(result.get('url'), str) else ''
    transport = _scheme(url)
    if transport not in NETWORK_TRANSPORTS and not url.startswith('file://'):
        return 'unsupported_transport'
    return None


def candidates(result, attempted=0, for_live=False, mpv_enabled=True,
               decode_mode='auto'):
    """与 MediaPlaybackDecodeRouteCandidatesForResult 同逻辑。"""
    if not isinstance(result, dict):
        return []
    if rejection_reason(result, mpv_enabled) is not None:
        return []
    direct = is_direct_media(result)
    av_supported = supports_av(result)
    requires_web = ((result.get('requiresWebPlayback')
                     or (isinstance(result.get('parse'), int)
                         and result['parse'] > 0)
                     or (isinstance(result.get('jx'), int)
                         and result['jx'] > 0))
                    and not direct)
    probed = _lower(result.get('probedContainer'))
    raw_ts = (_ext(_raw_url(result)) == 'ts'
              and _format(result) not in ('hls', 'm3u8'))
    prefer_cicada = (probed in ('flv', 'live_flv', 'mkv', 'matroska',
                                'webm', '3gp', '3gpp', 'rtmp', 'mpegts')
                     or raw_ts or decode_mode in ('cicada', 'cicada_soft')
                     or _lower(result.get('playbackEngine')) == 'cicada')
    legacy_cicada = decode_mode == 'cicada_legacy'
    cicada_mode = ('cicada_soft' if decode_mode == 'cicada_soft'
                   or result.get('preferSoftwareDecode') else 'cicada')
    if requires_web:
        if for_live or (attempted & ATTEMPTED_WEBVIEW):
            return []
        return [{'route': WEBVIEW, 'decodeMode': 'webview',
                 'reason': 'web_page'}]
    chain = [AV, MPV, CICADA, WEBVIEW]
    bits = {AV: ATTEMPTED_AV, MPV: ATTEMPTED_MPV, CICADA: ATTEMPTED_CICADA,
            WEBVIEW: ATTEMPTED_WEBVIEW}
    out = []
    for route in chain:
        if route == MPV and not mpv_enabled:
            continue
        if route == MPV and legacy_cicada:
            continue
        if for_live and route in (MPV, WEBVIEW):
            continue
        if route == WEBVIEW and direct:
            continue
        if route == AV and not av_supported:
            continue
        if attempted & bits[route]:
            continue
        mode = {AV: 'av', MPV: 'mpv', CICADA: cicada_mode,
                WEBVIEW: 'webview'}[route]
        reason = {AV: 'av_supported', MPV: 'mpv_preferred',
                  CICADA: ('cicada_preferred' if prefer_cicada
                           else 'cicada_fallback'),
                  WEBVIEW: 'web_page'}[route]
        out.append({'route': route, 'decodeMode': mode, 'reason': reason})
    if prefer_cicada:
        routes = [c['route'] for c in out]
        if MPV in routes and CICADA in routes:
            i, j = routes.index(MPV), routes.index(CICADA)
            if j > i:
                out[i], out[j] = out[j], out[i]
    return out


def next_route(result, attempted=0, for_live=False, **kw):
    found = candidates(result, attempted, for_live, **kw)
    return found[0]['route'] if found else NONE


class RouteCandidateModelTests(unittest.TestCase):
    def test_mp4_direct_chain_is_av_then_mpv_then_cicada(self):
        result = {'url': 'https://cdn.test/movie.mp4', 'format': 'mp4'}
        got = candidates(result)
        self.assertEqual([c['route'] for c in got], [AV, MPV, CICADA])
        self.assertEqual(got[0], {'route': AV, 'decodeMode': 'av',
                                  'reason': 'av_supported'})
        self.assertEqual(got[1]['decodeMode'], 'mpv')
        self.assertEqual(got[1]['reason'], 'mpv_preferred')
        self.assertEqual(got[2]['decodeMode'], 'cicada')
        self.assertEqual(got[2]['reason'], 'cicada_fallback')
        self.assertEqual(next_route(result), AV)
        self.assertEqual(next_route(result, ATTEMPTED_AV), MPV)
        self.assertEqual(next_route(result, ATTEMPTED_AV | ATTEMPTED_MPV),
                         CICADA)
        # 直连媒体耗尽原生候选后返回 None，不进 WebView。
        self.assertEqual(next_route(
            result, ATTEMPTED_AV | ATTEMPTED_MPV | ATTEMPTED_CICADA), NONE)

    def test_flv_skips_avplayer(self):
        result = {'url': 'https://cdn.test/live.flv', 'format': 'flv'}
        self.assertEqual([c['route'] for c in candidates(result)],
                         [MPV, CICADA])
        self.assertEqual(next_route(result), MPV)
        self.assertEqual([c['route'] for c in candidates(
            result, mpv_enabled=False)], [CICADA])

    def test_prefer_cicada_puts_cicada_before_mpv(self):
        mp4 = {'url': 'https://cdn.test/movie.mp4', 'format': 'mp4'}
        self.assertEqual(
            [c['route'] for c in candidates(mp4, decode_mode='cicada')],
            [AV, CICADA, MPV])
        self.assertEqual(
            candidates(mp4, decode_mode='cicada')[1]['reason'],
            'cicada_preferred')
        flv = {'url': 'https://cdn.test/live.flv', 'format': 'flv',
               'playbackEngine': 'cicada'}
        self.assertEqual([c['route'] for c in candidates(flv)],
                         [CICADA, MPV])

    def test_legacy_cicada_mode_excludes_mpv(self):
        result = {'url': 'https://cdn.test/movie.mp4', 'format': 'mp4'}
        self.assertEqual(
            [c['route'] for c in candidates(result,
                                            decode_mode='cicada_legacy')],
            [AV, CICADA])

    def test_cicada_soft_decode_mode_flows_into_candidate(self):
        result = {'url': 'https://cdn.test/movie.mp4', 'format': 'mp4'}
        # cicada_soft 也是 preferCicada：Cicada 换到 MPV 之前（下标 1）。
        self.assertEqual(
            candidates(result, decode_mode='cicada_soft')[1]['decodeMode'],
            'cicada_soft')
        soft_flag = {'url': 'https://cdn.test/movie.mp4', 'format': 'mp4',
                     'preferSoftwareDecode': True}
        self.assertEqual(candidates(soft_flag)[2]['decodeMode'],
                         'cicada_soft')

    def test_parse_page_goes_to_webview_only(self):
        page = {'url': 'https://watch.test/play?id=1', 'parse': 1,
                'format': 'html'}
        self.assertEqual(candidates(page), [{'route': WEBVIEW,
                                            'decodeMode': 'webview',
                                            'reason': 'web_page'}])
        self.assertEqual(candidates(page, ATTEMPTED_WEBVIEW), [])
        self.assertEqual(next_route(page), WEBVIEW)

    def test_live_excludes_mpv_and_webview(self):
        result = {'url': 'https://cdn.test/live.m3u8', 'format': 'm3u8'}
        self.assertEqual([c['route'] for c in candidates(result,
                                                        for_live=True)],
                         [AV, CICADA])
        self.assertEqual(next_route(result, for_live=True), AV)
        self.assertEqual(next_route(result, ATTEMPTED_AV, for_live=True),
                         CICADA)
        self.assertEqual(next_route(
            result, ATTEMPTED_AV | ATTEMPTED_CICADA, for_live=True), NONE)
        page = {'url': 'https://watch.test/play?id=1', 'parse': 1}
        self.assertEqual(candidates(page, for_live=True), [])

    def test_avi_rejected_only_when_mpv_disabled(self):
        avi = {'url': 'https://cdn.test/movie.avi', 'format': 'avi'}
        self.assertIsNone(rejection_reason(avi, mpv_enabled=True))
        self.assertEqual([c['route'] for c in candidates(
            avi, mpv_enabled=True)], [MPV, CICADA])
        self.assertEqual(rejection_reason(avi, mpv_enabled=False),
                         'unsupported_container')
        self.assertEqual(candidates(avi, mpv_enabled=False), [])

    def test_vp9_rejected_by_codec_gate(self):
        webm = {'url': 'https://cdn.test/movie.webm', 'format': 'webm',
                'videoCodec': 'VP9'}
        self.assertEqual(rejection_reason(webm), 'unsupported_video_codec')
        self.assertEqual(candidates(webm), [])
        future = {'url': 'https://cdn.test/movie.webm', 'format': 'webm',
                  'videoCodec': 'future-codec'}
        self.assertIsNone(rejection_reason(future))

    def test_unsupported_transport_rejected(self):
        rtsp = {'url': 'rtsp://cam.test/live', 'format': 'rtsp'}
        self.assertEqual(rejection_reason(rtsp), 'unsupported_transport')
        self.assertEqual(candidates(rtsp), [])
        rtmp = {'url': 'rtmp://cdn.test/live/key', 'format': 'rtmp'}
        self.assertIsNone(rejection_reason(rtmp))
        self.assertEqual(next_route(rtmp), MPV)

    def test_cenc_local_proxy_uses_url_not_original_url(self):
        # 红果本地代理：originalURL 是 cenc://，可播地址在 url 字段。
        # 门禁只查 url，否则会误杀。
        result = {'url': 'http://127.0.0.1:10010/hg.mp4',
                  'originalURL': 'cenc://vid123', 'format': 'mp4'}
        self.assertIsNone(rejection_reason(result))
        self.assertEqual(next_route(result), AV)
        cenc_url = {'url': 'cenc://vid123', 'format': 'mp4'}
        self.assertEqual(rejection_reason(cenc_url),
                         'unsupported_transport')

    def test_file_url_allowed(self):
        result = {'url': 'file:///var/mobile/test.mp4', 'format': 'mp4'}
        self.assertIsNone(rejection_reason(result))
        self.assertEqual(next_route(result), AV)

    def test_non_dict_has_no_candidates(self):
        self.assertEqual(rejection_reason(None), 'unsupported_transport')
        self.assertEqual(candidates(None), [])
        self.assertEqual(next_route(None), NONE)

    def test_unknown_format_falls_through_to_webview_tail(self):
        result = {'url': 'https://cdn.test/stream'}
        self.assertIsNone(rejection_reason(result))
        self.assertEqual([c['route'] for c in candidates(result)],
                         [MPV, CICADA, WEBVIEW])
        self.assertEqual(next_route(
            result, ATTEMPTED_MPV | ATTEMPTED_CICADA), WEBVIEW)


class UnifiedRouteFactoryContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.router_h = read_source('MediaPlaybackDecodeRouter.h')
        cls.router_m = read_source('MediaPlaybackDecodeRouter.m')
        cls.descriptor_m = read_source('MediaDescriptor.m')
        cls.coord_h = read_source('HostPlaybackAndResourceCoordinators.h')
        cls.coord_m = read_source('HostPlaybackAndResourceCoordinators.m')
        cls.vc = read_source('MediaPlaybackViewController.m')
        cls.live = read_source('RootViewController+Playback.m')

    # ---- 路由器：单一候选计算 ----
    def test_router_exposes_candidate_and_rejection_functions(self):
        for name in ('MediaPlaybackDecodeRouteCandidatesForResult',
                     'MediaPlaybackDecodeRouteRejectionReasonForResult',
                     'MediaPlaybackDecodeRouteNextForLiveResult'):
            self.assertIn(name, self.router_h, f'路由头缺 {name}')
            self.assertIn(name, self.router_m, f'路由实现缺 {name}')
        self.assertIn('@"unsupported_container"', self.router_m)
        self.assertIn('@"unsupported_video_codec"', self.router_m)
        self.assertIn('@"unsupported_transport"', self.router_m)
        self.assertIn('@"decodeMode"', self.router_m)
        self.assertIn('@"reason"', self.router_m)
        self.assertIn('@"cicada_soft"', self.router_m)
        self.assertIn('@"cicada_preferred"', self.router_m)
        self.assertIn('@"cicada_fallback"', self.router_m)

    def test_router_mpv_branch_uses_enabled_state_not_availability(self):
        # R4：MPV 分支按启用状态（开关 + isAvailable），不是裸可用性。
        self.assertIn('MediaPlaybackMPVRouteEnabled()', self.router_m)
        self.assertNotIn('if (MediaPlaybackMPVUniversalAvailable()) {',
                         self.router_m)

    # ---- 描述符：统一到路由 ----
    def test_descriptor_delegates_to_router(self):
        self.assertIn('MediaPlaybackDecodeRouteRejectionReasonForResult(_result)',
                      self.descriptor_m, '描述符未调路由拒绝原因')
        self.assertIn('MediaPlaybackDecodeRouteCandidatesForResult(_result,0,NO)',
                      self.descriptor_m, '描述符未调路由候选函数')
        self.assertNotIn('MediaPlaybackResultRequiresWebViewOnly(_result)',
                         self.descriptor_m, '描述符仍自建 webOnly 判断')
        self.assertNotIn('MediaCapabilityUnsupportedVideoCodecs()',
                         self.descriptor_m, '描述符仍自建编码表')
        self.assertNotIn('MediaCapabilityNetworkTransports()',
                         self.descriptor_m, '描述符仍自建传输表')

    # ---- 工厂：按 route 建核 ----
    def test_factory_builds_only_the_decided_route(self):
        self.assertIn('+ (nullable id<CCTVPlaybackEngine>)engineForRoute:',
                      self.coord_h, '协调器头缺按 route 建引擎的工厂')
        self.assertIn('engineForRoute:(MediaPlaybackDecodeRoute)route',
                      self.coord_m, '协调器实现缺按 route 建引擎的工厂')
        self.assertIn('if (!MediaPlaybackMPVRouteEnabled()) return nil;',
                      self.coord_m, '工厂未对禁用 MPV 做 fail-closed')
        self.assertIn('if (![MediaPlaybackCicadaAdapter isAvailable]) return nil;',
                      self.coord_m, '工厂未对不可用 Cicada 做 fail-closed')
        for source, name in ((self.coord_h, '协调器头'),
                             (self.coord_m, '协调器实现'),
                             (self.vc, '播放页'), (self.live, '直播页')):
            self.assertNotIn('createUniversalEngineWithURL', source,
                             f'{name} 仍有无调用方的通用引擎构造')

    # ---- VC 工厂：传 route、引擎名真实、终态共用 ----
    def test_vc_factory_takes_route_and_uses_single_factory(self):
        self.assertIn('startCicadaPlaybackWithResult:(NSDictionary *)result route:(MediaPlaybackDecodeRoute)route',
                      self.vc, 'VC 工厂未接 route 参数')
        self.assertIn('engineForRoute:route', self.vc,
                      'VC 工厂未走协调器单一工厂')
        self.assertIn('useMPV?MediaPlaybackDecodeRouteAttemptedMPV:MediaPlaybackDecodeRouteAttemptedCicadaPlayer',
                      self.vc, 'VC 未按已决定 route 置 attempted 位')
        self.assertIn('MediaPlaybackDecodeRouteName(route)', self.vc,
                      'VC handoff 未用真实引擎名')
        self.assertNotIn('@"player":@"cicada"', self.vc,
                         'VC 仍有把 MPV 记成 cicada 的硬编码')
        self.assertIn('showTerminalPlaybackFailureWithStatus:',
                      self.vc, 'VC 缺统一终态 helper')
        self.assertIn('failureKind:@"engine_unavailable"', self.vc,
                      '工厂 fail-closed 未走统一终态')

    def test_vc_terminal_helper_covers_all_early_returns(self):
        for kind in ('webview_presented', 'webview_no_url',
                     'webview_direct_media', 'no_playback_route'):
            self.assertIn(f'failureKind:@"{kind}"', self.vc,
                          f'终态 helper 未覆盖 {kind}')
        self.assertIn('outcome:@"failed" failureKind:@"cicada_playback_failed"',
                      self.vc, 'advance 终态分支未走 helper')

    def test_vc_watchdog_passes_peeked_route(self):
        self.assertIn('route:[owner.playbackSession peekNextRouteForResult:owner.result]',
                      self.vc, '看门狗未把 peek 到的 route 传给工厂')

    # ---- 直播：统一路由 ----
    def test_live_uses_live_route_function(self):
        self.assertIn('MediaPlaybackDecodeRouteNextForLiveResult(descriptor,0)',
                      self.live, '直播首选未用 NextForLiveResult')
        self.assertIn('NextForLiveResult(liveDescriptor,MediaPlaybackDecodeRouteAttemptedAVPlayer)',
                      self.live, '直播看门狗未用 NextForLiveResult 取下一候选')
        self.assertNotIn('MediaPlaybackDecodeRouteNextForResult(descriptor,0)==MediaPlaybackDecodeRouteCicadaPlayer',
                         self.live, '直播仍在用旧的点播路由直启 Cicada')
        self.assertIn('liveFirst==MediaPlaybackDecodeRouteNone',
                      self.live, '直播无候选时未走终态')


if __name__ == '__main__':
    unittest.main()
