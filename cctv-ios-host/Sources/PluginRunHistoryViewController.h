#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginRunHistoryViewController : UITableViewController
@property(nonatomic,copy,nullable) NSString *serviceName;
@property(nonatomic,copy,nullable) NSArray<NSDictionary *> *(^runRecordsProvider)(void);
@property(nonatomic,copy,nullable) void (^onSelectRun)(NSDictionary *run);
@property(nonatomic,copy,nullable) dispatch_block_t onExportAll;
@property(nonatomic,copy,nullable) dispatch_block_t onClearAll;
@end

NS_ASSUME_NONNULL_END
