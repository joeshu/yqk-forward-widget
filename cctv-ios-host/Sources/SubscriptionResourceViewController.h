#import <UIKit/UIKit.h>
@interface SubscriptionResourceViewController : UITableViewController
@property(nonatomic,copy) NSString *source;
@property(nonatomic) BOOL initiallyEditing;
@property(nonatomic,copy) NSDictionary * (^profileProvider)(void);
@property(nonatomic,copy) void (^onCommit)(NSString *name,NSString *url,NSString *epg,void (^completion)(NSError *error));
@property(nonatomic,copy) dispatch_block_t onOpen;
@property(nonatomic,copy) dispatch_block_t onRefresh;
@property(nonatomic,copy) dispatch_block_t onRecheckHealth;
@property(nonatomic,copy) dispatch_block_t onRematchEPG;
@property(nonatomic,copy) dispatch_block_t onExport;
@property(nonatomic,copy) dispatch_block_t onDelete;
- (void)reloadThemeAppearance;
@end
