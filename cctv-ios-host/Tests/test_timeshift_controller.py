from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def brace_balanced(text):
    depth = 0
    for ch in text:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


class TimeshiftControllerContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (ROOT / 'Sources/CCTVTimeshiftController.h').read_text()
        cls.impl = (ROOT / 'Sources/CCTVTimeshiftController.m').read_text()
        cls.delegate = (ROOT / 'Sources/CNPlayerSessionDelegate.m').read_text()
        cls.patch = (ROOT / 'Docs/TIMESHIFT-INTEGRATION-PATCH.md').read_text()

    def test_controller_declares_full_state_machine(self):
        # 六态：空闲 / 版权预检 / 定位中 / 回看播放 / 返回直播 / 失败。
        for state in ['CCTVTimeshiftStateIdle', 'CCTVTimeshiftStateCheckingCopyright',
                      'CCTVTimeshiftStateSeeking', 'CCTVTimeshiftStatePlayingReplay',
                      'CCTVTimeshiftStateReturningToLive', 'CCTVTimeshiftStateFailed']:
            self.assertIn(state, self.header)

    def test_controller_declares_error_codes_aligned_with_session(self):
        # 1-3 与 NativeTimeshiftSession（CCTVHostTimeshift）对齐，4-6 新增。
        for code in ['CCTVTimeshiftErrorTimeout = 1', 'CCTVTimeshiftErrorInvalidRange = 2',
                     'CCTVTimeshiftErrorUnsupportedPlayer = 3', 'CCTVTimeshiftErrorNoCopyright = 4',
                     'CCTVTimeshiftErrorSeekRejected = 5', 'CCTVTimeshiftErrorReturnLiveFailed = 6']:
            self.assertIn(code, self.header)

    def test_controller_uses_manual_sdk_state_values(self):
        # 手册顺序推导：SeekSucceed=5、Stalled=11、StalledRecovery=12、Cancelled=13；
        # VODSeekStart=11、VODSeekCompletion=12、FirstRenderDidStart=3。
        for value in ['CCTVTimeshiftLoadStateSeekSucceed = 5', 'CCTVTimeshiftLoadStateStalled = 11',
                      'CCTVTimeshiftLoadStateStalledRecovery = 12', 'CCTVTimeshiftLoadStateCancelled = 13',
                      'CCTVTimeshiftStatEventVODSeekStart = 11', 'CCTVTimeshiftStatEventVODSeekCompletion = 12',
                      'CCTVTimeshiftStatEventFirstRenderDidStart = 3']:
            self.assertIn(value, self.header)

    def test_controller_declares_copyright_config_keys(self):
        # 版权校验配置键（与 App kOptTitle 等字符串字面量约定一致）。
        self.assertIn('CNPlayerConfigOptionKey_LivePublicCheck_ONOFF', self.header)
        self.assertIn('CNPlayerConfigOptionKey_TimeshiftingChannelID', self.header)
        self.assertIn('configSDK_VDN_LiveTSPublicUrl', self.header)

    def test_controller_debounces_seeks_and_caches_copyright_checks(self):
        # 防抖 0.3 秒、版权缓存 60 秒、预检超时 5 秒放行。
        self.assertIn('CCTVTimeshiftDebounceInterval = 0.3', self.impl)
        self.assertIn('CCTVTimeshiftCopyrightCacheTTL = 60.0', self.impl)
        self.assertIn('CCTVTimeshiftCopyrightCheckTimeout = 5.0', self.impl)
        self.assertIn('checkPublicPlaytime:completionBlock:', self.impl)

    def test_controller_retries_transient_seek_once_without_rebuilding_player(self):
        # 仅预检通过时对瞬时失败重试一次（同播放器实例，不重建、不重新请求 VDN）；
        # 超时不重试。
        self.assertIn('self.seekAttempts < 2 && self.seekPreCheckPassed', self.impl)
        self.assertIn('error.code != CCTVTimeshiftErrorTimeout', self.impl)

    def test_controller_tracks_seek_latency_and_stalls(self):
        # seek 接受耗时、首帧耗时、回看中卡顿计数、距直播秒数。
        for name in ['seekLatency', 'seekFirstFrameLatency', 'stallCount', 'behindLiveSeconds']:
            self.assertIn(name, self.header)
        self.assertIn('recordSeekFirstFrame', self.impl)
        self.assertIn('notePeriodicTick', self.impl)

    def test_controller_falls_back_when_back_to_live_unsupported(self):
        # backToLive 不可用时走宿主回退（整台重播），不是只报错。
        self.assertIn('onReturnToLiveFallback', self.header)
        self.assertIn('onReturnToLiveFallback', self.impl)

    def test_delegate_forwards_copyright_change_and_periodic_tick(self):
        # 会话代理新增转发：播放中版权变动（两种签名）+ 每秒周期事件，
        # 均受会话代际守卫，且宿主方法未合入前先判 respondsToSelector。
        for fragment in ['programPubicChanged:', 'programPubicChanged:type:error:',
                         'playerPeriodicTimeEvent:', 'isCurrentSession', 'respondsToSelector']:
            self.assertIn(fragment, self.delegate)

    def test_new_files_are_brace_balanced(self):
        self.assertTrue(brace_balanced(self.impl))
        self.assertTrue(brace_balanced(self.delegate))

    def test_integration_patch_covers_all_host_wiring(self):
        # 集成补丁须覆盖：seek/返回直播接入、SeekSucceed 与 seek 统计事件转发、
        # 版权变动与周期事件处理、时移进度 UI、SDK 版权配置（三件套缺一不可）。
        for fragment in ['seekNativeStart', 'returnToNativeLive', 'SeekSucceed',
                         'VODSeekCompletion', 'programPubicChanged', 'playerPeriodicTimeEvent',
                         'LivePublicCheck', 'TimeshiftingChannelID', 'LiveTSPublicUrl']:
            self.assertIn(fragment, self.patch)


if __name__ == '__main__':
    unittest.main()
