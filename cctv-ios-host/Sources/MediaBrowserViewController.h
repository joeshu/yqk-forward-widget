#import <UIKit/UIKit.h>

@interface MediaBrowserViewController : UIViewController
/// Refresh installed sources while preserving the current browser state when possible.
- (void)refreshSources;
@property(nonatomic, copy) NSArray<NSDictionary *> *(^sourcesProvider)(void);
@property(nonatomic, copy) void (^onActivateService)(NSDictionary *service,void (^completion)(NSError *error));
@property(nonatomic, copy) void (^onPlay)(NSDictionary *result,NSDictionary *context);
@property(nonatomic, copy) dispatch_block_t onResources;
@property(nonatomic, copy) NSError *(^startupErrorProvider)(void);
@property(nonatomic, copy) void (^onSubscribeLive)(NSDictionary *service);
@end
