#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 取消一次尚未完成的短剧分集解析。由 resolver 在发起解析时返回，
/// feed 在槽位被逐出或退出时调用；调用后对应的 completion 不应再触发播放。
typedef void (^ShortDramaResolveCancel)(void);

/// 短剧分集解析器：为指定下标解析出可直接播放的 URL 与请求头。
/// 每次调用必须使用独立的解析任务（独立 MediaAPIClient 或等价隔离），
/// 不得取消其它下标正在进行的解析；返回取消令牌（不支持取消时返回 nil）。
/// 若结果需要网页解析/非原生播放（requiresWebPlayback），应直接回调 completion(nil, nil)，
/// 由详情页的标准播放器承接（feed 只走 AVPlayer 直播）。
typedef nullable ShortDramaResolveCancel (^ShortDramaEpisodeResolver)(NSInteger index, void (^completion)(NSURL * _Nullable url, NSDictionary<NSString *, NSString *> * _Nullable headers));

/// 短剧全屏竖屏上下滑沉浸播放引擎（3 实例滑窗预热池：当前集播放 + 下一集预热 + 上一集保活）。
@interface ShortDramaVerticalFeedController : UIViewController

/// 初始化短剧竖屏流：episodes 数组每项含 @{@"name": ..., @"url": ...}（或由 resolver 异步解析）。
- (instancetype)initWithTitle:(NSString *)dramaTitle
                     episodes:(NSArray<NSDictionary *> *)episodes
                 initialIndex:(NSInteger)initialIndex
               episodeResolver:(nullable ShortDramaEpisodeResolver)resolver;

@end

NS_ASSUME_NONNULL_END
