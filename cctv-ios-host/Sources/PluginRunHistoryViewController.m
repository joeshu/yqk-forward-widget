#import "PluginRunHistoryViewController.h"
#import "HostTheme.h"
#import "LogCenterViewController.h"

@interface PluginRunHistoryViewController ()
@property(nonatomic,copy) NSArray<NSDictionary *> *runs;
@property(nonatomic,strong) UILabel *emptyLabel;
@property(nonatomic,assign) BOOL refreshScheduled;
@end

@implementation PluginRunHistoryViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=[NSString stringWithFormat:@"%@ · 日志",self.serviceName.length?self.serviceName:@"服务"];self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;self.tableView.accessibilityIdentifier=@"plugin.run-history.list";
    __weak typeof(self) weakSelf=self;UIAction *export=[UIAction actionWithTitle:@"导出全部运行日志" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction *action){if(weakSelf.onExportAll)weakSelf.onExportAll();}];UIAction *clear=[UIAction actionWithTitle:@"清除全部运行日志" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action){[weakSelf confirmClearAll];}];UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"运行日志" children:@[export,clear]]];more.accessibilityLabel=@"运行日志操作";self.navigationItem.rightBarButtonItem=more;
    self.emptyLabel=[UILabel new];self.emptyLabel.text=@"还没有运行记录\n启动这个脚本后，每次运行都会单独保存";self.emptyLabel.numberOfLines=0;self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.emptyLabel.adjustsFontForContentSizeCategory=YES;self.tableView.backgroundView=self.emptyLabel;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleRefresh) name:CCTVHostDiagnosticLogDidUpdateNotification object:nil];[self refreshRuns];
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();
    self.tableView.backgroundColor=HostBackground();
    self.emptyLabel.textColor=HostSecondaryText();
    [self.tableView reloadData];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self refreshRuns];}
- (void)scheduleRefresh {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf scheduleRefresh];});return;}if(self.refreshScheduled)return;self.refreshScheduled=YES;__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{weakSelf.refreshScheduled=NO;[weakSelf refreshRuns];});}
- (void)refreshRuns {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf refreshRuns];});return;}NSArray *runs=self.runRecordsProvider?self.runRecordsProvider():@[];self.runs=[runs isKindOfClass:NSArray.class]?runs:@[];self.emptyLabel.hidden=self.runs.count>0;self.tableView.backgroundView.hidden=self.runs.count>0;[self.tableView reloadData];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 1;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.runs.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return self.runs.count?[NSString stringWithFormat:@"%lu 次运行 · 点开查看本次日志",(unsigned long)self.runs.count]:nil;}
- (NSString *)formattedDate:(NSTimeInterval)timestamp {if(timestamp<=0)return @"时间未知";static NSDateFormatter *formatter;static dispatch_once_t once;dispatch_once(&once,^{formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss";});return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];}
- (NSString *)formattedSize:(unsigned long long)size {if(size<1024)return [NSString stringWithFormat:@"%llu B",size];if(size<1024*1024)return [NSString stringWithFormat:@"%.1f KB",size/1024.0];return [NSString stringWithFormat:@"%.1f MB",size/(1024.0*1024.0)];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse=@"plugin.run-history.row";UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    if(indexPath.row<0||indexPath.row>=self.runs.count)return cell;
    NSDictionary *run=self.runs[indexPath.row];if(![run isKindOfClass:NSDictionary.class])return cell;
    BOOL legacy=[run[@"legacy"] boolValue];NSString *runID=[run[@"runID"] isKindOfClass:NSString.class]?run[@"runID"]:@"unknown";cell.textLabel.text=legacy?@"更新前的历史日志":[NSString stringWithFormat:@"运行 · %@",[self formattedDate:[run[@"startedAt"] doubleValue]]];cell.textLabel.numberOfLines=0;cell.detailTextLabel.text=[NSString stringWithFormat:@"%@  ·  %@",run[@"status"]?:@"运行记录",[self formattedSize:[run[@"size"] unsignedLongLongValue]]];cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.accessibilityIdentifier=[@"plugin.run-history.row." stringByAppendingString:runID];return cell;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if(indexPath.row<0||indexPath.row>=self.runs.count)return nil;
    NSDictionary *run=self.runs[indexPath.row];
    if(![run isKindOfClass:NSDictionary.class])return nil;
    BOOL legacy=[run[@"legacy"] boolValue];
    NSString *title=legacy?@"更新前的历史日志":[NSString stringWithFormat:@"运行 · %@",[self formattedDate:[run[@"startedAt"] doubleValue]]];
    NSString *detail=[NSString stringWithFormat:@"%@ · %@",run[@"status"]?:@"运行记录",[self formattedSize:[run[@"size"] unsignedLongLongValue]]];
    NSString *summary=[NSString stringWithFormat:@"%@ (%@)",title,detail];
    __weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:run[@"runID"]?:@"run" previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        UIAction *open=[UIAction actionWithTitle:@"查看本次运行日志" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(__unused UIAction *a){if(weakSelf.onSelectRun)weakSelf.onSelectRun(run);}];
        UIAction *copy=[UIAction actionWithTitle:@"复制运行记录摘要" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=summary;}];
        return [UIMenu menuWithTitle:title children:@[open,copy]];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {if(indexPath.row<0||indexPath.row>=self.runs.count)return;NSDictionary *run=self.runs[indexPath.row];if(![run isKindOfClass:NSDictionary.class])return;[tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.onSelectRun)self.onSelectRun(run);}
- (void)confirmClearAll {UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除全部运行日志？" message:@"将删除这个脚本的所有运行记录及升级前历史日志。服务代码和配置不会改变。此操作无法撤销。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weakSelf=self;[alert addAction:[UIAlertAction actionWithTitle:@"清除日志" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){if(weakSelf.onClearAll)weakSelf.onClearAll();}]];[self presentViewController:alert animated:YES completion:nil];}
@end
