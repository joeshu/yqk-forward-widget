#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface ServicesViewController : UIViewController
@property(nonatomic,copy) dispatch_block_t onOpenYSP;
@property(nonatomic,copy) void (^onToggleService)(NSDictionary *service,BOOL enabled);
@property(nonatomic,copy) void (^onApplyService)(NSDictionary *previousService,
                                                 NSDictionary *updatedService,
                                                 void (^completion)(NSError * _Nullable error));
@property(nonatomic,copy) void (^onOpenLog)(NSDictionary * _Nullable service);
@property(nonatomic,copy) void (^onSubscribe)(NSString *url);
@property(nonatomic,copy) void (^onBrowseService)(NSDictionary *service);
@property(nonatomic,copy) dispatch_block_t onImportResource;
@end
NS_ASSUME_NONNULL_END
