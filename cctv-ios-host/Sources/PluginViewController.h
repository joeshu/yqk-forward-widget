#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface PluginViewController : UIViewController
@property (nonatomic, copy, nullable) dispatch_block_t onStart;
@property (nonatomic, copy, nullable) dispatch_block_t onStop;
@property (nonatomic, copy, nullable) dispatch_block_t onAddSubscription;
@property (nonatomic, copy, nullable) dispatch_block_t onManageSubscriptions;
@property (nonatomic, copy, nullable) dispatch_block_t onOpenLog;
- (void)updateRunning:(BOOL)running subscriptionCount:(NSUInteger)count;
@end
NS_ASSUME_NONNULL_END
