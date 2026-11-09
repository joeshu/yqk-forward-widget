#import "LogCenterViewController.h"
#import "HostTheme.h"

NSNotificationName const CCTVHostDiagnosticLogDidUpdateNotification = @"CCTVHostDiagnosticLogDidUpdateNotification";

typedef NS_ENUM(NSInteger, DiagnosticLogCategory) {
    DiagnosticLogCategoryGeneral,
    DiagnosticLogCategoryPlayback,
    DiagnosticLogCategoryPlugin,
    DiagnosticLogCategoryError,
};

@interface DiagnosticLogLineCell : UITableViewCell
@property(nonatomic,strong) UIView *cardView;
@property(nonatomic,strong) UILabel *messageLabel;
@property(nonatomic,strong) UIView *categoryDot;
@end

@implementation DiagnosticLogLineCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if((self=[super initWithStyle:style reuseIdentifier:reuseIdentifier])){
        self.backgroundColor=UIColor.clearColor;
        self.selectionStyle=UITableViewCellSelectionStyleNone;
        UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=HostCard();card.layer.cornerRadius=14;card.layer.cornerCurve=kCACornerCurveContinuous;card.layer.borderWidth=0.6;HostSetLayerBorderColor(card,HostBorder());
        self.cardView=card;
        [self.contentView addSubview:card];
        self.categoryDot=[UIView new];self.categoryDot.translatesAutoresizingMaskIntoConstraints=NO;self.categoryDot.layer.cornerRadius=3;
        self.messageLabel=[UILabel new];self.messageLabel.translatesAutoresizingMaskIntoConstraints=NO;self.messageLabel.numberOfLines=0;self.messageLabel.font=[[UIFontMetrics defaultMetrics] scaledFontForFont:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]];self.messageLabel.adjustsFontForContentSizeCategory=YES;self.messageLabel.textColor=HostMutedText();self.messageLabel.lineBreakMode=NSLineBreakByCharWrapping;
        [card addSubview:self.categoryDot];[card addSubview:self.messageLabel];
        [NSLayoutConstraint activateConstraints:@[
            [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],
            [card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
            [self.categoryDot.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
            [self.categoryDot.topAnchor constraintEqualToAnchor:card.topAnchor constant:15],
            [self.categoryDot.widthAnchor constraintEqualToConstant:6],
            [self.categoryDot.heightAnchor constraintEqualToConstant:6],
            [self.messageLabel.leadingAnchor constraintEqualToAnchor:self.categoryDot.trailingAnchor constant:10],
            [self.messageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
            [self.messageLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:10],
            [self.messageLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10]
        ]];
    }
    return self;
}
@end

@interface LogCenterViewController () <UITableViewDataSource,UITableViewDelegate,UISearchBarDelegate>
@property(nonatomic,strong) UISegmentedControl *categories;
@property(nonatomic,strong) UISearchBar *searchBar;
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UILabel *summaryLabel;
@property(nonatomic,strong) UILabel *emptyLabel;
@property(nonatomic,copy) NSArray<NSString *> *allLines;
@property(nonatomic,copy) NSArray<NSString *> *visibleLines;
@property(nonatomic) BOOL refreshScheduled;
@property(nonatomic) BOOL pageVisible;
@property(nonatomic) BOOL observingLogUpdates;
@property(nonatomic) BOOL hasLoadedSnapshot;
- (void)applyFilterFollowingTail:(BOOL)followsTail;
@end

@implementation LogCenterViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.title=self.titleOverride.length?self.titleOverride:(self.scopeName.length?[NSString stringWithFormat:@"%@日志",self.scopeName]:@"运行日志");
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor=HostBackground();
    self.view.tintColor=HostAccent();
    self.allLines=@[];self.visibleLines=@[];

    __weak typeof(self) weakSelf=self;
    UIBarButtonItem *export=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"] style:UIBarButtonItemStylePlain target:self action:@selector(exportLog)];export.accessibilityLabel=@"导出日志";
    UIAction *scrollBottom=[UIAction actionWithTitle:@"跳到最新末尾" image:[UIImage systemImageNamed:@"arrow.down.to.line"] identifier:nil handler:^(__unused UIAction *action){[weakSelf scrollToBottomLog];}];
    UIAction *copy=[UIAction actionWithTitle:@"复制当前结果" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action){[weakSelf copyVisibleLog];}];
    UIAction *copyErrors=[UIAction actionWithTitle:@"仅复制错误日志" image:[UIImage systemImageNamed:@"exclamationmark.triangle"] identifier:nil handler:^(__unused UIAction *action){[weakSelf copyErrorLog];}];
    UIAction *clear=[UIAction actionWithTitle:self.clearActionTitle.length?self.clearActionTitle:@"清空日志" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(__unused UIAction *action){[weakSelf confirmClearLog];}];
    UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"日志操作" children:@[scrollBottom,copy,copyErrors,clear]]];more.accessibilityLabel=@"更多日志操作";
    self.navigationItem.rightBarButtonItems=@[more,export];

    self.categories=[[UISegmentedControl alloc] initWithItems:@[@"全部",@"播放",@"插件",@"错误"]];self.categories.translatesAutoresizingMaskIntoConstraints=NO;self.categories.selectedSegmentIndex=0;self.categories.selectedSegmentTintColor=HostAccent();[self.categories setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];[self.categories setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateSelected];[self.categories addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    self.searchBar=[UISearchBar new];self.searchBar.translatesAutoresizingMaskIntoConstraints=NO;self.searchBar.delegate=self;self.searchBar.placeholder=@"搜索日志内容";self.searchBar.searchBarStyle=UISearchBarStyleMinimal;self.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.searchBar.accessibilityIdentifier=@"diagnostic.logs.search";
    self.summaryLabel=[UILabel new];self.summaryLabel.translatesAutoresizingMaskIntoConstraints=NO;self.summaryLabel.numberOfLines=0;self.summaryLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.summaryLabel.adjustsFontForContentSizeCategory=YES;self.summaryLabel.textColor=HostSecondaryText();
    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];self.tableView.translatesAutoresizingMaskIntoConstraints=NO;self.tableView.backgroundColor=HostBackground();self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;self.tableView.dataSource=self;self.tableView.delegate=self;self.tableView.estimatedRowHeight=54;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.accessibilityIdentifier=@"diagnostic.logs.list";[self.tableView registerClass:DiagnosticLogLineCell.class forCellReuseIdentifier:@"diagnostic.line"];
    self.emptyLabel=[UILabel new];self.emptyLabel.translatesAutoresizingMaskIntoConstraints=NO;self.emptyLabel.numberOfLines=0;self.emptyLabel.text=@"暂无日志";self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.emptyLabel.adjustsFontForContentSizeCategory=YES;self.emptyLabel.textAlignment=NSTextAlignmentCenter;
    [self.view addSubview:self.categories];[self.view addSubview:self.searchBar];[self.view addSubview:self.summaryLabel];[self.view addSubview:self.tableView];[self.view addSubview:self.emptyLabel];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.categories.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [self.categories.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.categories.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.searchBar.topAnchor constraintEqualToAnchor:self.categories.bottomAnchor constant:5],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:0],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:18],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
        // 统计行固定 22pt 在超大字体下会被截断：只定下限，让它随字体换行长高。
        [self.summaryLabel.heightAnchor constraintGreaterThanOrEqualToConstant:22],
        [self.tableView.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:4],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
        [self.emptyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24]
    ]];
}
- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.backgroundColor=HostBackground();
    self.view.tintColor=HostAccent();
    self.categories.selectedSegmentTintColor=HostAccent();
    [self.categories setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];
    [self.categories setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateSelected];
    self.summaryLabel.textColor=HostSecondaryText();
    self.emptyLabel.textColor=HostSecondaryText();
    self.tableView.backgroundColor=HostBackground();
    [self.tableView reloadData];
}
- (void)showTransientPrompt:(NSString *)prompt {
    self.navigationItem.prompt=prompt;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if([weakSelf.navigationItem.prompt isEqualToString:prompt])weakSelf.navigationItem.prompt=nil;
    });
}
- (void)scrollToBottomLog {
    if(!self.visibleLines.count)return;
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.visibleLines.count-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:YES];
}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.pageVisible=YES;
    if(!self.observingLogUpdates){
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scheduleRefresh) name:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
        self.observingLogUpdates=YES;
    }
    [self refreshLog];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    self.pageVisible=NO;
    if(self.observingLogUpdates){
        [[NSNotificationCenter defaultCenter] removeObserver:self name:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
        self.observingLogUpdates=NO;
    }
    self.refreshScheduled=NO;
}
- (void)scheduleRefresh {
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf scheduleRefresh];});return;}
    if(!self.pageVisible||self.refreshScheduled)return;self.refreshScheduled=YES;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{LogCenterViewController *owner=weakSelf;if(!owner)return;owner.refreshScheduled=NO;if(owner.pageVisible)[owner refreshLog];});
}
- (void)refreshLog {
    if(!self.pageVisible)return;
    NSString *text=self.logSnapshotProvider?self.logSnapshotProvider():@"";
    NSMutableArray *lines=[NSMutableArray array];for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])if(line.length)[lines addObject:line];
    // 诊断日志源头上限 4 MiB，整串仍可能上万行：只保留末尾 5000 行，避免两份全量数组常驻内存。
    if(lines.count>5000)[lines removeObjectsInRange:NSMakeRange(0,lines.count-5000)];
    if(self.hasLoadedSnapshot&&[self.allLines isEqualToArray:lines])return;
    BOOL followsTail=!self.hasLoadedSnapshot||(self.tableView.window&&self.visibleLines.count>0&&
        self.tableView.contentSize.height-(self.tableView.contentOffset.y+self.tableView.bounds.size.height-self.tableView.adjustedContentInset.bottom)<=48);
    self.allLines=lines;self.hasLoadedSnapshot=YES;[self applyFilterFollowingTail:followsTail];
}
- (void)applyFilter {
    [self applyFilterFollowingTail:NO];
}
- (void)applyFilterFollowingTail:(BOOL)followsTail {
    NSString *query=self.searchBar.text?:@"";NSInteger selected=self.categories.selectedSegmentIndex;NSMutableArray *filtered=[NSMutableArray array];
    NSUInteger errorCount=0,pluginCount=0,playbackCount=0;
    for(NSString *line in self.allLines){
        DiagnosticLogCategory category=[self categoryForLine:line];
        if(category==DiagnosticLogCategoryError)errorCount++;
        else if(category==DiagnosticLogCategoryPlugin)pluginCount++;
        else if(category==DiagnosticLogCategoryPlayback)playbackCount++;
        if(selected==1&&category!=DiagnosticLogCategoryPlayback)continue;
        if(selected==2&&category!=DiagnosticLogCategoryPlugin)continue;
        if(selected==3&&category!=DiagnosticLogCategoryError)continue;
        if(query.length&&[line rangeOfString:query options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
        [filtered addObject:line];
    }
    self.visibleLines=filtered;BOOL filteredByUser=query.length>0||selected!=0;self.summaryLabel.text=[NSString stringWithFormat:@"共 %lu 条%@ · 错误 %lu · 插件 %lu · 播放 %lu · 点按单行可复制",(unsigned long)filtered.count,filteredByUser?@" · 已筛选":@" · 实时刷新",(unsigned long)errorCount,(unsigned long)pluginCount,(unsigned long)playbackCount];self.emptyLabel.text=self.allLines.count?@"没有符合筛选的日志":@"暂无日志";self.emptyLabel.hidden=filtered.count>0;self.tableView.hidden=filtered.count==0;[self.tableView reloadData];
    if(followsTail&&filtered.count&&query.length==0&&selected==0)[self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:filtered.count-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}
- (DiagnosticLogCategory)categoryForLine:(NSString *)line {
    NSString *lower=line.lowercaseString;
    for(NSString *word in @[@"失败",@"错误",@"异常",@"超时",@"拒绝",@"crash",@"fatal"])if([lower containsString:word])return DiagnosticLogCategoryError;
    for(NSString *word in @[@"python",@"javascript",@"插件",@"服务",@"spider",@"node",@"js "])if([lower containsString:word])return DiagnosticLogCategoryPlugin;
    for(NSString *word in @[@"播放",@"起播",@"首帧",@"切台",@"vdn",@"sdk",@"时移",@"回看",@"卡顿",@"线路"])if([lower containsString:word])return DiagnosticLogCategoryPlayback;
    return DiagnosticLogCategoryGeneral;
}
- (UIColor *)colorForLine:(NSString *)line {
    // 分类色必须用随深浅模式自适应的系统语义色：上一轮的硬编码 RGB
    //（错误 #FF575E / 播放 #5CBFFF / 插件 #C28FFF）在晨光白、雪原白两套
    // 浅色主题下对比度不足（浅蓝在白卡上约 2:1），11pt 等宽正文难读。
    switch([self categoryForLine:line]){case DiagnosticLogCategoryError:return UIColor.systemRedColor;case DiagnosticLogCategoryPlayback:return UIColor.systemBlueColor;case DiagnosticLogCategoryPlugin:return UIColor.systemPurpleColor;default:return HostMutedText();}
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return self.visibleLines.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DiagnosticLogLineCell *cell=[tableView dequeueReusableCellWithIdentifier:@"diagnostic.line" forIndexPath:indexPath];if(indexPath.row<0||indexPath.row>=self.visibleLines.count)return cell;NSString *line=self.visibleLines[indexPath.row];DiagnosticLogCategory cat=[self categoryForLine:line];UIColor *color=[self colorForLine:line];cell.cardView.backgroundColor=HostCard();cell.cardView.layer.borderWidth=cat==DiagnosticLogCategoryError?0.9:0.6;HostSetLayerBorderColor(cell.cardView,cat==DiagnosticLogCategoryError?[UIColor.systemRedColor colorWithAlphaComponent:0.45]:HostBorder());cell.messageLabel.attributedText=nil;cell.messageLabel.text=line;cell.messageLabel.textColor=color;NSString *q=self.searchBar.text?:@"";if(q.length){NSRange match=[line rangeOfString:q options:NSCaseInsensitiveSearch];if(match.location!=NSNotFound){NSMutableAttributedString *attr=[[NSMutableAttributedString alloc] initWithString:line attributes:@{NSForegroundColorAttributeName:color,NSFontAttributeName:cell.messageLabel.font}];[attr addAttributes:@{NSBackgroundColorAttributeName:[HostAccent() colorWithAlphaComponent:0.25],NSForegroundColorAttributeName:HostText()} range:match];cell.messageLabel.attributedText=attr;}}cell.categoryDot.backgroundColor=color;cell.accessibilityHint=@"点按复制这行日志";return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {if(indexPath.row<self.visibleLines.count){UIPasteboard.generalPasteboard.string=self.visibleLines[indexPath.row];[self showTransientPrompt:@"日志内容已复制"];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"日志内容已复制");}[tableView deselectRowAtIndexPath:indexPath animated:YES];}
- (void)filterChanged {[self applyFilter];}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {[self applyFilter];}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {[searchBar resignFirstResponder];}
- (void)exportLog {if(self.onExportLog)self.onExportLog();}
- (void)copyVisibleLog {UIPasteboard.generalPasteboard.string=[self.visibleLines componentsJoinedByString:@"\n"]?:@"";[self showTransientPrompt:@"当前筛选的日志已复制"];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"当前筛选的日志已复制");}
- (void)copyErrorLog {NSMutableArray *errs=[NSMutableArray array];for(NSString *line in self.allLines)if([self categoryForLine:line]==DiagnosticLogCategoryError)[errs addObject:line];UIPasteboard.generalPasteboard.string=[errs componentsJoinedByString:@"\n"]?:@"";[self showTransientPrompt:errs.count?@"错误日志已复制":@"当前暂无错误日志"];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"错误日志已复制");}
- (void)confirmClearLog {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:self.clearActionTitle.length?self.clearActionTitle:@"清空日志" message:self.clearConfirmationMessage.length?self.clearConfirmationMessage:@"将清除当前日志文件和内存中的日志记录。此操作无法撤销。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;[alert addAction:[UIAlertAction actionWithTitle:self.clearActionTitle.length?self.clearActionTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){if(weakSelf.onClearLog)weakSelf.onClearLog();[weakSelf refreshLog];}]];[self presentViewController:alert animated:YES completion:nil];
}
@end
