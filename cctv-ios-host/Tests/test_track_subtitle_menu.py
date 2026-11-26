"""T09 音轨、字幕、倍速与播放菜单（F2/S3）。

审计 ID：F2（音轨/字幕/外挂字幕）；方案 §10.2 验收 A06（双轨/字幕切换/
晚返回旧字幕/文字时序偏差<=250ms）、A10（倍速/换集/旧请求不得完成新请求）。

两类测试：
- 行为测试：按 ObjC 实现逐条复刻的 Python 模型（字幕 cue 查找、加载代际、
  尺寸/状态门禁、菜单会话守卫、轨道选择验证）。
- 合同测试：源码接线断言，锁住 ObjC 实现与模型一致的关键点。
"""
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, 'Sources')


def read(name):
    with open(os.path.join(SRC, name), encoding='utf-8') as fh:
        return fh.read()


SUBTITLE_MAX_BYTES = 2 * 1024 * 1024


# ---------------------------------------------------------------- 模型 ---

class SubtitleCueLookup:
    """HostSubtitleOverlayView.updateForPlaybackTime 的复刻。

    cue 按 startTime 升序；二分找最后一个 start <= target 的 candidate，
    再从 candidate 一路扫回第 0 条，收集全部覆盖 target 的 cue。
    """

    def __init__(self, cues):
        # cues: [(start, end, text)]，调用方保证按 start 升序。
        self.cues = list(cues)

    def active_at(self, target):
        candidate = -1
        lo, hi = 0, len(self.cues) - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            if self.cues[mid][0] <= target:
                candidate = mid
                lo = mid + 1
            else:
                hi = mid - 1
        active = []
        for i in range(candidate, -1, -1):
            start, end, text = self.cues[i]
            if start <= target <= end:
                active.insert(0, text)
        return active


class SubtitleLoadSession:
    """外挂字幕加载代际模型：每次 load/clear 递增；过期完成直接丢弃。"""

    def __init__(self):
        self.generation = 0
        self.cues = []
        self.completions = []

    def load_url(self, url):
        self.generation += 1
        return self.generation

    def load_text(self, text):
        self.generation += 1
        self.cues = [('text', text)]

    def clear(self):
        self.generation += 1
        self.cues = []

    def complete(self, generation, cues):
        if generation != self.generation:
            return False  # 过期完成：丢弃，不调 completion。
        self.cues = cues
        self.completions.append(generation)
        return True


def subtitle_network_acceptable(status, error, length):
    """网络字幕加载门禁：2xx、无错误、<=2 MiB 才解析。"""
    if error:
        return False
    if status < 200 or status >= 300:
        return False
    if not length or length > SUBTITLE_MAX_BYTES:
        return False
    return True


class TrackMenuSession:
    """轨道菜单会话守卫模型：构建时抓快照，点选时校验。"""

    def __init__(self, adapter_id, episode, line):
        self.built_adapter = adapter_id
        self.built_episode = episode
        self.built_line = line

    def action_allowed(self, adapter_id, episode, line):
        return (adapter_id == self.built_adapter
                and episode == self.built_episode
                and line == self.built_line)


class EngineTrackList:
    """adapter 轨道列表模型：selected 是 NSNumber BOOL（MPV 真实值）
    或字符串 'unknown'（Cicada 不暴露）。"""

    def __init__(self, tracks):
        # tracks: [(kind, index, name, selected)]
        self.tracks = list(tracks)

    def selection_known(self, kind):
        return any(t[0] == kind and isinstance(t[3], bool)
                   for t in self.tracks)

    def current_name(self, kind):
        for t in self.tracks:
            if t[0] == kind and t[3] is True:
                return t[2]
        return None

    def verify_selection(self, kind, index):
        for t in self.tracks:
            if t[0] == kind and t[1] == index:
                return t[3] is True
        return False

    def verify_off(self, kind):
        return not any(t[0] == kind and t[3] is True for t in self.tracks)


