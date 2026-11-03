#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaGlobalSearchViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *sources;
@property(nonatomic,copy,nullable) NSString *initialKeyword;
/// Set before presentation. A matching source opens search in the current-site scope.
@property(nonatomic,copy,nullable) NSString *currentSourceID;
/// The selected provider inside that source; empty string identifies a single-site source.
@property(nonatomic,copy,nullable) NSString *currentProviderID;
@property(nonatomic,copy,nullable) NSString *currentCatalogID;
@property(nonatomic,copy,nullable) void (^onActivateService)(NSDictionary *service,void (^completion)(NSError * _Nullable error));
@property(nonatomic,copy,nullable) void (^onSelectResult)(NSDictionary *item,NSDictionary *source,NSString *provider);
@end
NS_ASSUME_NONNULL_END
