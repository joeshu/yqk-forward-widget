#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PluginRunHistoryViewController : UITableViewController
@property(nonatomic,copy,nullable) NSString *serviceName;
@property(nonatomic,copy,nullable) NSArray<NSDictionary *> *(^runRecordsProvider)(void);
/// 主线程回调：每次取数前调用，只做只能在主线程做的事（例如读服务启停集合、
/// 标记未正常结束的运行）。取数本身在后台进行，provider 里不得再同步跳回
/// 主线程——后台 provider 同步等主线程是 2026-11-26 SE 冒烟 rows=0  stall
/// 的头号嫌疑（取数从未落定）；拆出来后 provider 只有磁盘读。
@property(nonatomic,copy,nullable) dispatch_block_t willRefreshRuns;
@property(nonatomic,copy,nullable) void (^onSelectRun)(NSDictionary *run);
@property(nonatomic,copy,nullable) dispatch_block_t onExportAll;
@property(nonatomic,copy,nullable) dispatch_block_t onClearAll;
- (void)reloadThemeAppearance;
@end

NS_ASSUME_NONNULL_END
