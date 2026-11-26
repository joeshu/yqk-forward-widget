"""T08 真实首帧 / seek / 恢复（S2/S3/S5）。

审计 ID：S2（首帧证据）、S3（seek/恢复）、S5（缓冲/统计）；方案 §10.2
验收 A01（首帧真实性）、A07（seek 误差 <=1s / P95 <=1s）、A10（缓冲语义）。

两类测试：
- 行为测试：按 ObjC 实现逐条复刻的状态机（Python 模型），验证状态转移
  与"一次且仅一次"通知——不依赖源码字符串。
- 合同测试：源码接线断言，锁住 ObjC 实现与本文件模型一致的关键点。
"""
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, 'Sources')


def read(name):
    with open(os.path.join(SRC, name), encoding='utf-8') as fh:
        return fh.read()


FIRST_FRAME_TIMEOUT = 20.0
SEEK_TIMEOUT = 3.0
AUDIO_ONLY_THRESHOLD = 1.0
SEEK_TOLERANCE = 1.0


class MPVFirstFrameSeekModel:
    """MediaPlaybackMPVAdapter 首帧/seek 状态机的 Python 复刻。

    与 ObjC 实现逐条对应：prepare 末尾 arm 20 秒预算；pause 冻结预算、
    start 按剩余重 arm；重启与 time-pos 只有观测到视频轨道才报视频首帧；
    无视频轨道且 time-pos 超过 1.0 秒报纯音频；seek 有独立 id + 目标 +
    3 秒 deadline，落点在目标 ±1.0 秒内才完成一次。
    """

    def __init__(self):
        self.now = 0.0
        self.destroyed = False
        self.prepared = False
        self.first_frame_reported = False
        self.audio_only_notified = False
        self.first_frame_remaining = FIRST_FRAME_TIMEOUT
        self._budget_started = None
        self._watchdog_armed = False
        self.has_video_track = False
        self.current_position = 0.0
        self._seek_id = 0
        self._pending_seek = None  # (seek_id, target)
        self.seek_results = []     # (seek_id, finished)，按完成顺序
        self.did_seek_calls = 0
        self.first_frame_calls = 0
        self.audio_only_calls = 0
        self.failures = []

    # -- 生命周期 ------------------------------------------------------
    def prepare(self):
        self.prepared = True
        self.first_frame_reported = False
        self.audio_only_notified = False
        self.first_frame_remaining = FIRST_FRAME_TIMEOUT
        self._pending_seek = None
        self._arm_watchdog()

    def start(self):
        if self.destroyed:
            return
        if self.prepared:
            self._arm_watchdog()

    def pause(self):
        if self.destroyed:
            return
        if self._watchdog_armed:
            self.first_frame_remaining = max(
                0.0, self.first_frame_remaining - (self.now - self._budget_started))
            self._watchdog_armed = False
            self._budget_started = None

    def stop(self):
        self._finish_pending_seek(False)

    def destroy(self):
        self.destroyed = True
        self._watchdog_armed = False
        self._finish_pending_seek(False)

    def fail(self, code):
        self.failures.append(code)
        self._watchdog_armed = False
        self._finish_pending_seek(False)

    # -- 事件 ----------------------------------------------------------
    def video_geometry(self, width, height):
        if width > 0 and height > 0:
            self.has_video_track = True

    def restart(self):
        # PLAYBACK_RESTART：只证明解码器恢复输出，不证明视频画面。
        if self.has_video_track:
            self._report_first_frame()
        self._maybe_complete_seek()

    def time_pos(self, pos):
        if pos < 0:
            return
        self.current_position = pos
        if (not self.first_frame_reported and self.has_video_track
                and pos > 0.05):
            self._report_first_frame()
        elif (not self.first_frame_reported and not self.audio_only_notified
                and not self.has_video_track and pos > AUDIO_ONLY_THRESHOLD):
            self._report_audio_only()
        self._maybe_complete_seek()

    def seek(self, target):
        self._finish_pending_seek(False)
        self._seek_id += 1
        self._pending_seek = (self._seek_id, max(0.0, target),
                              self.now + SEEK_TIMEOUT)
        return self._seek_id

    def advance(self, seconds):
        """虚拟时钟前进，触发到期的 watchdog 与 seek 超时。"""
        deadline = self.now + seconds
        while True:
            nxt = None
            if self._watchdog_armed:
                nxt = self._budget_started + self.first_frame_remaining
            if self._pending_seek is not None:
                t = self._pending_seek[2]
                nxt = t if nxt is None else min(nxt, t)
            if nxt is None or nxt > deadline:
                break
            self.now = nxt
            if (self._watchdog_armed
                    and self.now >= self._budget_started + self.first_frame_remaining):
                self._watchdog_armed = False
                self._watchdog_timeout()
            if (self._pending_seek is not None
                    and self.now >= self._pending_seek[2]):
                self._finish_pending_seek(False)
        self.now = deadline

    # -- 内部 ----------------------------------------------------------
    def _arm_watchdog(self):
        if (self._watchdog_armed or self.first_frame_reported
                or self.audio_only_notified or self.destroyed):
            return
        self._watchdog_armed = True
        self._budget_started = self.now

    def _watchdog_timeout(self):
        if self.destroyed or self.first_frame_reported or self.audio_only_notified:
            return
        self.fail(-1008)

    def _report_first_frame(self):
        if self.destroyed or self.first_frame_reported:
            return
        self.first_frame_reported = True
        self.first_frame_calls += 1
        self._watchdog_armed = False

    def _report_audio_only(self):
        if (self.destroyed or self.first_frame_reported
                or self.audio_only_notified):
            return
        self.audio_only_notified = True
        self.audio_only_calls += 1
        self._watchdog_armed = False

    def _maybe_complete_seek(self):
        if self._pending_seek is None:
            return
        seek_id, target, _deadline = self._pending_seek
        if abs(self.current_position - target) <= SEEK_TOLERANCE:
            self._finish_pending_seek(True)

    def _finish_pending_seek(self, finished):
        if self._pending_seek is None:
            return
        seek_id, _target, _deadline = self._pending_seek
        self._pending_seek = None
        self.seek_results.append((seek_id, finished))
        if finished:
            self.did_seek_calls += 1