def mpv_select_result(index):
    """MPV selectTrackWithIndex 的返回值模型（含关闭哨兵）。"""
    if index == 0:
        return ('ok', 'aid', 'no')
    if index == 10000:
        return ('ok', 'sid', 'no')
    if index < 0:
        return ('no', None, None)
    prop = 'aid'
    if index >= 20000:
        prop, index = 'vid', index - 20000
    elif index >= 10000:
        prop, index = 'sid', index - 10000
    return ('ok', prop, index)


# -------------------------------------------------------------- 行为测试 ---

class TestSubtitleCueLookup(unittest.TestCase):
    def test_long_overlapping_cue_is_not_missed(self):
        # 早开始的长 cue（0–60 秒）+ 10 条短 cue 在其后开始；旧"最近 5 条"
        # 会漏掉长 cue，全扫不会。
        cues = [(0.0, 60.0, 'long')] + [
            (float(2 * i + 1), float(2 * i + 2), 'short%d' % i)
            for i in range(10)
        ]
        lookup = SubtitleCueLookup(cues)
        self.assertEqual(lookup.active_at(15.5), ['long', 'short7'])
        self.assertEqual(lookup.active_at(0.5), ['long'])
        self.assertEqual(lookup.active_at(61.0), [])

    def test_overlapping_cues_stay_in_start_order(self):
        cues = [(0.0, 10.0, 'a'), (2.0, 8.0, 'b'), (5.0, 12.0, 'c')]
        lookup = SubtitleCueLookup(cues)
        self.assertEqual(lookup.active_at(6.0), ['a', 'b', 'c'])
        self.assertEqual(lookup.active_at(9.0), ['a', 'c'])
        self.assertEqual(lookup.active_at(11.0), ['c'])

    def test_no_cue_before_start(self):
        lookup = SubtitleCueLookup([(10.0, 20.0, 'x')])
        self.assertEqual(lookup.active_at(5.0), [])


class TestSubtitleLoadGeneration(unittest.TestCase):
    def test_late_old_completion_does_not_overwrite_new_episode(self):
        s = SubtitleLoadSession()
        gen1 = s.load_url('ep1.srt')
        gen2 = s.load_url('ep2.srt')
        self.assertFalse(s.complete(gen1, [('old', 'ep1 cue')]))
        self.assertEqual(s.cues, [])
        self.assertTrue(s.complete(gen2, [('new', 'ep2 cue')]))
        self.assertEqual(s.cues, [('new', 'ep2 cue')])

    def test_clear_invalidates_in_flight_load(self):
        s = SubtitleLoadSession()
        gen = s.load_url('ep1.srt')
        s.clear()
        self.assertFalse(s.complete(gen, [('old', 'ep1 cue')]))
        self.assertEqual(s.cues, [])

    def test_load_text_invalidates_in_flight_url_load(self):
        s = SubtitleLoadSession()
        gen = s.load_url('ep1.srt')
        s.load_text('direct text')
        self.assertFalse(s.complete(gen, [('old', 'ep1 cue')]))
        self.assertEqual(s.cues, [('text', 'direct text')])


class TestSubtitleNetworkGate(unittest.TestCase):
    def test_non_2xx_or_error_or_oversize_is_rejected(self):
        self.assertFalse(subtitle_network_acceptable(404, False, 100))
        self.assertFalse(subtitle_network_acceptable(200, True, 100))
        self.assertFalse(subtitle_network_acceptable(200, False, 0))
        self.assertFalse(subtitle_network_acceptable(200, False,
                                                     SUBTITLE_MAX_BYTES + 1))
        self.assertFalse(subtitle_network_acceptable(500, False, 100))

    def test_ok_2xx_within_cap_is_accepted(self):
        self.assertTrue(subtitle_network_acceptable(200, False, 100))
        self.assertTrue(subtitle_network_acceptable(204, False,
                                                    SUBTITLE_MAX_BYTES))


class TestTrackMenuSessionGuard(unittest.TestCase):
    def test_same_session_action_allowed(self):
        m = TrackMenuSession('adapter-A', 3, 0)
        self.assertTrue(m.action_allowed('adapter-A', 3, 0))

    def test_episode_line_or_adapter_change_refuses_action(self):
        m = TrackMenuSession('adapter-A', 3, 0)
        self.assertFalse(m.action_allowed('adapter-A', 4, 0))  # 切集
        self.assertFalse(m.action_allowed('adapter-A', 3, 1))  # 换线
        self.assertFalse(m.action_allowed('adapter-B', 3, 0))  # 换引擎


