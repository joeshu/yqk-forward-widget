#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface TVBoxCatalogViewController : UITableViewController
@property(nonatomic,copy) NSDictionary *catalog;
@property(nonatomic,copy) void (^onImportSite)(NSDictionary *site);
@property(nonatomic,copy) void (^onUseNativeSite)(NSDictionary *site);
@property(nonatomic,copy) void (^onSubscribeLive)(NSDictionary *live);
@property(nonatomic,copy) dispatch_block_t onRemove;
@end
NS_ASSUME_NONNULL_END