def buffered_ahead(buffered_position, current_position):
    """S5：ahead = MAX(0, bufferedPosition - currentPosition)。"""
    return max(0.0, buffered_position - current_position)


class TestRealFirstFrameBehavior(unittest.TestCase):
    def test_restart_without_video_track_is_not_a_video_first_frame(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.time_pos(0.5)
        m.restart()
        self.assertEqual(m.first_frame_calls, 0)
        self.assertFalse(m.first_frame_reported)

    def test_time_pos_advance_without_video_track_is_not_a_video_first_frame(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.time_pos(0.06)
        m.time_pos(0.9)
        self.assertEqual(m.first_frame_calls, 0)

    def test_audio_only_declared_after_one_second_without_video_track(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.time_pos(0.9)
        self.assertEqual(m.audio_only_calls, 0)
        m.time_pos(1.5)
        self.assertEqual(m.audio_only_calls, 1)
        self.assertTrue(m.audio_only_notified)
        self.assertFalse(m.first_frame_reported)
        # 只报一次；且纯音频取消首帧预算（不再超时失败）。
        m.time_pos(2.5)
        m.advance(30.0)
        self.assertEqual(m.audio_only_calls, 1)
        self.assertEqual(m.failures, [])

    def test_video_frame_after_audio_only_still_reports_first_frame(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.time_pos(1.5)
        self.assertEqual(m.audio_only_calls, 1)
        m.video_geometry(1920, 1080)
        m.restart()
        self.assertEqual(m.first_frame_calls, 1)
        self.assertTrue(m.first_frame_reported)

    def test_video_geometry_then_restart_reports_first_frame(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.video_geometry(1280, 720)
        m.restart()
        self.assertEqual(m.first_frame_calls, 1)

    def test_pause_freezes_first_frame_budget(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.advance(5.0)
        m.pause()
        # 暂停 100 秒不计预算。
        m.advance(100.0)
        self.assertEqual(m.failures, [])
        m.start()
        # 剩余 15 秒：14 秒后仍未超时，15 秒后超时。
        m.advance(14.0)
        self.assertEqual(m.failures, [])
        m.advance(1.0)
        self.assertEqual(m.failures, [-1008])

    def test_pause_before_prepare_does_not_arm_budget(self):
        m = MPVFirstFrameSeekModel()
        m.start()
        m.advance(25.0)
        self.assertEqual(m.failures, [])

    def test_seek_completes_only_when_landing_near_target(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        m.video_geometry(1920, 1080)
        seek_id = m.seek(30.0)
        m.current_position = 10.0
        m.restart()  # 落点 10，离目标 30 太远：不完成。
        self.assertEqual(m.seek_results, [])
        m.time_pos(29.5)  # 落在 30 ± 1 内：完成一次。
        self.assertEqual(m.seek_results, [(seek_id, True)])
        self.assertEqual(m.did_seek_calls, 1)

    def test_seek_timeout_completes_no_once(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        seek_id = m.seek(30.0)
        m.advance(3.0)
        self.assertEqual(m.seek_results, [(seek_id, False)])
        self.assertEqual(m.did_seek_calls, 0)
        m.advance(10.0)
        self.assertEqual(m.seek_results, [(seek_id, False)])

    def test_new_seek_supersedes_old_with_no_once(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        old = m.seek(30.0)
        new = m.seek(60.0)
        self.assertEqual(m.seek_results, [(old, False)])
        m.time_pos(60.2)
        self.assertEqual(m.seek_results, [(old, False), (new, True)])
        self.assertEqual(m.did_seek_calls, 1)

    def test_stop_completes_pending_seek_no_once(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        seek_id = m.seek(30.0)
        m.stop()
        m.stop()
        self.assertEqual(m.seek_results, [(seek_id, False)])
        self.assertEqual(m.did_seek_calls, 0)

    def test_destroy_and_failure_complete_pending_seek_no_once(self):
        m = MPVFirstFrameSeekModel()
        m.prepare()
        seek_id = m.seek(30.0)
        m.destroy()
        m.advance(10.0)
        self.assertEqual(m.seek_results, [(seek_id, False)])
        m2 = MPVFirstFrameSeekModel()
        m2.prepare()
        seek_id2 = m2.seek(30.0)
        m2.fail(-1002)
        self.assertEqual(m2.seek_results, [(seek_id2, False)])

    def test_buffered_ahead_is_clamped_at_zero(self):
        self.assertEqual(buffered_ahead(120.0, 100.0), 20.0)
        self.assertEqual(buffered_ahead(90.0, 100.0), 0.0)
        self.assertEqual(buffered_ahead(100.0, 100.0), 0.0)


class TestStatisticsContract(unittest.TestCase):
    def test_statistics_keys_are_the_documented_set(self):
        keys = {'engine', 'hwdec', 'videoBitrate', 'audioBitrate', 'fps',
                'droppedFrames', 'cacheSeconds', 'bufferedPosition',
                'bufferedAheadSeconds', 'currentPosition', 'duration',
                'state', 'stallCount'}
        # 协议头写明的键契约必须与两 adapter 返回的键一致。
        protocol = read('CCTVPlaybackEngineProtocol.h')
        for key in keys:
            self.assertIn('@' + '"' + key + '"', protocol, key)
        for name in ('MediaPlaybackMPVAdapter.m',
                     'MediaPlaybackCicadaAdapter.m'):
            body = read(name)
            stats = body[body.index('playbackStatistics'):]
            for key in keys:
                self.assertIn('@' + '"' + key + '"', stats[:6000],
                              '%s missing %s' % (name, key))

    def test_statistics_never_fabricates_unknown_values(self):
        # 未暴露的项必须是字符串 @"unknown"，不是 0 / -1 / nil。
        for name in ('MediaPlaybackMPVAdapter.m',
                     'MediaPlaybackCicadaAdapter.m'):
            body = read(name)
            stats = body[body.index('playbackStatistics'):]
            self.assertIn('@"unknown"', stats[:6000], name)
            self.assertNotIn('return @{};', stats[:2000], name)


class TestRealFirstFrameContracts(unittest.TestCase):
    def setUp(self):
        self.mpv = read('MediaPlaybackMPVAdapter.m')
        self.cicada = read('MediaPlaybackCicadaAdapter.m')
        self.types = read('CCTVPlaybackEngineTypes.h')
        self.vc = read('MediaPlaybackViewController.m')

    def test_mpv_first_frame_budget_is_pause_aware(self):
        self.assertIn('firstFrameRemaining', self.mpv)
        self.assertIn('firstFrameBudgetStarted', self.mpv)
        # pause 冻结预算：剩余 = 剩余 - (now - started)，并取消计时器。
        pause = self.mpv[self.mpv.index('- (void)pause {'):]
        self.assertIn('firstFrameRemaining = MAX(0, self.firstFrameRemaining - (CACurrentMediaTime() - self.firstFrameBudgetStarted))',
                      pause[:1200])
        self.assertIn('cancelFirstFrameWatchdog', pause[:1200])
        # start 按剩余预算重 arm；prepare 未完成时不 arm。
        start = self.mpv[self.mpv.index('- (void)start {'):]
        self.assertIn('if (self.preparedNotified) [self armFirstFrameWatchdog];',
                      start[:800])
        # arm 是带剩余预算的一次性 arm，不是无条件取消重建。
        arm = self.mpv[self.mpv.index('- (void)armFirstFrameWatchdog {'):]
        self.assertIn('MAX(0.01, self.firstFrameRemaining)', arm[:1200])
        self.assertIn('self.firstFrameWatchdog || self.firstFrameNotified || self.audioOnlyNotified',
                      arm[:1200])

    def test_mpv_restart_and_time_pos_require_a_video_track(self):
        restart = self.mpv[self.mpv.index('case MPV_EVENT_PLAYBACK_RESTART:'):]
        self.assertIn('if (self.hasVideoTrack) [self handleFirstFrameOnMain];',
                      restart[:1200])
        # 旧行为（重启无条件报首帧 + 无条件完成 seek）必须消失。
        self.assertNotIn('[self finishPendingSeek:YES];', restart[:1200])
        time_pos = self.mpv[self.mpv.index('CCTVMPVReplyTimePos && prop->format'):]
        # T20：time-pos 分支只做 4Hz 节流，首帧判定抽进 dispatchPositionUpdate:。
        self.assertIn('[self dispatchPositionUpdate:pos];', time_pos[:2000])
        position = self.mpv[self.mpv.index('- (void)dispatchPositionUpdate:(double)pos {'):]
        self.assertIn('self.hasVideoTrack && pos > 0.05', position[:2000])
        self.assertIn('pos > MediaPlaybackMPVAudioOnlyPositionThreshold',
                      position[:2000])

    def test_mpv_audio_only_delegate_is_wired(self):
        self.assertIn('cicadaAdapterDidStartAudioOnly:', self.types)
        self.assertIn('handleAudioOnlyOnMain', self.mpv)
        self.assertIn('cicadaAdapterDidStartAudioOnly:', self.mpv)
        self.assertIn('MediaPlaybackMPVAudioOnlyPositionThreshold = 1.0', self.mpv)
        # 纯音频不是视频首帧：handleAudioOnly 不置 firstFrameNotified。
        audio = self.mpv[self.mpv.index('- (void)handleAudioOnlyOnMain {'):]
        self.assertNotIn('firstFrameNotified = YES', audio[:800])
        self.assertIn('audioOnlyNotified = YES', audio[:800])

    def test_mpv_seek_has_id_target_and_timeout(self):
        self.assertIn('MediaPlaybackMPVSeekTimeout = 3.0', self.mpv)
        self.assertIn('MediaPlaybackMPVSeekPositionTolerance = 1.0', self.mpv)
        self.assertIn('pendingSeekID', self.mpv)
        self.assertIn('pendingSeekTarget', self.mpv)
        self.assertIn('handleSeekTimeoutForID:', self.mpv)
        # 完成一次且只通知一次：finishPendingSeek 在 finished 时发 didSeek。
        finish = self.mpv[self.mpv.index('- (void)finishPendingSeek:(BOOL)finished {'):]
        self.assertIn('seekTimeoutTimer', finish[:1200])
        self.assertIn('if (finished) {', finish[:1200])
        self.assertIn('cicadaAdapterDidSeek:', finish[:1200])
        # maybeCompletePendingSeek 只在落点接近目标时完成。
        maybe = self.mpv[self.mpv.index('- (void)maybeCompletePendingSeek {'):]
        self.assertIn('fabs(self.currentPosition - self.pendingSeekTarget) <= MediaPlaybackMPVSeekPositionTolerance',
                      maybe[:800])

    def test_mpv_statistics_come_from_engine_properties(self):
        stats = self.mpv[self.mpv.index('playbackStatistics'):]
        for prop in ('"hwdec-current"', '"video-bitrate"', '"audio-bitrate"',
                     '"estimated-vf-fps"', '"decoder-frame-drop-count"',
                     '"demuxer-cache-duration"'):
            self.assertIn(prop, stats[:5000], prop)
        # bufferedPosition 语义注释：demuxer-cache-time 是缓存末尾包的
        # 绝对媒体时间戳，不是"已缓冲时长"。
        self.assertIn('demuxer-cache-time', self.mpv)
        self.assertIn('缓存末尾包的绝对', self.mpv)
        self.assertIn('媒体时间戳', self.mpv)

    def test_cicada_poll_declares_audio_only_without_video_track(self):
        poll = self.cicada[self.cicada.index('- (void)startPollTimer {'):]
        self.assertIn('!owner.hasVideoTrack && position > 1.0', poll[:2000])
        self.assertIn('[owner handleAudioOnly]', poll[:2000])
        audio = self.cicada[self.cicada.index('- (void)handleAudioOnly {'):]
        self.assertIn('audioOnlyNotified = YES', audio[:800])
        self.assertIn('firstFrameWatchdog', audio[:800])
        self.assertIn('cicadaAdapterDidStartAudioOnly:', audio[:800])
        # 纯音频不置首帧已报：视频随后渲染仍可报首帧。
        self.assertNotIn('firstFrameReported = YES', audio[:800])

    def test_completion_is_reported_at_most_once(self):
        # MPV：completionNotified 单次守卫；Cicada：completedReported 单次守卫。
        self.assertIn('completionNotified', self.mpv)
        self.assertIn('if (self.destroyed || self.completionNotified) return;', self.mpv)
        self.assertIn('completedReported', self.cicada)
        self.assertIn('if (self.completedReported', self.cicada)

    def test_vc_handles_audio_only_and_clears_it_on_first_frame(self):
        self.assertIn('cicadaAdapterDidStartAudioOnly:', self.vc)
        handler = self.vc[self.vc.index('cicadaAdapterDidStartAudioOnly:'):]
        self.assertIn('self.confirmedAudioOnly=YES;', handler[:800])
        self.assertIn('media_audio_only_started', handler[:800])
        self.assertIn('正在播放音频', handler[:800])
        # 视频首帧到达时清掉纯音频标记。
        mark = self.vc[self.vc.index('- (void)markCicadaFirstFrameReady {'):]
        self.assertIn('self.confirmedAudioOnly=NO;', mark[:1200])

    def test_no_new_darwin_unsafe_pthread_clock_calls(self):
        # B1 教训：macOS 没有 pthread_condattr_setclock。
        for text in (self.mpv, self.cicada):
            self.assertNotIn('pthread_condattr_setclock', text)
        # B1 教训：typedef 里不在 block 返回类型前写 nullable。
        self.assertNotIn('typedef nullable', self.mpv)
        self.assertNotIn('typedef nullable', self.cicada)


if __name__ == '__main__':
    unittest.main()
