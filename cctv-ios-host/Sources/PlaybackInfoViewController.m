#import "PlaybackInfoViewController.h"
#import "HostTheme.h"

@interface PlaybackInfoViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
@end

@implementation PlaybackInfoViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = @"播放信息";
    self.view.tintColor = HostAccent();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorColor = HostSeparator();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"暂无播放信息\n请先播放一个频道，再打开本页查看。";
    self.emptyLabel.textColor = HostSecondaryText();
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;
    self.tableView.backgroundView = self.emptyLabel;
    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(copyAllDiagnostics)];
    copyItem.accessibilityIdentifier = @"playback.info.copy";
    copyItem.accessibilityLabel = @"复制播放诊断信息";
    self.navigationItem.rightBarButtonItem = copyItem;
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(refreshSnapshot) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self refreshSnapshot];
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorColor = HostSeparator();
    self.emptyLabel.textColor = HostSecondaryText();
    [self.tableView reloadData];
}

- (void)showTransientPrompt:(NSString *)prompt {
    self.navigationItem.prompt = prompt;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([weakSelf.navigationItem.prompt isEqualToString:prompt]) {
            weakSelf.navigationItem.prompt = nil;
        }
    });
}

- (void)copyAllDiagnostics {
    if (!self.snapshotRows.count) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:self.snapshotRows.count];
    for (NSDictionary *row in self.snapshotRows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        [lines addObject:[NSString stringWithFormat:@"%@：%@", [(row[@"title"]?:@"") description], [(row[@"value"]?:@"") description]]];
    }
    UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    [self showTransientPrompt:@"已复制全部播放诊断信息"];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"已复制全部播放诊断信息");
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self refreshSnapshot]; }
- (void)refreshSnapshot { NSArray *rows=@[];if(self.rowsProvider){@try{rows=self.rowsProvider()?:@[];}@catch(NSException *e){rows=@[];}}self.snapshotRows=[rows isKindOfClass:NSArray.class]?rows:@[];self.emptyLabel.hidden=self.snapshotRows.count>0;[self.refreshControl endRefreshing];if(self.isViewLoaded)[self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.snapshotRows.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.snapshotRows.count ? @"实时播放链路指标 · 点按任意行可复制" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.row>=self.snapshotRows.count)return [UITableViewCell new];NSDictionary *row = [self.snapshotRows[ip.row] isKindOfClass:NSDictionary.class]?self.snapshotRows[ip.row]:@{};
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"playback.info.row"];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"playback.info.row"];
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 13;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.clipsToBounds = YES;
    c.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(c, HostBorder());
    NSString *titleText = [(row[@"title"]?:@"") description];
    c.textLabel.text = titleText;
    c.detailTextLabel.text = [(row[@"value"]?:@"") description];
    NSString *symbol = [titleText containsString:@"带宽"]||[titleText containsString:@"速率"]?@"speedometer":([titleText containsString:@"分辨率"]||[titleText containsString:@"画面"]?@"rectangle.expand.vertical":([titleText containsString:@"节点"]||[titleText containsString:@"线路"]||[titleText containsString:@"地址"]?@"network":@"waveform.path.ecg"));
    c.imageView.image = [UIImage systemImageNamed:symbol];
    c.imageView.tintColor = HostAccent();
    c.textLabel.textColor = HostText();
    c.detailTextLabel.textColor = HostSecondaryText();
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    c.textLabel.adjustsFontForContentSizeCategory=YES;c.textLabel.numberOfLines=0;
    c.detailTextLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]];
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    c.accessibilityHint = @"点按复制此项指标";
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.row >= self.snapshotRows.count) return;
    NSDictionary *row = [self.snapshotRows[ip.row] isKindOfClass:NSDictionary.class] ? self.snapshotRows[ip.row] : @{};
    NSString *line = [NSString stringWithFormat:@"%@：%@", [(row[@"title"]?:@"") description], [(row[@"value"]?:@"") description]];
    UIPasteboard.generalPasteboard.string = line;
    [self showTransientPrompt:@"指标已复制"];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"指标已复制");
}
@end
