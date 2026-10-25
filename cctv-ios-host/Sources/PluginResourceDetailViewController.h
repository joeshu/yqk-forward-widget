#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface PluginResourceDetailViewController : UITableViewController
@property(nonatomic,copy) NSDictionary *service;
@property(nonatomic,copy) void (^onToggle)(NSDictionary *service,BOOL enabled,void (^completion)(NSError *error));
@property(nonatomic,copy) void (^onUse)(NSDictionary *service,NSString *kind);
@property(nonatomic,copy) void (^onLog)(NSDictionary *service);
@property(nonatomic,copy) void (^onEdit)(NSDictionary *service);
@property(nonatomic,copy) void (^onUpdate)(NSDictionary *service);
@property(nonatomic,copy) void (^onRollback)(NSDictionary *service);
@property(nonatomic,copy) void (^onRemove)(NSDictionary *service);
@end
NS_ASSUME_NONNULL_END
