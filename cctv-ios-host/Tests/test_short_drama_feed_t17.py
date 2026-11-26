"""短剧竖屏流产品完整性（T17：失败卡片 + 历史/续播接线）行为测试 + 源码合同。

行为部分复刻 persistSlotProgress 的写历史门禁（M11 同款）与续播位置判定，
真实执行场景断言；接线部分用源码合同锁定（失败卡片、原因直通、标准播放器
出口、historyContext/initialResumePosition/onOpenInStandardPlayer）。
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Sources'


def read_source(name):
    return (SOURCES / name).read_text(encoding='utf-8')


def persist_decision(*, has_history_context, evidence_ready, completed,
                     completed_persisted, position, duration):
    """复刻 ShortDramaVerticalFeedController.persistSlotProgress 的写判定。

    返回 (should_write, completed_persisted_after)。"""
    if not has_history_context:
        return False, completed_persisted
    if completed_persisted and not completed:
        return False, completed_persisted
    if not evidence_ready and not completed:
        return False, completed_persisted
    if position is None or position < 0:
        return False, completed_persisted
    if not completed and position <= 0:
        return False, completed_persisted
    return True, (True if completed else completed_persisted)


def resume_position(*, entry, min_position=15.0, tail_guard=10.0):
    """复刻详情页 openShortDramaVerticalFeed 的 initialResumePosition 判定。

    entry: 历史条目 dict（position/duration/completed），无条目返回 0。"""
    if not entry:
        return 0
    if entry.get('completed'):
        return 0
    position = entry.get('position', 0)
    duration = entry.get('duration', 0)
    if position < min_position:
        return 0
    if duration and duration > 0 and position >= duration - tail_guard:
        return 0
    return position


class PersistDecisionBehavior(unittest.TestCase):
    def test_no_history_context_never_writes(self):
        self.assertFalse(persist_decision(
            has_history_context=False, evidence_ready=True, completed=False,
            completed_persisted=False, position=30, duration=60)[0])
        self.assertFalse(persist_decision(
            has_history_context=False, evidence_ready=True, completed=True,
            completed_persisted=False, position=60, duration=60)[0])

    def test_no_evidence_no_write_unless_completed(self):
        # 无首帧/播放证据且未完成 → 不建历史（M11 门禁）。
        self.assertFalse(persist_decision(
            has_history_context=True, evidence_ready=False, completed=False,
            completed_persisted=False, position=30, duration=60)[0])
        # 播完（completed=YES）不需要证据。
        self.assertTrue(persist_decision(
            has_history_context=True, evidence_ready=False, completed=True,
            completed_persisted=False, position=60, duration=60)[0])

    def test_zero_position_never_writes(self):
        self.assertFalse(persist_decision(
            has_history_context=True, evidence_ready=True, completed=False,
            completed_persisted=False, position=0, duration=60)[0])

    def test_completed_persisted_blocks_later_incomplete_write(self):
        # 播完写 completed=YES 后，离场/关闭时的 completed=NO 写不再覆盖完成态。
        wrote, flag = persist_decision(
            has_history_context=True, evidence_ready=True, completed=True,
            completed_persisted=False, position=60, duration=60)
        self.assertTrue(wrote)
        self.assertTrue(flag)
        self.assertFalse(persist_decision(
            has_history_context=True, evidence_ready=True, completed=False,
            completed_persisted=flag, position=60, duration=60)[0])

    def test_evidence_with_position_writes(self):
        self.assertTrue(persist_decision(
            has_history_context=True, evidence_ready=True, completed=False,
            completed_persisted=False, position=30, duration=60)[0])


class ResumePositionBehavior(unittest.TestCase):
    def test_resume_rules(self):
        self.assertEqual(resume_position(entry=None), 0)
        self.assertEqual(resume_position(entry={'position': 30, 'duration': 60}), 30)
        self.assertEqual(resume_position(entry={'position': 10, 'duration': 60}), 0)
        self.assertEqual(resume_position(
            entry={'position': 30, 'duration': 60, 'completed': True}), 0)
        self.assertEqual(resume_position(entry={'position': 55, 'duration': 60}), 0)
        self.assertEqual(resume_position(entry={'position': 30, 'duration': 0}), 30)


class ShortDramaFeedT17Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feed_h = read_source('ShortDramaVerticalFeedController.h')
        cls.feed_m = read_source('ShortDramaVerticalFeedController.m')
        cls.browser_m = read_source('MediaBrowserViewController.m')

    def test_resolver_completion_carries_failure_reason(self):
        # T17：completion 三参（url, headers, failureReason）。
        self.assertIn('failureReason', self.feed_h)
        self.assertIn('NSURL * _Nullable url', self.feed_h)
        self.assertIn('NSString * _Nullable failureReason', self.feed_h)

    def test_failure_card_wired(self):
        self.assertIn('showFailureWithReason:', self.feed_m)
        self.assertIn('canOpenInStandardPlayer:', self.feed_m)
        self.assertIn('hideFailure', self.feed_m)
        self.assertIn('failureRetryButton', self.feed_m)
        self.assertIn('failureStandardButton', self.feed_m)
        self.assertIn('retryFailedEpisode:', self.feed_m)
        self.assertIn('openFailedEpisodeInStandardPlayer:', self.feed_m)
        # 失败槽位只在 Failed 态重试，不碰正在解析的槽。
        self.assertIn('ShortDramaSlotStateFailed', self.feed_m)
        # 播放失败通知进失败态并显示卡片。
        self.assertIn('AVPlayerItemFailedToPlayToEndTimeNotification', self.feed_m)
        self.assertIn('handlePlaybackFailed:', self.feed_m)

    def test_history_and_resume_wiring(self):
        self.assertIn('historyContext', self.feed_h)
        self.assertIn('initialResumePosition', self.feed_h)
        self.assertIn('onOpenInStandardPlayer', self.feed_h)
        self.assertIn('persistSlotProgress:', self.feed_m)
        self.assertIn('installProgressObserverForSlot:', self.feed_m)
        self.assertIn('completedPersisted', self.feed_m)
        self.assertIn('resumeSeekDone', self.feed_m)
        # 播完记完成态再切下一集。
        self.assertIn('persistSlotProgress:current completed:YES', self.feed_m)

    def test_detail_page_feeds_reason_and_history(self):
        # 网页结果给原因，不再静默回调 nil。
        self.assertIn('需要网页播放，请用标准播放器打开', self.browser_m)
        # 能力不支持复用标准判定文案。
        self.assertIn('capabilityStatus', self.browser_m)
        self.assertIn('当前播放器不支持此容器', self.browser_m)
        # 历史上下文 + 续播位置 + 标准播放器出口都传入 feed。
        self.assertIn('feed.historyContext', self.browser_m)
        self.assertIn('feed.initialResumePosition', self.browser_m)
        self.assertIn('feed.onOpenInStandardPlayer', self.browser_m)
        self.assertIn('historyEntryForContext:', self.browser_m)


if __name__ == '__main__':
    unittest.main()
