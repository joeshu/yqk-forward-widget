#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 取消一次尚未完成的短剧分集解析。由 resolver 在发起解析时返回，
/// feed 在槽位被逐出或退出时调用；调用后对应的 completion 不应再触发播放。
typedef void (^ShortDramaResolveCancel)(void);

/// 短剧分集解析器：为指定下标解析出可直接播放的 URL 与请求头。
/// 每次调用必须使用独立的解析任务（独立 MediaAPIClient 或等价隔离），
/// 不得取消其它下标正在进行的解析；返回取消令牌（不支持取消时返回 nil）。
/// 若结果需要网页解析/非原生播放（requiresWebPlayback），应直接回调
/// completion(nil, nil, 原因)，由详情页的标准播放器承接（feed 只走 AVPlayer 直播）。
/// 若结果是不支持的容器/编码/传输，也回调 completion(nil, nil, 原因)，
/// feed 在失败卡片上显示原因并提供标准播放器出口。
/// 注意：typedef 本身不带 nullable（clang 不接受 block 返回类型前的
/// nullable 限定）；resolver 可为空由各使用处显式标注（init 参数与
/// feed 的 episodeResolver 属性均为 nullable）。
typedef ShortDramaResolveCancel (^ShortDramaEpisodeResolver)(NSInteger index, void (^completion)(NSURL * _Nullable url, NSDictionary<NSString *, NSString *> * _Nullable headers, NSString * _Nullable failureReason));

/// 短剧全屏竖屏上下滑沉浸播放引擎（3 实例滑窗预热池：当前集播放 + 下一集预热 + 上一集保活）。
@interface ShortDramaVerticalFeedController : UIViewController

/// 初始化短剧竖屏流：episodes 数组每项含 @{@"name": ..., @"url": ...}（或由 resolver 异步解析）。
- (instancetype)initWithTitle:(NSString *)dramaTitle
                     episodes:(NSArray<NSDictionary *> *)episodes
                 initialIndex:(NSInteger)initialIndex
               episodeResolver:(nullable ShortDramaEpisodeResolver)resolver;

/// 历史上下文（可选）：与详情页 resolve 上下文同形
/// @{@"source":..., @"provider":..., @"item":..., @"detail":..., @"seasonIndex":...}，
/// 置入后 feed 按集写观看历史（一集一条，首帧/播放证据后才记）。
/// 不置入时 feed 不写历史。
@property (nonatomic, copy, nullable) NSDictionary *historyContext;

/// 进入时首集的续播位置（秒，0 表示无续播）。仅对进入时那一集 seek 一次。
@property (nonatomic, assign) NSTimeInterval initialResumePosition;

/// 失败卡片上的“用标准播放器打开”出口（可选）：参数为分集下标，
/// 由详情页实现（解散 feed 后用标准播放器播该集）。不设置时不显示该按钮。
@property (nonatomic, copy, nullable) void (^onOpenInStandardPlayer)(NSInteger index);

@end

NS_ASSUME_NONNULL_END
