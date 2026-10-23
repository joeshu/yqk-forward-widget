#import <UIKit/UIKit.h>

@interface MediaBrowserViewController : UIViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *(^sourcesProvider)(void);
@property(nonatomic, copy) void (^onActivateService)(NSDictionary *service,void (^completion)(NSError *error));
@property(nonatomic, copy) void (^onPlay)(NSDictionary *result,NSString *name);
@property(nonatomic, copy) dispatch_block_t onResources;
@property(nonatomic, copy) void (^onSubscribeLive)(NSDictionary *service);
@end
