#import "PluginRunHistoryViewController.h"
#import "HostTheme.h"
#import "LogCenterViewController.h"

@interface PluginRunHistoryViewController ()
@property(nonatomic,copy) NSArray<NSDictionary *> *runs;
@property(nonatomic,strong) UILabel *emptyLabel;
@property(nonatomic,assign) BOOL refreshScheduled;
@property(nonatomic) BOOL refreshingRuns;
- (void)confirmClearAll;
- (void)  refreshRuns;
@end

@implementation PluginRunHistoryViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=[NSString stringWithFormat:@"%@ · 日志",self.serviceName.length?self.serviceName:@"服务"];self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;self.tableView.accessibilityIdentifier=@"plugin.run-history.list";
    __weak typeof(self) weakSelf=self;UIDeferredMenuElement *dynamicItems=[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)){PluginRunHistoryViewController *owner=weakSelf;BOOL hasRuns=owner&&owner.runs.count>0;UIAction *export=[UIAction actionWithTitle:@"导出全部运行日志" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction *action){if(weakSelf.onExportAll)weakSelf.onExportAll();}];if(!hasRuns)export.attributes=UIMenuElementAttributesDisabled;UIAction *clear=[UIAction actionWithTitle:@"清除全部运行日志" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action){[weakSelf confirmClearAll];}];clear.attributes=UIMenuElementAttributesDestructive;if(!hasRuns)clear.attributes|=UIMenuElementAttributesDisabled;completion(@[export,clear]);}];UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"运行日志" children:@[dynamicItems]]];more.accessibilityLabel=@"运行日志操作";self.navigationItem.rightBarButtonItem=more;
    self.emptyLabel=[UILabel new];self.emptyLabel.text=@"还没有运行记录\n启动这个脚本后，每次运行都会单独保存";self.emptyLabel.numberOfLines=0;self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.emptyLabel.adjustsFontForContentSizeCategory=YES;self.tableView.backgroundView=self.emptyLabel;
    UIRefreshControl *rc=[UIRefreshControl new];[rc addTarget:self action:@selector(refreshRuns) forControlEvents:UIControlEventValueChanged];self.refreshControl=rc;
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
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {[super traitCollectionDidChange:previousTraitCollection];if(previousTraitCollection&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){HostRefreshAppearanceLayers(self.view.window);[self reloadThemeAppearance];}}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self refreshRuns];}
- (void)scheduleRefresh {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf scheduleRefresh];});return;}if(!self.isViewLoaded||!self.view.window||self.refreshScheduled)return;self.refreshScheduled=YES;__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{weakSelf.refreshScheduled=NO;if(weakSelf.isViewLoaded&&weakSelf.view.window)[weakSelf refreshRuns];});}
- (void)refreshRuns {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self refreshRuns];});return;}
    if(self.refreshingRuns)return;self.refreshingRuns=YES;
    NSArray *(^provider)(void)=[self.runRecordsProvider copy];__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSArray *runs=provider?provider():@[];dispatch_async(dispatch_get_main_queue(),^{
        PluginRunHistoryViewController *owner=weakSelf;if(!owner)return;owner.refreshingRuns=NO;
        owner.runs=[runs isKindOfClass:NSArray.class]?runs:@[];owner.emptyLabel.hidden=owner.runs.count>0;owner.tableView.backgroundView.hidden=owner.runs.count>0;[owner.refreshControl endRefreshing];[owner.tableView reloadData];
    });});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 1;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.runs.count;}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return self.runs.count?[NSString stringWithFormat:@"%lu 次运行 · 点开查看本次日志",(unsigned long)self.runs.count]:nil;}
- (NSString *)formattedDate:(NSTimeInterval)timestamp {if(timestamp<=0)return @"时间未知";static NSDateFormatter *formatter;static dispatch_once_t once;dispatch_once(&once,^{formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss";});@synchronized(formatter){return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];}}
- (NSString *)formattedSize:(unsigned long long)size {if(size<1024)return [NSString stringWithFormat:@"%llu B",size];if(size<1024*1024)return [NSString stringWithFormat:@"%.1f KB",size/1024.0];return [NSString stringWithFormat:@"%.1f MB",size/(1024.0*1024.0)];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse=@"plugin.run-history.row";UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    if(indexPath.row<0||indexPath.row>=self.runs.count)return cell;
    NSDictionary *run=self.runs[indexPath.row];if(![run isKindOfClass:NSDictionary.class])return cell;
    BOOL legacy=[run[@"legacy"] boolValue];NSString *runID=[run[@"runID"] isKindOfClass:NSString.class]?run[@"runID"]:@"unknown";cell.textLabel.text=legacy?@"更新前的历史日志":[NSString stringWithFormat:@"运行 · %@",[self formattedDate:[run[@"startedAt"] doubleValue]]];cell.textLabel.numberOfLines=0;cell.detailTextLabel.text=[NSString stringWithFormat:@"%@  ·  %@",run[@"status"]?:@"运行记录",[self formattedSize:[run[@"size"] unsignedLongLongValue]]];cell.imageView.image=[UIImage systemImageNamed:legacy?@"archivebox.fill":(indexPath.row==0?@"bolt.horizontal.circle.fill":@"clock.arrow.circlepath")];cell.imageView.tintColor=indexPath.row==0?HostAccent():HostSecondaryText();cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;UIView *bar=[cell.contentView viewWithTag:9301];if(!bar){bar=[UIView new];bar.tag=9301;bar.translatesAutoresizingMaskIntoConstraints=NO;bar.layer.cornerRadius=1.5;bar.userInteractionEnabled=NO;[cell.contentView addSubview:bar];[NSLayoutConstraint activateConstraints:@[[bar.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:2],[bar.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],[bar.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],[bar.widthAnchor constraintEqualToConstant:3]]];}bar.backgroundColor=legacy?HostMutedText():(indexPath.row==0?HostAccent():[HostAccent() colorWithAlphaComponent:0.35]);cell.accessibilityIdentifier=[@"plugin.run-history.row." stringByAppendingString:runID];return cell;
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
        UIAction *copy=[UIAction actionWithTitle:@"复制运行记录摘要" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){PluginRunHistoryViewController *owner=weakSelf;if(!owner)return;UIPasteboard.generalPasteboard.string=summary;owner.navigationItem.prompt=@"运行记录摘要已复制";dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{PluginRunHistoryViewController *cbOwner=weakSelf;if(cbOwner&&[cbOwner.navigationItem.prompt isEqualToString:@"运行记录摘要已复制"])cbOwner.navigationItem.prompt=nil;});}];
        return [UIMenu menuWithTitle:title children:@[open,copy]];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {if(indexPath.row<0||indexPath.row>=self.runs.count)return;NSDictionary *run=self.runs[indexPath.row];if(![run isKindOfClass:NSDictionary.class])return;[tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.onSelectRun)self.onSelectRun(run);}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];if(!cell||UIAccessibilityIsReduceMotionEnabled())return;[UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{cell.transform=CGAffineTransformMakeScale(0.985,0.985);} completion:nil];}
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];if(!cell)return;[UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{cell.transform=CGAffineTransformIdentity;} completion:nil];}
- (void)confirmClearAll {UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除全部运行日志？" message:@"将删除这个脚本的所有运行记录及升级前历史日志。服务代码和配置不会改变。此操作无法撤销。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weakSelf=self;[alert addAction:[UIAlertAction actionWithTitle:@"清除日志" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){if(weakSelf.onClearAll)weakSelf.onClearAll();[weakSelf refreshRuns];}]];[self presentViewController:alert animated:YES completion:nil];}
@end
