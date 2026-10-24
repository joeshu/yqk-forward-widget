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
@property(nonatomic,strong) UILabel *messageLabel;
@property(nonatomic,strong) UIView *categoryDot;
@end

@implementation DiagnosticLogLineCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if((self=[super initWithStyle:style reuseIdentifier:reuseIdentifier])){
        self.backgroundColor=UIColor.clearColor;
        self.selectionStyle=UITableViewCellSelectionStyleNone;
        UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=HostCard();card.layer.cornerRadius=13;card.layer.cornerCurve=kCACornerCurveContinuous;
        [self.contentView addSubview:card];
        self.categoryDot=[UIView new];self.categoryDot.translatesAutoresizingMaskIntoConstraints=NO;self.categoryDot.layer.cornerRadius=3;
        self.messageLabel=[UILabel new];self.messageLabel.translatesAutoresizingMaskIntoConstraints=NO;self.messageLabel.numberOfLines=0;self.messageLabel.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];self.messageLabel.textColor=HostMutedText();self.messageLabel.lineBreakMode=NSLineBreakByCharWrapping;
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
@end

@implementation LogCenterViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=self.scopeName.length?[NSString stringWithFormat:@"%@日志",self.scopeName]:@"运行日志";
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor=UIColor.blackColor;
    self.view.tintColor=HostAccent();
    self.allLines=@[];self.visibleLines=@[];

    __weak typeof(self) weakSelf=self;
    UIBarButtonItem *export=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"] style:UIBarButtonItemStylePlain target:self action:@selector(exportLog)];export.accessibilityLabel=@"导出日志";
    UIAction *copy=[UIAction actionWithTitle:@"复制当前结果" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action){[weakSelf copyVisibleLog];}];
    UIAction *clear=[UIAction actionWithTitle:@"清空日志" image:[UIImage systemImageNamed:@"trash"] identifier:nil attributes:UIMenuElementAttributesDestructive handler:^(__unused UIAction *action){[weakSelf confirmClearLog];}];
    UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] menu:[UIMenu menuWithTitle:@"日志操作" children:@[copy,clear]]];more.accessibilityLabel=@"更多日志操作";
    self.navigationItem.rightBarButtonItems=@[more,export];

    self.categories=[[UISegmentedControl alloc] initWithItems:@[@"全部",@"播放",@"插件",@"错误"]];self.categories.translatesAutoresizingMaskIntoConstraints=NO;self.categories.selectedSegmentIndex=0;self.categories.selectedSegmentTintColor=HostAccent();[self.categories addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    self.searchBar=[UISearchBar new];self.searchBar.translatesAutoresizingMaskIntoConstraints=NO;self.searchBar.delegate=self;self.searchBar.placeholder=@"搜索日志内容";self.searchBar.searchBarStyle=UISearchBarStyleMinimal;self.searchBar.barStyle=UIBarStyleBlack;self.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.searchBar.accessibilityIdentifier=@"diagnostic.logs.search";
    self.summaryLabel=[UILabel new];self.summaryLabel.translatesAutoresizingMaskIntoConstraints=NO;self.summaryLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium];self.summaryLabel.textColor=UIColor.secondaryLabelColor;
    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];self.tableView.translatesAutoresizingMaskIntoConstraints=NO;self.tableView.backgroundColor=UIColor.blackColor;self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;self.tableView.dataSource=self;self.tableView.delegate=self;self.tableView.estimatedRowHeight=54;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.accessibilityIdentifier=@"diagnostic.logs.list";[self.tableView registerClass:DiagnosticLogLineCell.class forCellReuseIdentifier:@"diagnostic.line"];
    self.emptyLabel=[UILabel new];self.emptyLabel.translatesAutoresizingMaskIntoConstraints=NO;self.emptyLabel.text=@"暂无日志";self.emptyLabel.textColor=UIColor.secondaryLabelColor;self.emptyLabel.font=[UIFont systemFontOfSize:15];self.emptyLabel.textAlignment=NSTextAlignmentCenter;
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
        [self.summaryLabel.heightAnchor constraintEqualToConstant:22],
        [self.tableView.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:4],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor]
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scheduleRefresh) name:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
    [self refreshLog];
}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self refreshLog];}
- (void)scheduleRefresh {
    if(self.refreshScheduled)return;self.refreshScheduled=YES;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{weakSelf.refreshScheduled=NO;[weakSelf refreshLog];});
}
- (void)refreshLog {
    NSString *text=self.logSnapshotProvider?self.logSnapshotProvider():@"";
    NSMutableArray *lines=[NSMutableArray array];for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])if(line.length)[lines addObject:line];
    self.allLines=lines;[self applyFilter];
}
- (void)applyFilter {
    NSString *query=self.searchBar.text?:@"";NSInteger selected=self.categories.selectedSegmentIndex;NSMutableArray *filtered=[NSMutableArray array];
    for(NSString *line in self.allLines){
        DiagnosticLogCategory category=[self categoryForLine:line];
        if(selected==1&&category!=DiagnosticLogCategoryPlayback)continue;
        if(selected==2&&category!=DiagnosticLogCategoryPlugin)continue;
        if(selected==3&&category!=DiagnosticLogCategoryError)continue;
        if(query.length&&[line rangeOfString:query options:NSCaseInsensitiveSearch].location==NSNotFound)continue;
        [filtered addObject:line];
    }
    self.visibleLines=filtered;self.summaryLabel.text=[NSString stringWithFormat:@"共 %lu 条 · 实时刷新",(unsigned long)filtered.count];self.emptyLabel.hidden=filtered.count>0;self.tableView.hidden=filtered.count==0;[self.tableView reloadData];
    if(filtered.count&&query.length==0&&selected==0)[self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:filtered.count-1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
}
- (DiagnosticLogCategory)categoryForLine:(NSString *)line {
    NSString *lower=line.lowercaseString;
    for(NSString *word in @[@"失败",@"错误",@"异常",@"超时",@"拒绝",@"crash",@"fatal"])if([lower containsString:word])return DiagnosticLogCategoryError;
    for(NSString *word in @[@"python",@"javascript",@"插件",@"服务",@"spider",@"node",@"js "])if([lower containsString:word])return DiagnosticLogCategoryPlugin;
    for(NSString *word in @[@"播放",@"起播",@"首帧",@"切台",@"vdn",@"sdk",@"时移",@"回看",@"卡顿",@"线路"])if([lower containsString:word])return DiagnosticLogCategoryPlayback;
    return DiagnosticLogCategoryGeneral;
}
- (UIColor *)colorForLine:(NSString *)line {
    switch([self categoryForLine:line]){case DiagnosticLogCategoryError:return [UIColor colorWithRed:1 green:0.34 blue:0.38 alpha:1];case DiagnosticLogCategoryPlayback:return [UIColor colorWithRed:0.36 green:0.75 blue:1 alpha:1];case DiagnosticLogCategoryPlugin:return [UIColor colorWithRed:0.76 green:0.56 blue:1 alpha:1];default:return HostMutedText();}
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return self.visibleLines.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DiagnosticLogLineCell *cell=[tableView dequeueReusableCellWithIdentifier:@"diagnostic.line" forIndexPath:indexPath];NSString *line=self.visibleLines[indexPath.row];UIColor *color=[self colorForLine:line];cell.messageLabel.text=line;cell.messageLabel.textColor=color;cell.categoryDot.backgroundColor=color;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {UIPasteboard.generalPasteboard.string=self.visibleLines[indexPath.row];[tableView deselectRowAtIndexPath:indexPath animated:YES];}
- (void)filterChanged {[self applyFilter];}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {[self applyFilter];}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {[searchBar resignFirstResponder];}
- (void)exportLog {if(self.onExportLog)self.onExportLog();}
- (void)copyVisibleLog {UIPasteboard.generalPasteboard.string=[self.visibleLines componentsJoinedByString:@"\n"]?:@"";}
- (void)confirmClearLog {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清空日志" message:@"将清除当前日志文件和内存中的日志记录。此操作无法撤销。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;[alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){if(weakSelf.onClearLog)weakSelf.onClearLog();[weakSelf refreshLog];}]];[self presentViewController:alert animated:YES completion:nil];
}
@end
