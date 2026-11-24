#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 短剧全屏竖屏上下滑沉浸播放引擎（3 实例滑窗预热池：当前集播放 + 下一集预热 + 上一集保活）。
@interface ShortDramaVerticalFeedController : UIViewController

/// 初始化短剧竖屏流：episodes 数组每项含 @{@"name": ..., @"url": ...}（或由 resolver 异步解析）。
- (instancetype)initWithTitle:(NSString *)dramaTitle
                     episodes:(NSArray<NSDictionary *> *)episodes
                 initialIndex:(NSInteger)initialIndex
               episodeResolver:(nullable void (^)(NSInteger index, void (^completion)(NSURL * _Nullable url, NSDictionary<NSString *, NSString *> * _Nullable headers)))resolver;

@end

NS_ASSUME_NONNULL_END
