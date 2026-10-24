#import <UIKit/UIKit.h>
@interface ConfigCenterViewController : UITableViewController
- (void)reloadProfiles;
@property(nonatomic, copy) NSArray<NSDictionary *> * (^profilesProvider)(void);
@property(nonatomic, copy) dispatch_block_t onServices;
@property(nonatomic, copy) dispatch_block_t onAdd;
@property(nonatomic, copy) dispatch_block_t onRefresh;
@property(nonatomic, copy) void (^onRefreshProfile)(NSString *source);
@property(nonatomic, copy) void (^onSelectProfile)(NSString *source);
@property(nonatomic, copy) void (^onToggleProfile)(NSString *source, BOOL enabled);
@property(nonatomic, copy) void (^onEditProfile)(NSString *source);
@property(nonatomic, copy) void (^onDeleteProfile)(NSString *source);
@property(nonatomic, copy) void (^onOpenResource)(NSString *source);
@end
