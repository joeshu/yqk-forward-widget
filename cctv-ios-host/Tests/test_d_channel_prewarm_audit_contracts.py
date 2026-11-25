"""D阶段 · 频道预热（NativeChannelPreloader）切换资源审计契约测试

只读取 Sources 文本断言不变量，不触发构建/网络/CI。
对应审计维度：并发、取消、过期/陈旧结果覆盖、内存预算。

审计结论：现有 NativeChannelPreloader 行为正确，本次不加重型预热，无确定 bug 需修复；
本文件固化以下不变量以便回归：

1. 单槽语义：头注释声明「Holds at most one SDK-owned metadata preparation」，
   状态字段为单值（player/channel/ready/deadline），prepare 起步即 cancel 旧槽。
2. 并发安全：所有状态变更与回调收敛到主线程；statEvent 非主线程时重投主线程。
3. 取消语义：prepare 起步调用 cancel；cancel 自增 generation、nil 化 player 并 reset；
   takeChannel 交割后自增 generation 并置空状态；dealloc 调用 cancel。
4. 陈旧覆盖防护：completion 与 90s 超时定时器均以捕获的 generation 与 owner.generation
   比对，不匹配即放弃；deadline 逾期即取消，绝不把过期元数据标 ready。
5. 内存预算：单 CNPlayer 实例上限、TTL=90s、交割/取消后立即释放；无重型预热新增。
"""
import os
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(REPO_ROOT, "Sources")


def read_source(name):
    with open(os.path.join(SOURCES, name), "r", encoding="utf-8") as f:
        return f.read()


class DChannelPrewarmAuditContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hdr = read_source("NativeChannelPreloader.h")
        cls.impl = read_source("NativeChannelPreloader.m")

    # 1. 单槽语义
    def test_header_declares_single_slot_metadata_only(self):
        self.assertIn("Holds at most one SDK-owned metadata preparation", self.hdr)
        self.assertIn("never starts video playback", self.hdr)

    def test_prepare_clears_previous_slot_before_configuring_new(self):
        # prepare 起步先 cancel，保证任一时刻最多一个待用 player。
        body = self.impl.split("- (void)prepareChannel:", 1)[1]
        head = body.split("NSUInteger generation", 1)[0]
        self.assertIn("[self cancel];", head)
        self.assertIn("if(!channel.length)return;", head)

    def test_state_is_single_valued_not_collection(self):
        # 单值字段而非数组/字典，结构上保证单槽。
        for decl in (
            "@property(nonatomic,strong) id<CCTVMetadataPlayer> player;",
            "@property(nonatomic,copy) NSString *channel;",
            "@property(nonatomic) BOOL ready;",
            "@property(nonatomic) NSTimeInterval deadline;",
        ):
            self.assertIn(decl, self.impl)

    # 2. 并发安全
    def test_completion_and_timer_land_on_main_queue(self):
        body = self.impl.split("prepareRateItemToPlay_completionBlock", 1)[1]
        self.assertIn("dispatch_async(dispatch_get_main_queue(),^{", body)
        self.assertIn("dispatch_after(dispatch_time(DISPATCH_TIME_NOW", self.impl)
        self.assertIn("dispatch_get_main_queue(),^{", self.impl)

    def test_statevent_redispatches_off_main_to_main(self):
        body = self.impl.split("- (void)player:(id)player statEvent:", 1)[1]
        self.assertIn("if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue()", body)

    # 3. 取消语义
    def test_cancel_increments_generation_resets_player(self):
        body = self.impl.split("- (void)cancel {", 1)[1] if "- (void)cancel {" in self.impl \
            else self.impl.split("- (void)cancel", 1)[1]
        self.assertIn("self.generation++;", body)
        self.assertIn("self.ready=NO;", body)
        self.assertIn("self.channel=nil;", body)
        self.assertIn("player.delegate=nil;[player reset];", body)

    def test_takechannel_advances_generation_and_clears_state(self):
        body = self.impl.split("- (id)takeChannel:", 1)[1]
        self.assertIn("self.generation++;self.player=nil;self.channel=nil;self.ready=NO;", body)
        self.assertIn("player.delegate=nil;", body)

    def test_dealloc_cancels(self):
        self.assertIn("- (void)dealloc { [self cancel]; }", self.impl)

    # 4. 陈旧/过期覆盖防护
    def test_completion_drops_stale_generation(self):
        body = self.impl.split("prepareRateItemToPlay_completionBlock", 1)[1]
        self.assertIn("if(!owner || generation!=owner.generation)return;", body)

    def test_completion_rejects_error_nonpublic_and_expired_deadline(self):
        body = self.impl.split("prepareRateItemToPlay_completionBlock", 1)[1]
        self.assertIn(
            "if(error || !isPublic || owner.clock()>=owner.deadline){[owner cancel];return;}",
            body,
        )
        self.assertIn("owner.ready=YES;", body)

    def test_ttl_timer_only_cancels_matching_generation(self):
        self.assertIn("static const NSTimeInterval NativeChannelPreloaderTTLSeconds = 90.0;", self.impl)
        body = self.impl.split("dispatch_after(dispatch_time(DISPATCH_TIME_NOW", 1)[1]
        self.assertIn("if(owner && generation==owner.generation)[owner cancel];", body)

    def test_takechannel_guards_ready_channel_and_deadline_before_handoff(self):
        body = self.impl.split("- (id)takeChannel:", 1)[1].split("self.generation++", 1)[0]
        self.assertIn("if(!self.ready", body)
        self.assertIn("![self.channel isEqualToString:channel]", body)
        self.assertIn("self.clock()>=self.deadline", body)

    def test_statevent_defensive_cancel_only_for_owned_player(self):
        # event==3（疑似起播）仅当该 player 仍是当前预解析槽时取消，避免误杀已交割实例。
        self.assertIn("if(event==3 && player==self.player)[self cancel];", self.impl)

    # 5. 内存预算：无重型预热新增（TTL 与单槽即预算上限）
    def test_no_heavy_parallel_prewarm_introduced(self):
        # 不存在 batch/数组式并发预热多个频道 player 的结构。
        self.assertNotIn("NSArray<id<CCTVMetadataPlayer>>", self.impl)
        self.assertNotIn("NSMutableDictionary<NSString *, id<CCTVMetadataPlayer>", self.impl)
        self.assertNotIn("dispatch_apply", self.impl)


if __name__ == "__main__":
    unittest.main()
