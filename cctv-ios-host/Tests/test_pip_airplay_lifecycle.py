"""T10 PiP、AirPlay 与系统生命周期（F1）。

审计 ID：F1（AV PiP / MPV PiP / 投屏 / 直播回看）；方案 §10.2 验收
A07（PiP 起停/回页面/后台锁屏/AirPlay 连接断开/输出受限）、A13（电话/
耳机断开/媒体服务重置/前后台/切换 owner）、A14（输出策略）。

两类测试：
- 行为测试：按 ObjC 实现逐条复刻的 Python 模型（MPV PiP 能力、AirPlay
  音频/视频状态机、PlaybackCoordinator 中断/路由/重置 owner 规则）。
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


# ---------------------------------------------------------------- 模型 ---

class MPVPipModel:
    """MPV adapter 的 PiP 模型（T10 后）：无视频供帧，故不支持 PiP；
    start 是 no-op，不建空窗；stop 是 no-op。"""

    def __init__(self):
        self.controller_created = False

    def is_supported(self):
        return False

    def start(self):
        return False  # 不启动，不创建 controller。

    def stop(self):
        return False

    def is_active(self):
        return False


class AirPlayUIModel:
    """handleAudioRouteChange 的状态机复刻（T10 后）。

    video 只认 AVPlayer.externalPlaybackActive；仅音频路由不得显示
    "投屏中"/"正在投屏至"。
    """

    def __init__(self, audio_route_name=None, external_playback_active=False,
                 has_av_player=False, has_current_player=False,
                 has_channel=False, switch_route_ok=True):
        self.audio_route_name = audio_route_name
        self.external = external_playback_active
        self.has_av_player = has_av_player
        self.has_current_player = has_current_player
        self.has_channel = has_channel
        self.switch_route_ok = switch_route_ok

    def render(self):
        is_airplay = bool(self.audio_route_name)
        is_video = self.has_av_player and self.external
        title = '投屏中' if is_video else '投屏'
        info = None
        if (is_airplay and self.has_current_player and not self.has_av_player
                and self.has_channel):
            if not self.switch_route_ok:
                info = '📺 已连接 %s · 加密频道建议使用系统「屏幕镜像」' % self.audio_route_name
        elif is_video:
            info = '📺 正在投屏至 %s' % self.audio_route_name
        elif is_airplay:
            info = '🔊 音频已连接至 %s，视频仍在本机播放' % self.audio_route_name
        return title, info


class PlaybackCoordinatorModel:
    """PlaybackCoordinator 中断/路由/重置的 owner 规则复刻。

    恢复只在：中断结束 + 中断前想播 + 被中断的 session 仍是当前
    session + 系统带 ShouldResume。换 session 清除中断状态。
    """

    def __init__(self):
        self.current = None
        self.interrupted = None
        self.resume_after = False
        self.playing = {}

    def acquire(self, session):
        if self.current == session:
            return
        if self.current is not None:
            self.playing[self.current] = False
        self.current = session
        self.interrupted = None
        self.resume_after = False

    def interruption_began(self):
        self.interrupted = self.current
        self.resume_after = bool(self.playing.get(self.current, False))
        if self.current is not None:
            self.playing[self.current] = False

    def interruption_ended(self, should_resume):
        resume = (self.resume_after and self.interrupted == self.current
                  and should_resume)
        self.resume_after = False
        self.interrupted = None
        if resume and self.current is not None:
            self.playing[self.current] = True
        return resume

    def route_old_device_unavailable(self):
        # 耳机拔出：暂停，不自动恢复（不置 resume 标志）。
        if self.current is not None:
            self.playing[self.current] = False
        return False

    def media_reset(self):
        self.resume_after = False
        if self.current is not None:
            self.playing[self.current] = False
        return False


# -------------------------------------------------------------- 行为测试 ---

class TestMPVPipModel(unittest.TestCase):
    def test_mpv_pip_is_not_supported_without_frame_supply(self):
        m = MPVPipModel()
        self.assertFalse(m.is_supported())
        self.assertFalse(m.start())
        self.assertFalse(m.controller_created)
        self.assertFalse(m.is_active())
        self.assertFalse(m.stop())


class TestAirPlayUIModel(unittest.TestCase):
    def test_audio_only_route_is_not_video_cast(self):
        # 音频路由到 AirPlay 音箱/电视，视频未外放：按钮不是"投屏中"，
        # 文案明确说视频仍在本机。
        m = AirPlayUIModel(audio_route_name='客厅 HomePod',
                           external_playback_active=False,
                           has_av_player=True)
        title, info = m.render()
        self.assertEqual(title, '投屏')
        self.assertEqual(info, '🔊 音频已连接至 客厅 HomePod，视频仍在本机播放')

    def test_video_external_playback_is_casting(self):
        m = AirPlayUIModel(audio_route_name='客厅 Apple TV',
                           external_playback_active=True,
                           has_av_player=True)
        title, info = m.render()
        self.assertEqual(title, '投屏中')
        self.assertEqual(info, '📺 正在投屏至 客厅 Apple TV')

    def test_no_route_shows_plain_cast_button(self):
        m = AirPlayUIModel()
        title, info = m.render()
        self.assertEqual(title, '投屏')
        self.assertIsNone(info)

    def test_av_player_without_external_playback_is_not_casting(self):
        # 有 AV 播放器但 externalPlaybackActive 为 NO：不是投屏。
        m = AirPlayUIModel(audio_route_name='卧室 Apple TV',
                           external_playback_active=False,
                           has_av_player=True)
        title, info = m.render()
        self.assertEqual(title, '投屏')
        self.assertIn('视频仍在本机播放', info)

    def test_non_av_engine_with_audio_route_tries_compatible_route(self):
        m = AirPlayUIModel(audio_route_name='客厅 Apple TV',
                           external_playback_active=False,
                           has_av_player=False, has_current_player=True,
                           has_channel=True, switch_route_ok=False)
        title, info = m.render()
        self.assertEqual(title, '投屏')
        self.assertIn('已连接 客厅 Apple TV', info)
        self.assertIn('屏幕镜像', info)


class TestPlaybackCoordinatorModel(unittest.TestCase):
    def test_interruption_resumes_only_for_same_owner_with_should_resume(self):
        c = PlaybackCoordinatorModel()
        c.acquire('live')
        c.playing['live'] = True
        c.interruption_began()
        self.assertFalse(c.playing['live'])
        self.assertTrue(c.interruption_ended(should_resume=True))
        self.assertTrue(c.playing['live'])

    def test_interruption_does_not_resume_without_should_resume(self):
        c = PlaybackCoordinatorModel()
        c.acquire('live')
        c.playing['live'] = True
        c.interruption_began()
        self.assertFalse(c.interruption_ended(should_resume=False))
        self.assertFalse(c.playing['live'])

    def test_interruption_does_not_resume_after_owner_switch(self):
        c = PlaybackCoordinatorModel()
        c.acquire('live')
        c.playing['live'] = True
        c.interruption_began()
        c.acquire('vod')  # 中断期间切了 owner：旧 owner 不抢占。
        self.assertFalse(c.interruption_ended(should_resume=True))
        self.assertFalse(c.playing.get('live', False))

    def test_interruption_does_not_resume_when_not_playing_before(self):
        c = PlaybackCoordinatorModel()
        c.acquire('live')
        c.playing['live'] = False  # 中断前已暂停：不自动恢复。
        c.interruption_began()
        self.assertFalse(c.interruption_ended(should_resume=True))

    def test_headphone_unplug_pauses_without_resume(self):
        c = PlaybackCoordinatorModel()
        c.acquire('live')
        c.playing['live'] = True
        self.assertFalse(c.route_old_device_unavailable())
        self.assertFalse(c.playing['live'])

    def test_media_reset_pauses_without_resume(self):
        c = PlaybackCoordinatorModel()
        c.acquire('live')
        c.playing['live'] = True
        self.assertFalse(c.media_reset())
        self.assertFalse(c.playing['live'])


# -------------------------------------------------------------- 合同测试 ---

class TestPipAirPlayLifecycleContracts(unittest.TestCase):
    def setUp(self):
        self.protocol = read('CCTVPlaybackEngineProtocol.h')
        self.mpv = read('MediaPlaybackMPVAdapter.m')
        self.playback = read('RootViewController+Playback.m')
        self.root = read('RootViewController.m')
        self.coord = read('PlaybackCoordinator.m')
        self.vc = read('MediaPlaybackViewController.m')

    def test_mpv_pip_is_marked_not_implemented(self):
        support = self.mpv[self.mpv.index('- (BOOL)isPictureInPictureSupported {'):]
        self.assertIn('return NO;', support[:400])
        start = self.mpv[self.mpv.index('- (void)startPictureInPicture {'):]
        # start 是 no-op：不建 sample-buffer layer、不建 controller、不启动。
        self.assertNotIn('AVSampleBufferDisplayLayer new', start[:800])
        self.assertNotIn('AVPictureInPictureControllerContentSource', start[:800])
        self.assertNotIn('startPictureInPicture]', start[:800])
        # 桥骨架保留给 T24（属性与 delegate 方法仍在）。
        self.assertIn('AVSampleBufferDisplayLayer', self.mpv)
        self.assertIn('pictureInPictureController:', self.mpv)

    def test_protocol_documents_pip_honesty(self):
        self.assertIn('MPV 返回 NO', self.protocol)
        self.assertIn('T24', self.protocol)

    def test_airplay_video_requires_external_playback_active(self):
        handler = self.playback[self.playback.index(
            '- (void)handleAudioRouteChange:'):]
        self.assertIn('isAirPlayVideo = self.avPlayer && self.avPlayer.isExternalPlaybackActive',
                      handler[:2500])
        self.assertIn('setTitle:isAirPlayVideo ? @"投屏中" : @"投屏"',
                      handler[:2500])
        self.assertIn('} else if (isAirPlayVideo) {', handler[:2500])
        self.assertIn('正在投屏至 %@', handler[:2500])
        # 仅音频路由有明确文案，不再冒充视频投屏。
        self.assertIn('音频已连接至 %@，视频仍在本机播放', handler[:2500])
        # 旧的冒充条件必须消失：仅音频路由 + avPlayer 存在不得报"正在投屏"。
        self.assertNotIn('} else if (isAirPlay && self.avPlayer) {', handler[:2500])

    def test_live_pip_stays_av_layer_only(self):
        self.assertIn('BOOL pipAvailable = (self.avLayer && AVPictureInPictureController.isPictureInPictureSupported);',
                      self.playback)

    def test_av_pip_uses_system_player_controller(self):
        self.assertIn('allowsPictureInPicturePlayback=YES', self.vc)

    def test_interruption_resumes_only_for_same_owner(self):
        intr = self.coord[self.coord.index('- (void)interruption:'):]
        self.assertIn('self.interruptedSession=self.currentSession', intr[:1500])
        self.assertIn('self.interruptedSession==self.currentSession', intr[:1500])
        self.assertIn('AVAudioSessionInterruptionOptionShouldResume', intr[:1500])

    def test_route_change_only_pauses_on_old_device_unavailable(self):
        route = self.coord[self.coord.index('- (void)routeChanged:'):]
        self.assertIn('AVAudioSessionRouteChangeReasonOldDeviceUnavailable', route[:800])
        self.assertIn('[self pause]', route[:800])

    def test_media_reset_clears_resume_flag(self):
        reset = self.coord[self.coord.index('- (void)mediaReset:'):]
        self.assertIn('self.resumeAfterInterruption=NO;', reset[:800])
        self.assertIn('sessionMediaServicesReset', reset[:800])

    def test_acquire_session_pauses_previous_owner(self):
        acquire = self.coord[self.coord.index('- (void)acquireSession:'):]
        self.assertIn('[self.currentSession sessionPause]', acquire[:800])
        self.assertIn('self.interruptedSession=nil;self.resumeAfterInterruption=NO;',
                      acquire[:800])


if __name__ == '__main__':
    unittest.main()
