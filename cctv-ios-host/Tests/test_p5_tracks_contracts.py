"""P5 源码契约：音轨/字幕选择与倍速档位（iOS SDK 不可用，做静态源码核对）。

覆盖：
  - 倍速档位统一为 0.5 / 0.75 / 1 / 1.25 / 1.5 / 2 / 3，调用方钳制到 3.0；
  - 引擎不支持写倍速时隐藏倍速子菜单（activeEngineSupportsRateWriting）；
  - 音轨/字幕子菜单对当前引擎经 respondsToSelector 安全调用协议 @optional
    轨道接口，无轨道时不显示（返回 nil，不再渲染禁用占位项）；
  - AVPlayer 路径用 AVMediaSelectionGroup 实现同等能力；
  - 选择后经 RuntimeDiagnostics 写诊断事件；
  - 现有 accessibilityIdentifier 不变，且类扩展不重复声明公开 readwrite 的 rate
    （CI #615 回归护栏）。
"""
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / 'Sources'


def read(name):
    return (SOURCES / name).read_text(encoding='utf-8')


class P5TracksContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.playback = read('MediaPlaybackViewController.m')
        cls.protocol = read('CCTVPlaybackEngineProtocol.h')
        cls.cicada_h = read('MediaPlaybackCicadaAdapter.h')
        cls.cicada_m = read('MediaPlaybackCicadaAdapter.m')
        cls.mpv_h = read('MediaPlaybackMPVAdapter.h')
        cls.mpv_m = read('MediaPlaybackMPVAdapter.m')

    # ---- 倍速档位 ----
    def test_rate_gears_are_unified_seven_steps_with_three_x(self):
        mp = self.playback
        m = re.search(r'NSArray<NSNumber \*> \*rates=@\[([^\]]*)\];', mp)
        self.assertIsNotNone(m, 'playback rate gear list literal not found')
        rates = [float(x) for x in re.findall(r'@([0-9.]+)', m.group(1))]
        self.assertEqual(rates, [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
        self.assertNotIn(1.75, rates, 'legacy 1.75x gear must be removed')
        self.assertIn(3.0, rates, '3.0x gear must be present')

    def test_setPlayback_rate_clamps_to_three_not_two(self):
        mp = self.playback
        # The persistent rate set by the settings menu may now reach 3.0x.
        self.assertIn('rate=MIN(3.0,MAX(0.5,rate))', mp)
        self.assertNotIn('rate=MIN(2.0,MAX(0.5,rate))', mp)

    def test_rate_menu_hidden_when_engine_cannot_write_rate(self):
        mp = self.playback
        self.assertIn('- (BOOL)activeEngineSupportsRateWriting', mp)
        body = mp.split('- (BOOL)activeEngineSupportsRateWriting {', 1)[1]
        body = body.split('\n}\n', 1)[0]
        # Adapter path must guard with respondsToSelector(setRate:); AVPlayer path
        # is always writable.
        self.assertIn('respondsToSelector:@selector(setRate:)]', body)
        self.assertIn('return YES;', body)
        # Both menu construction and the standalone speed-menu provider guard
        # unsupported engines (speed button menu is rebuilt through this method).
        self.assertIn('if([self activeEngineSupportsRateWriting])', mp)
        self.assertIn('BOOL supportsRate=[self activeEngineSupportsRateWriting];', mp)
        self.assertIn('if(!supportsRate){self.playbackSpeedButton.menu=nil;return nil;}', mp)

    def test_speed_button_identifier_preserved(self):
        mp = self.playback
        self.assertIn('@"media-playback-speed"', mp)

    # ---- 音轨 / 字幕子菜单 ----
    def test_track_menu_uses_respondsToSelector_on_optional_protocol_members(self):
        mp = self.playback
        # availableTracks / canSelectTracks / selectTrackWithIndex: are @optional.
        self.assertIn('[adapter respondsToSelector:@selector(availableTracks)]', mp)
        self.assertIn('[adapter respondsToSelector:@selector(canSelectTracks)]', mp)
        self.assertIn('if(!canSelect)return nil;', mp)
        self.assertIn('[current respondsToSelector:@selector(selectTrackWithIndex:)]', mp)
        # The active engine adapter is treated through the protocol, so the MPV
        # adapter (stored in the same property) is covered too.
        self.assertIn('id<CCTVPlaybackEngine> adapter=(id<CCTVPlaybackEngine>)self.cicadaAdapter', mp)

    def test_track_menu_hidden_when_no_tracks(self):
        mp = self.playback
        # returning nil hides the sub-menu; the old disabled placeholders are gone.
        self.assertIn('if(!actions.count)return nil;', mp)
        self.assertIn('if(!group.options.count)return nil;', mp)
        self.assertNotIn('当前引擎暂不支持轨道选择', mp)
        self.assertNotIn('当前引擎尚未返回可选轨道', mp)
        # The track menus must not surface a "无可用轨道" placeholder (danmaku is unrelated).
        menu = mp.split('- (nullable UIMenu *)mediaSelectionMenuForCharacteristic', 1)[1]
        menu = menu.split('\n- (UIMenu *)playbackRateMenu', 1)[0]
        self.assertNotIn('无可用轨道', menu)

    def test_track_menus_wired_into_av_group_with_characteristics(self):
        mp = self.playback
        self.assertIn('AVMediaCharacteristicLegible title:@"字幕"', mp)
        self.assertIn('AVMediaCharacteristicAudible title:@"音轨"', mp)
        # The av group is now built from a mutable children array that skips nil.
        self.assertIn('NSMutableArray<UIMenuElement *> *avChildren', mp)
        self.assertIn('if(subtitleMenu)[avChildren insertObject:subtitleMenu atIndex:1];', mp)
        self.assertIn('if(audioMenu)[avChildren insertObject:audioMenu atIndex:avChildren.count-1];', mp)

    def test_avplayer_path_uses_media_selection_group(self):
        mp = self.playback
        self.assertIn('mediaSelectionGroupForMediaCharacteristic:characteristic', mp)
        self.assertIn('selectMediaOption:nil inMediaSelectionGroup:currentGroup', mp)
        self.assertIn('selectMediaOption:option inMediaSelectionGroup:currentGroup', mp)

    # ---- 诊断事件 ----
    def test_track_and_rate_selection_record_diagnostics(self):
        mp = self.playback
        self.assertIn('recordEvent:@"playback_track_selected" category:@"playback"', mp)
        self.assertIn('recordEvent:@"playback_rate_selected" category:@"playback"', mp)
        # Track event carries the kind + selection outcome fields.
        track_event = mp.split('@"playback_track_selected"', 1)[1].split('}];', 1)[0]
        self.assertIn('"track_kind"', track_event)
        self.assertIn('"selection_succeeded"', track_event)
        # Rate event carries the resolved rate + engine tag.
        rate_event = mp.split('@"playback_rate_selected"', 1)[1].split('}];', 1)[0]
        self.assertIn('"rate"', rate_event)
        self.assertIn('"engine"', rate_event)

    def test_protocol_keeps_track_and_rate_members_optional(self):
        proto = self.protocol
        optional = proto[proto.index('@optional'):]
        for sel in ('rate', 'availableTracks', 'canSelectTracks', 'selectTrackWithIndex:'):
            self.assertIn(sel, optional)

    def test_view_controller_extension_does_not_redeclare_readwrite_rate(self):
        # CI #615: a class extension must not redeclare a readwrite property that
        # the public header already declares readwrite. Applies to the VC too.
        src = self.playback
        ext = src.split('@interface MediaPlaybackViewController ()', 1)[1].split('@end', 1)[0]
        self.assertNotIn('@property (nonatomic) float rate;', ext)

    def test_adapter_rate_clamps_allow_three_x(self):
        # Both adapters must accept 3.0x (long-press gesture + new 3.0 gear).
        self.assertIn('MIN(3.0f, MAX(0.5f, rate))', self.cicada_m)
        self.assertIn('MIN(3.0f, MAX(0.5f, isfinite(rate) ? rate : 1.0f))', self.mpv_m)

    def test_objc_edits_keep_balanced_delimiters(self):
        # Only headers carry the delimiter guarantee (large .m files contain
        # brace/paren literals inside NSString constants that break naive counts).
        # Comments are stripped first; @property/@selector lines are balanced.
        for name in ('MediaPlaybackCicadaAdapter.h',):
            text = read(name)
            code = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
            self.assertEqual(code.count('{'), code.count('}'), name + ' braces')
            self.assertEqual(code.count('('), code.count(')'), name + ' parens')


if __name__ == '__main__':
    unittest.main()
