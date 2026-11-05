#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface PluginViewController : UIViewController
@property (nonatomic, copy, nullable) dispatch_block_t onStart;
@property (nonatomic, copy, nullable) dispatch_block_t onStop;
/// 重启：先停、确认端口释放后再启动；完成时回调错误（成功为 nil）。
@property (nonatomic, copy, nullable) void (^onRestart)(void (^completion)(NSError * _Nullable error));
@property (nonatomic, copy, nullable) dispatch_block_t onAddSubscription;
@property (nonatomic, copy, nullable) dispatch_block_t onManageSubscriptions;
@property (nonatomic, copy, nullable) dispatch_block_t onOpenLog;
@property (nonatomic, copy, nullable) NSUInteger (^subscriptionCountProvider)(void);
- (void)updateRunning:(BOOL)running subscriptionCount:(NSUInteger)count;
@end
NS_ASSUME_NONNULL_END
