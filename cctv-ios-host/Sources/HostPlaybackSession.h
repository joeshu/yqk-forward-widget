// HostPlaybackSession.h
//
// 统一播放会话（P2）：轻量模型对象，收拢一次点播播放尝试的状态——
// 源解析结果、请求头、当前解码路由、已尝试路由位掩码、重试计数、续播进度。
//
// 纯 Foundation 逻辑，不引用 UIKit / 播放器 SDK 符号，ui-smoke 构建也能链接。
// 路由选择本身仍由 MediaPlaybackDecodeRouteNextForResult 决定，本类只做封装与状态记录。
#import <Foundation/Foundation.h>
#import "MediaPlaybackDecodeRouter.h"

NS_ASSUME_NONNULL_BEGIN

@interface HostPlaybackSession : NSObject

/// 源解析结果字典（playResult: 的入参）。
@property (nonatomic, copy, nullable) NSDictionary *resolvedResult;
/// 本次播放使用的请求头。
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *requestHeaders;
/// 最近一次 -nextRouteForResult: 选出的路由；未选择或无可用路由时为 MediaPlaybackDecodeRouteNone。
@property (nonatomic) MediaPlaybackDecodeRoute currentRoute;
/// 已尝试路由位掩码（MediaPlaybackDecodeRouteAttempted* 的或）；0 表示从头开始。
@property (nonatomic) NSUInteger attemptedRoutes;
/// 本会话内的重试次数。
@property (nonatomic) NSInteger retryCount;
/// 续播进度（秒）；非有限值或负数在写入时归零。
@property (nonatomic) NSTimeInterval resumePosition;

/// 只查询下一条未尝试的路由，不修改任何状态。
- (MediaPlaybackDecodeRoute)peekNextRouteForResult:(nullable NSDictionary *)result;

/// 选择下一条未尝试的路由：调用 MediaPlaybackDecodeRouteNextForResult(result, attemptedRoutes)，
/// 并把结果记入 currentRoute。等价于 -nextRouteForResult:markAttempted:NO。
/// 注意：为与现有点播页回退链行为等价，默认不在“选择”时置位 attempted——
/// 引擎真正启动时由调用方 -markRouteAttempted:（或直接改 attemptedRoutes）置位。
- (MediaPlaybackDecodeRoute)nextRouteForResult:(nullable NSDictionary *)result;

/// 同上；markAttempted 为 YES 时同时把返回的路由并入 attemptedRoutes（None 不置位）。
- (MediaPlaybackDecodeRoute)nextRouteForResult:(nullable NSDictionary *)result markAttempted:(BOOL)markAttempted;

/// 把某路由并入 attemptedRoutes；None 忽略。
- (void)markRouteAttempted:(MediaPlaybackDecodeRoute)route;

/// 该路由是否已尝试过。
- (BOOL)hasAttemptedRoute:(MediaPlaybackDecodeRoute)route;

/// 清空路由状态（attemptedRoutes=0、currentRoute=None），保留结果/请求头/进度。
- (void)resetRoutes;

/// 路由 → Attempted 位；None 或未知路由返回 0。
+ (NSUInteger)attemptedMaskForRoute:(MediaPlaybackDecodeRoute)route;

@end

NS_ASSUME_NONNULL_END
