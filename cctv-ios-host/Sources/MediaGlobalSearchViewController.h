#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaGlobalSearchViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *sources;
@property(nonatomic,copy,nullable) void (^onActivateService)(NSDictionary *service,void (^completion)(NSError * _Nullable error));
@property(nonatomic,copy,nullable) void (^onSelectResult)(NSDictionary *item,NSDictionary *source,NSString *provider);
@end
NS_ASSUME_NONNULL_END
