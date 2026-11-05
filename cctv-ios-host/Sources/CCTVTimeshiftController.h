#import <Foundation/Foundation.h>

// 回看 / 时移状态机（CCTVTimeshiftController）。
//
// 解决的问题（对照《央视网 iOS 播放器集成手册》BV3.23.17）：
//  1. 版权预检缺失：App 从未调用 checkPublicPlaytime，时移 seek 要等 SDK
//     10 秒超时才知道无版权；本控制器在 seek 前先调 checkPublicPlaytime，
//     无版权直接失败（60 秒缓存，同一节目重复 seek 不重复校验）。
//  2. seek 无防抖：连续点按回退每次都走完整 beginNativeTransition；本控制
//     器 0.3 秒防抖合并，只执行最后一次请求，旧请求取消。
//  3. seek 失败无重试：失败直接报错；本控制器在预检通过/未做预检时对瞬时
//     失败重试一次（同播放器实例，不重建播放器、不重新请求 VDN）。
//  4. seek 完成无感知：loadState SeekSucceed / statEvent VODSeekStart、
//     VODSeekCompletion 从未处理；本控制器记录 seek 耗时与首帧耗时。
//  5. 播放中版权变动无感知：programPubicChanged 从未转发；本控制器接
//     收后在回看中版权丢失时失败并通知宿主返回直播。
//  6. 时移进度无 tick：playerPeriodicTimeEvent 从未转发；本控制器每秒更
//     新距直播秒数，供宿主刷新“回看中 · 距直播 X 分钟”。
//
// 只依赖 Foundation + NativeTimeshiftSession，可独立编译测试；
// 不直接操作 RootViewController / MediaPlaybackViewController，宿主通过
// 集成补丁（见仓库外说明）在 seekNativeStart / returnToNativeLive 与各 SDK
// 回调处接入。

// —— SDK 状态值（手册顺序推导；App 已用 4=PrepareDone、13=Cancelled、
//    statEvent 1/2/3=Startup/SetupPlayer/FirstRenderDidStart 佐证该顺序）——
typedef NS_ENUM(NSUInteger, CCTVTimeshiftLoadState) {
    CCTVTimeshiftLoadStatePrepareDone = 4,
    CCTVTimeshiftLoadStateSeekSucceed = 5,
    CCTVTimeshiftLoadStateStalled = 11,
    CCTVTimeshiftLoadStateStalledRecovery = 12,
    CCTVTimeshiftLoadStateCancelled = 13,
};
typedef NS_ENUM(NSUInteger, CCTVTimeshiftStatEvent) {
    CCTVTimeshiftStatEventFirstRenderDidStart = 3,
    CCTVTimeshiftStatEventVODSeekStart = 11,
    CCTVTimeshiftStatEventVODSeekCompletion = 12,
};

// —— 版权校验配置键（与 App 既有 kOptTitle 等字符串字面量约定一致）——
// 注意：SDK 侧自动版权校验需三者齐备才生效（手册 §4.8）：
//   LivePublicCheck_ONOFF=YES + TimeshiftingChannelID + configSDK_VDN_LiveTSPublicUrl。
//   其中 LiveTSPublicUrl 的真实地址须向央视索取，本控制器不内置占位地址；
//   未配齐前，本控制器的 checkPublicPlaytime 主动预检是唯一生效的版权关口。
static NSString *const CCTVTimeshiftConfigKeyLivePublicCheck = @"CNPlayerConfigOptionKey_LivePublicCheck_ONOFF";
static NSString *const CCTVTimeshiftConfigKeyTimeshiftingChannelID = @"CNPlayerConfigOptionKey_TimeshiftingChannelID";

typedef NS_ENUM(NSInteger, CCTVTimeshiftState) {
    CCTVTimeshiftStateIdle = 0,
    CCTVTimeshiftStateCheckingCopyright = 1,
    CCTVTimeshiftStateSeeking = 2,
    CCTVTimeshiftStatePlayingReplay = 3,
    CCTVTimeshiftStateReturningToLive = 4,
    CCTVTimeshiftStateFailed = 5,
};

// 错误码 1-3 与 NativeTimeshiftSession（CCTVHostTimeshift）对齐；4-6 为本控制器新增。
typedef NS_ENUM(NSInteger, CCTVTimeshiftError) {
    CCTVTimeshiftErrorTimeout = 1,
    CCTVTimeshiftErrorInvalidRange = 2,
    CCTVTimeshiftErrorUnsupportedPlayer = 3,
    CCTVTimeshiftErrorNoCopyright = 4,
    CCTVTimeshiftErrorSeekRejected = 5,
    CCTVTimeshiftErrorReturnLiveFailed = 6,
};

@interface CCTVTimeshiftController : NSObject
@property(nonatomic, readonly) CCTVTimeshiftState state;
@property(nonatomic, readonly) NSTimeInterval seekStart;
@property(nonatomic, readonly) NSTimeInterval seekEnd;
@property(nonatomic, readonly) NSTimeInterval seekLatency;           // seek 发起 → SDK 接受
@property(nonatomic, readonly) NSTimeInterval seekFirstFrameLatency; // seek 发起 → 首帧
@property(nonatomic, readonly) NSTimeInterval behindLiveSeconds;     // 距直播秒数
@property(nonatomic, readonly) NSUInteger stallCount;                // 回看中卡顿次数
@property(nonatomic, copy, nullable) void (^onStateChanged)(CCTVTimeshiftState state);
@property(nonatomic, copy, nullable) void (^onProgress)(NSTimeInterval behindLiveSeconds, NSTimeInterval positionSeconds);
@property(nonatomic, copy, nullable) void (^onFailure)(NSError *error);
@property(nonatomic, copy, nullable) void (^onReturnToLiveFallback)(void);
- (instancetype)initWithPlayer:(id)player;
- (void)resetWithPlayer:(id)player;
// 防抖 seek：0.3 秒内多次请求只执行最后一次；执行中来新请求会取消旧 seek。
- (void)requestSeekToStart:(NSTimeInterval)start end:(NSTimeInterval)end channelID:(NSString *)channelID completion:(void (^)(BOOL ok, NSError *error))completion;
// 返回直播：backToLive 不可用时走 onReturnToLiveFallback（宿主整台重播）。
- (void)returnToLive;
// 以下由宿主从 SDK 回调转发（主线程调用）。
- (void)noteLoadState:(NSUInteger)state;
- (void)noteStatEvent:(NSUInteger)event;
- (void)noteCopyrightChanged:(BOOL)isPublic error:(nullable NSError *)error;
- (void)notePeriodicTick;
- (void)noteReturnedToLive;
- (void)cancel;
@end
