#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface TVBoxCatalogViewController : UITableViewController
@property(nonatomic,copy) NSDictionary *catalog;
@property(nonatomic,copy) NSDictionary *(^serviceForSite)(NSDictionary *site);
@property(nonatomic,copy) void (^onImportSite)(NSDictionary *site,BOOL browseAfterImport);
@property(nonatomic,copy) void (^onUseImportedService)(NSDictionary *service);
@property(nonatomic,copy) void (^onOpenImportedService)(NSDictionary *service);
@property(nonatomic,copy) void (^onUseNativeSite)(NSDictionary *site);
@property(nonatomic,copy) void (^onSubscribeLive)(NSDictionary *live);
@property(nonatomic,copy) dispatch_block_t onImportCompatibleContents;
@property(nonatomic,copy) void (^onExportCatalog)(NSString *format);
@property(nonatomic,copy) void (^onExportSingleResource)(NSDictionary *resource,NSString *kind,NSUInteger index);
@property(nonatomic,copy) dispatch_block_t onRemove;
@end
NS_ASSUME_NONNULL_END
