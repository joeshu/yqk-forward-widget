#import <UIKit/UIKit.h>
@interface MediaWebViewController : UIViewController
@property(nonatomic, copy) dispatch_block_t onClose;
@property(nonatomic, copy) dispatch_block_t onTryNativePlayback;
- (instancetype)initWithResult:(NSDictionary *)result title:(NSString *)title;
@end
