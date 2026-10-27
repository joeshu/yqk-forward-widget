#import <UIKit/UIKit.h>
@interface MediaWebViewController : UIViewController
@property(nonatomic, copy) void (^onResolvedMedia)(NSDictionary *result);
@property(nonatomic, copy) NSString *correlationID;
@property(nonatomic, copy) NSString *serviceID;
@property(nonatomic, copy) NSString *playbackAttemptID;
@property(nonatomic, copy) dispatch_block_t onClose;
@property(nonatomic, copy) dispatch_block_t onTryNativePlayback;
- (instancetype)initWithResult:(NSDictionary *)result title:(NSString *)title;
@end