class TestTrackSelectionVerification(unittest.TestCase):
    def test_mpv_selection_is_known_and_verifiable(self):
        tracks = EngineTrackList([
            ('audio', 1, '中文 · AAC', True),
            ('audio', 2, 'English · AAC', False),
            ('subtitle', 10001, '中文', False),
        ])
        self.assertTrue(tracks.selection_known('audio'))
        self.assertEqual(tracks.current_name('audio'), '中文 · AAC')
        self.assertIsNone(tracks.current_name('subtitle'))
        self.assertTrue(tracks.verify_selection('audio', 1))
        self.assertFalse(tracks.verify_selection('audio', 2))
        self.assertTrue(tracks.verify_off('subtitle'))

    def test_cicada_selection_is_unknown_and_never_verified(self):
        tracks = EngineTrackList([
            ('audio', 0, 'Audio 0', 'unknown'),
            ('audio', 1, 'Audio 1', 'unknown'),
        ])
        self.assertFalse(tracks.selection_known('audio'))
        self.assertIsNone(tracks.current_name('audio'))
        self.assertFalse(tracks.verify_selection('audio', 0))
        self.assertFalse(tracks.verify_selection('audio', 1))

    def test_mpv_off_sentinels(self):
        self.assertEqual(mpv_select_result(0), ('ok', 'aid', 'no'))
        self.assertEqual(mpv_select_result(10000), ('ok', 'sid', 'no'))
        self.assertEqual(mpv_select_result(-1), ('no', None, None))
        self.assertEqual(mpv_select_result(2), ('ok', 'aid', 2))
        self.assertEqual(mpv_select_result(10002), ('ok', 'sid', 2))
        self.assertEqual(mpv_select_result(20001), ('ok', 'vid', 1))


# -------------------------------------------------------------- 合同测试 ---

