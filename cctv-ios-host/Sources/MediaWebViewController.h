#import <UIKit/UIKit.h>
@interface MediaWebViewController : UIViewController
@property(nonatomic, copy) dispatch_block_t onClose;
- (instancetype)initWithResult:(NSDictionary *)result title:(NSString *)title;
@end
