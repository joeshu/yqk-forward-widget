#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginRunHistoryViewController : UITableViewController
@property(nonatomic,copy,nullable) NSString *serviceName;
@property(nonatomic,copy,nullable) void (^runRecordsLoader)(void (^completion)(NSArray<NSDictionary *> *runs));
/// 主线程回调：每次取数前调用，只做只能在主线程做的事（例如读服务启停集合、
/// 标记未正常结束的运行）。记录读取由存储层串行队列完成，再回到主线程更新页面。
@property(nonatomic,copy,nullable) dispatch_block_t willRefreshRuns;
@property(nonatomic,copy,nullable) void (^onSelectRun)(NSDictionary *run);
@property(nonatomic,copy,nullable) dispatch_block_t onExportAll;
@property(nonatomic,copy,nullable) dispatch_block_t onClearAll;
- (void)reloadThemeAppearance;
@end

NS_ASSUME_NONNULL_END