class TestTrackSubtitleContracts(unittest.TestCase):
    def setUp(self):
        self.protocol = read('CCTVPlaybackEngineProtocol.h')
        self.mpv = read('MediaPlaybackMPVAdapter.m')
        self.cicada = read('MediaPlaybackCicadaAdapter.m')
        self.coord = read('MediaPlaybackSettingsCoordinator.m')
        self.overlay = read('HostSubtitleOverlayView.m')

    def test_protocol_documents_track_dict_and_off_sentinels(self):
        self.assertIn('@"selected"', self.protocol)
        self.assertIn('@"unknown"', self.protocol)
        self.assertIn('index 0 = 关闭音频轨道', self.protocol)
        self.assertIn('index 10000 = 关闭字幕轨道', self.protocol)
        # 调用成功 ≠ 已切换：Cicada 只表示调用已发出。
        self.assertIn('只表示', self.protocol)

    def test_mpv_tracks_report_real_selected_state(self):
        self.assertIn('/selected', self.mpv)
        self.assertIn('MPV_FORMAT_FLAG', self.mpv)
        self.assertIn('@"selected": @(selectedFlag != 0)', self.mpv)

    def test_mpv_off_sentinels_disable_aid_sid(self):
        select = self.mpv[self.mpv.index('- (BOOL)selectTrackWithIndex:'):]
        self.assertIn('index == 0 || index == 10000', select[:1500])
        # T20：set_property_string 经受检 helper（mpvSetPropertyString）
        # 下发，哨兵语义不变（aid/sid 设 "no"）。
        self.assertIn('mpvSetPropertyString:ctx name:prop value:"no"', select[:1500])

    def test_cicada_tracks_report_selected_unknown(self):
        self.assertIn('@"selected":@"unknown"', self.cicada)
        select = self.cicada[self.cicada.index('- (BOOL)selectTrackWithIndex:'):]
        self.assertIn('无法重查验证实际切换', select[:1200])

    def test_coordinator_guards_stale_menu_actions(self):
        self.assertIn('menuSessionChangedSinceAdapter:', self.coord)
        self.assertIn('builtEpisode=owner.episodeIndex', self.coord)
        self.assertIn('builtLine=owner.lineIndex', self.coord)
        self.assertIn('refuseStaleMenuAction', self.coord)
        self.assertIn('已切换剧集或线路，菜单已过期', self.coord)
        # adapter 分支与 AV 分支都校验快照。
        self.assertIn('menuSessionChangedSinceAdapter:builtAdapter item:nil episode:builtEpisode line:builtLine',
                      self.coord)
        self.assertIn('menuSessionChangedSinceAdapter:nil item:builtItem episode:builtEpisode line:builtLine',
                      self.coord)

    def test_coordinator_marks_current_selection_and_offers_off(self):
        menu = self.coord[self.coord.index('mediaSelectionMenuForCharacteristic:'):]
        self.assertIn('isCurrent=[track[@"selected"] isEqual:@(YES)]', menu[:12000])
        self.assertIn('trackAct.state=isCurrent?UIMenuElementStateOn:UIMenuElementStateOff',
                      menu[:12000])
        self.assertIn('actionWithTitle:@"关闭"', menu[:12000])
        self.assertIn('selectionKnown', menu[:12000])
        self.assertIn('选中状态未确认', menu[:12000])
        # 切换后重查验证，结果进诊断事件。
        self.assertIn('verifyTrackSelectionForAdapter:', menu[:12000])
        self.assertIn('verifyTrackOffForAdapter:', menu[:12000])
        self.assertIn('@"selection_verified"', menu[:12000])
        self.assertIn('已发送切换请求，尚未确认是否切换', menu[:12000])

    def test_external_subtitle_menu_is_gated_by_engine(self):
        menu = self.coord[self.coord.index('- (UIMenu *)externalSubtitleMenu {'):]
        self.assertIn('MPV 字幕由内核渲染，请用字幕菜单切换', menu[:3000])
        self.assertIn('Cicada 暂不支持外挂字幕', menu[:3000])
        self.assertIn('UIMenuElementAttributesDisabled', menu[:3000])
        # 标识符保持不变（VC 有断言）。
        self.assertIn('@"media.playback.menu.extsub"', menu[:3000])
        # AV 路径保留完整调节项，并标注仅纯文本。
        self.assertIn('仅显示纯文本（复杂样式已去除）', menu)

    def test_overlay_load_generation_guards_late_completions(self):
        self.assertIn('loadGeneration', self.overlay)
        self.assertIn('self.loadGeneration += 1;', self.overlay)
        self.assertIn('owner.loadGeneration != generation', self.overlay)
        # clear 与直接加载文本同样使在途请求失效。
        clear = self.overlay[self.overlay.index('- (void)clearSubtitles {'):]
        self.assertIn('self.loadGeneration += 1;', clear[:600])

    def test_overlay_network_gate_and_size_cap(self):
        self.assertIn('HostSubtitleMaxBytes = 2 * 1024 * 1024', self.overlay)
        self.assertIn('data.length <= HostSubtitleMaxBytes', self.overlay)
        self.assertIn('http.statusCode >= 200 && http.statusCode < 300', self.overlay)
        self.assertIn('NSFileSize', self.overlay)

    def test_overlay_overlap_scan_is_not_limited_to_nearest_five(self):
        self.assertNotIn('candidate - 4', self.overlay)
        update = self.overlay[self.overlay.index('- (void)updateForPlaybackTime:'):]
        self.assertIn('for (NSInteger i = candidate; i >= 0; i--)', update[:2000])

    def test_rate_menu_still_gated_by_engine_capability(self):
        rate = self.coord[self.coord.index('- (nullable UIMenu *)playbackRateMenu {'):]
        self.assertIn('BOOL supportsRate=[owner activeEngineSupportsRateWriting];',
                      rate[:800])
        self.assertIn("if(!supportsRate){owner.playbackSpeedButton.menu=nil;return nil;}",
                      rate[:800])


if __name__ == '__main__':
    unittest.main()
