#import "PlaybackInfoViewController.h"
#import "HostTheme.h"

@interface PlaybackInfoViewController ()
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *snapshotSections;
@property (nonatomic, strong) NSDictionary *snapshotSummary;
@property (nonatomic, strong) NSTimer *autoRefreshTimer;
@property (nonatomic, strong) UIView *summaryHeaderContainer;
@property (nonatomic, strong) UIView *summaryCardView;
@property (nonatomic, strong) UIView *summarySpecularLine;
@property (nonatomic, strong) UILabel *summaryChannelLabel;
@property (nonatomic, strong) UILabel *summaryEngineBadge;
@property (nonatomic, strong) UIButton *liveRefreshToggleButton;
@property (nonatomic, assign) BOOL autoRefreshPausedByUser;
@property (nonatomic, strong) NSArray<UIView *> *summaryMetricContainers;
@property (nonatomic, strong) NSArray<UILabel *> *summaryMetricValueLabels;
@property (nonatomic, strong) NSArray<UILabel *> *summaryMetricTitleLabels;
- (void)toggleAutoRefreshPause;
- (void)updateLiveRefreshToggleAppearance;
- (void)refreshSnapshot;
-  (void)stopAutoRefreshTimer;
-  (void)buildSummaryHeaderView;
-  (void)startAutoRefreshTimer;
@end

@implementation PlaybackInfoViewController
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _autoRefreshInterval = 1.5;
    }
    return self;
}

- (void)dealloc {
    [self stopAutoRefreshTimer];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = @"播放信息";
    self.view.tintColor = HostAccent();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorColor = HostSeparator();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"暂无播放信息\n请先播放一个频道，再打开本页查看。";
    self.emptyLabel.textColor = HostSecondaryText();
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;
    self.tableView.backgroundView = self.emptyLabel;
    HostInstallGlassBackdrop(self.tableView);

    [self buildSummaryHeaderView];

    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"] style:UIBarButtonItemStylePlain target:self action:@selector(copyAllDiagnostics)];
    copyItem.accessibilityIdentifier = @"playback.info.copy";
    copyItem.accessibilityLabel = @"复制播放诊断信息";
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"] style:UIBarButtonItemStylePlain target:self action:@selector(refreshSnapshot)];
    refreshItem.accessibilityIdentifier = @"playback.info.refresh";
    refreshItem.accessibilityLabel = @"立即刷新播放信息";
    self.navigationItem.rightBarButtonItems = @[copyItem, refreshItem];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(refreshSnapshot) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refresh;
    [self refreshSnapshot];
}

- (void)buildSummaryHeaderView {
    CGFloat width = MAX(320.0, self.view.bounds.size.width > 0 ? self.view.bounds.size.width : 375.0);
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 128)];
    container.backgroundColor = UIColor.clearColor;

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = HostCard();
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.8;
    HostSetLayerBorderColor(card, HostBorder());
    card.accessibilityIdentifier = @"playback.info.summary-card";
    [container addSubview:card];

    UIView *specLine = [UIView new];
    specLine.translatesAutoresizingMaskIntoConstraints = NO;
    specLine.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    specLine.userInteractionEnabled = NO;
    [card addSubview:specLine];
    self.summarySpecularLine = specLine;

    UIButton *liveToggle = [UIButton buttonWithType:UIButtonTypeSystem];
    liveToggle.translatesAutoresizingMaskIntoConstraints = NO;
    liveToggle.titleLabel.font = HostMonospacedDigitFont(10.5, UIFontWeightSemibold, UIFontTextStyleCaption2);
    liveToggle.contentEdgeInsets = UIEdgeInsetsMake(3, 8, 3, 8);
    liveToggle.layer.cornerRadius = 8;
    liveToggle.layer.cornerCurve = kCACornerCurveContinuous;
    liveToggle.layer.borderWidth = 0.55;
    liveToggle.accessibilityIdentifier = @"playback.info.live-toggle";
    HostInstallPressFeedback(liveToggle);
    [liveToggle addTarget:self action:@selector(toggleAutoRefreshPause) forControlEvents:UIControlEventTouchUpInside];
    [liveToggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [liveToggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [card addSubview:liveToggle];
    self.liveRefreshToggleButton = liveToggle;
    [self updateLiveRefreshToggleAppearance];

    UILabel *channelLabel = [UILabel new];
    channelLabel.translatesAutoresizingMaskIntoConstraints = NO;
    channelLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    channelLabel.adjustsFontForContentSizeCategory = YES;
    channelLabel.textColor = HostText();
    channelLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:channelLabel];

    UILabel *engineBadge = [UILabel new];
    engineBadge.translatesAutoresizingMaskIntoConstraints = NO;
    engineBadge.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];
    engineBadge.adjustsFontForContentSizeCategory = YES;
    engineBadge.textColor = HostAccent();
    engineBadge.backgroundColor = HostSelectedSurface();
    engineBadge.textAlignment = NSTextAlignmentCenter;
    engineBadge.layer.cornerRadius = 8;
    engineBadge.layer.cornerCurve = kCACornerCurveContinuous;
    engineBadge.clipsToBounds = YES;
    [engineBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [engineBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [card addSubview:engineBadge];

    UIStackView *grid = [UIStackView new];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 8;
    [card addSubview:grid];

    NSArray<NSString *> *titles = @[@"分辨率", @"实时码率", @"帧率", @"编码"];
    NSMutableArray<UIView *> *pillContainers = [NSMutableArray arrayWithCapacity:4];
    NSMutableArray<UILabel *> *valueLabels = [NSMutableArray arrayWithCapacity:4];
    NSMutableArray<UILabel *> *titleLabels = [NSMutableArray arrayWithCapacity:4];
    for (NSString *title in titles) {
        UIView *pill = [UIView new];
        pill.backgroundColor = HostRaisedSurface();
        pill.layer.cornerRadius = 11;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.borderWidth = 0.55;
        HostSetLayerBorderColor(pill, HostBorder());
        [pillContainers addObject:pill];

        UILabel *val = [UILabel new];
        val.translatesAutoresizingMaskIntoConstraints = NO;
        val.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold]];
        val.adjustsFontForContentSizeCategory = YES;
        val.adjustsFontSizeToFitWidth = YES;
        val.minimumScaleFactor = 0.72;
        val.textColor = HostText();
        val.textAlignment = NSTextAlignmentCenter;
        val.text = @"—";
        [pill addSubview:val];

        UILabel *cap = [UILabel new];
        cap.translatesAutoresizingMaskIntoConstraints = NO;
        cap.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        cap.adjustsFontForContentSizeCategory = YES;
        cap.textColor = HostSecondaryText();
        cap.textAlignment = NSTextAlignmentCenter;
        cap.text = title;
        [pill addSubview:cap];

        [NSLayoutConstraint activateConstraints:@[
            [val.topAnchor constraintEqualToAnchor:pill.topAnchor constant:8],
            [val.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:4],
            [val.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-4],
            [cap.topAnchor constraintEqualToAnchor:val.bottomAnchor constant:2],
            [cap.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:4],
            [cap.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-4],
            [cap.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-7]
        ]];
        [grid addArrangedSubview:pill];
        [valueLabels addObject:val];
        [titleLabels addObject:cap];
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],

        [specLine.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [specLine.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [specLine.topAnchor constraintEqualToAnchor:card.topAnchor],
        [specLine.heightAnchor constraintEqualToConstant:0.5],

        [channelLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [channelLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [liveToggle.centerYAnchor constraintEqualToAnchor:channelLabel.centerYAnchor],
        [liveToggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:channelLabel.trailingAnchor constant:6],
        [liveToggle.heightAnchor constraintEqualToConstant:22],
        [engineBadge.centerYAnchor constraintEqualToAnchor:channelLabel.centerYAnchor],
        [engineBadge.leadingAnchor constraintEqualToAnchor:liveToggle.trailingAnchor constant:6],
        [engineBadge.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [engineBadge.heightAnchor constraintEqualToConstant:22],
        [engineBadge.widthAnchor constraintGreaterThanOrEqualToConstant:58],

        [grid.topAnchor constraintEqualToAnchor:channelLabel.bottomAnchor constant:10],
        [grid.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [grid.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [grid.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12]
    ]];

    self.summaryHeaderContainer = container;
    self.summaryCardView = card;
    self.summaryChannelLabel = channelLabel;
    self.summaryEngineBadge = engineBadge;
    self.summaryMetricContainers = pillContainers;
    self.summaryMetricValueLabels = valueLabels;
    self.summaryMetricTitleLabels = titleLabels;
}

- (void)applySummaryData:(NSDictionary *)summary {
    self.snapshotSummary = [summary isKindOfClass:NSDictionary.class] ? summary : nil;
    if (!self.snapshotSummary.count) {
        self.tableView.tableHeaderView = nil;
        return;
    }
    self.summaryChannelLabel.text = [self.snapshotSummary[@"channelName"] description] ?: @"未选台";
    NSString *engine = [self.snapshotSummary[@"engine"] description] ?: @"等待播放";
    self.summaryEngineBadge.text = [NSString stringWithFormat:@"  %@  ", engine];
    NSArray<NSString *> *values = @[
        [self.snapshotSummary[@"resolution"] description] ?: @"—",
        [self.snapshotSummary[@"bitrate"] description] ?: @"—",
        [self.snapshotSummary[@"fps"] description] ?: @"—",
        [self.snapshotSummary[@"codec"] description] ?: @"—"
    ];
    for (NSUInteger i = 0; i < self.summaryMetricValueLabels.count && i < values.count; i++) {
        NSString *v = values[i].length ? values[i] : @"—";
        UILabel *valLbl = self.summaryMetricValueLabels[i];
        valLbl.text = v;
        if (i == 0 && ([v containsString:@"2160"] || [v containsString:@"1080"] || [v containsString:@"4K"])) valLbl.textColor = HostAccent();
        else if (i == 2 && ([v containsString:@"50"] || [v containsString:@"60"])) valLbl.textColor = UIColor.systemGreenColor;
        else valLbl.textColor = HostText();
    }
    if (self.tableView.tableHeaderView != self.summaryHeaderContainer) {
        CGRect frame = self.summaryHeaderContainer.frame;
        frame.size.width = MAX(320.0, self.tableView.bounds.size.width);
        self.summaryHeaderContainer.frame = frame;
        self.tableView.tableHeaderView = self.summaryHeaderContainer;
    }
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorColor = HostSeparator();
    self.emptyLabel.textColor = HostSecondaryText();
    self.summaryCardView.backgroundColor = HostCard();
    HostSetLayerBorderColor(self.summaryCardView, HostBorder());
    self.summaryChannelLabel.textColor = HostText();
    self.summaryEngineBadge.textColor = HostAccent();
    self.summaryEngineBadge.backgroundColor = HostSelectedSurface();
    for (UIView *pill in self.summaryMetricContainers) { pill.backgroundColor = HostRaisedSurface(); HostSetLayerBorderColor(pill, HostBorder()); }
    for (UILabel *lbl in self.summaryMetricValueLabels) lbl.textColor = HostText();
    for (UILabel *lbl in self.summaryMetricTitleLabels) lbl.textColor = HostSecondaryText();
    [self updateLiveRefreshToggleAppearance];
    [self.tableView reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self reloadThemeAppearance];
    }
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

- (NSArray<NSDictionary *> *)allFlattenedRows {
    if (self.snapshotSections.count) {
        NSMutableArray<NSDictionary *> *flat = [NSMutableArray array];
        for (NSDictionary *sec in self.snapshotSections) {
            NSArray *rows = [sec[@"rows"] isKindOfClass:NSArray.class] ? sec[@"rows"] : @[];
            [flat addObjectsFromArray:rows];
        }
        return flat;
    }
    return self.snapshotRows ?: @[];
}

- (void)copyAllDiagnostics {
    NSArray<NSDictionary *> *allRows = [self allFlattenedRows];
    if (!allRows.count) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:allRows.count];
    for (NSDictionary *row in allRows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        [lines addObject:[NSString stringWithFormat:@"%@：%@", [(row[@"title"]?:@"") description], [(row[@"value"]?:@"") description]]];
    }
    UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    [self showTransientPrompt:@"已复制全部播放诊断信息"];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"已复制全部播放诊断信息");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshSnapshot];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startAutoRefreshTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopAutoRefreshTimer];
}

- (void)toggleAutoRefreshPause {
    self.autoRefreshPausedByUser = !self.autoRefreshPausedByUser;
    if (self.autoRefreshPausedByUser) [self stopAutoRefreshTimer];
    else { [self refreshSnapshot]; [self startAutoRefreshTimer]; }
    [self updateLiveRefreshToggleAppearance];
}

- (void)updateLiveRefreshToggleAppearance {
    if (!self.liveRefreshToggleButton) return;
    if (self.autoRefreshPausedByUser) {
        [self.liveRefreshToggleButton setTitle:@"⏸ 已暂停" forState:UIControlStateNormal];
        self.liveRefreshToggleButton.tintColor = UIColor.systemOrangeColor;
        self.liveRefreshToggleButton.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.14];
        HostSetLayerBorderColor(self.liveRefreshToggleButton, [UIColor.systemOrangeColor colorWithAlphaComponent:0.35]);
    } else {
        [self.liveRefreshToggleButton setTitle:@"● 实时" forState:UIControlStateNormal];
        self.liveRefreshToggleButton.tintColor = UIColor.systemGreenColor;
        self.liveRefreshToggleButton.backgroundColor = HostSuccessSurface();
        HostSetLayerBorderColor(self.liveRefreshToggleButton, [UIColor.systemGreenColor colorWithAlphaComponent:0.35]);
    }
}

- (void)startAutoRefreshTimer {
    [self stopAutoRefreshTimer];
    if (self.autoRefreshPausedByUser || self.autoRefreshInterval <= 0.1) return;
    __weak typeof(self) weakSelf = self;
    self.autoRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:self.autoRefreshInterval repeats:YES block:^(NSTimer *timer) {
        PlaybackInfoViewController *owner = weakSelf;
        if (!owner) { [timer invalidate]; return; }
        [owner refreshSnapshot];
    }];
}

- (void)stopAutoRefreshTimer {
    [self.autoRefreshTimer invalidate];
    self.autoRefreshTimer = nil;
}

- (void)refreshSnapshot {
    if (self.summaryProvider) {
        NSDictionary *summary = nil;
        @try { summary = self.summaryProvider(); } @catch (NSException *e) { summary = nil; }
        [self applySummaryData:summary];
    } else {
        [self applySummaryData:nil];
    }

    NSArray<NSDictionary *> *sections = @[];
    if (self.sectionsProvider) {
        @try { sections = self.sectionsProvider() ?: @[]; } @catch (NSException *e) { sections = @[]; }
    }
    if ([sections isKindOfClass:NSArray.class] && sections.count) {
        self.snapshotSections = sections;
        self.snapshotRows = [self allFlattenedRows];
    } else {
        self.snapshotSections = @[];
        NSArray *rows = @[];
        if (self.rowsProvider) {
            @try { rows = self.rowsProvider() ?: @[]; } @catch (NSException *e) { rows = @[]; }
        }
        self.snapshotRows = [rows isKindOfClass:NSArray.class] ? rows : @[];
    }

    BOOL hasData = self.snapshotSections.count > 0 || self.snapshotRows.count > 0;
    self.emptyLabel.hidden = hasData;
    [self.refreshControl endRefreshing];
    if (self.isViewLoaded) {
        CGPoint offset = self.tableView.contentOffset;
        [UIView performWithoutAnimation:^{
            [self.tableView reloadData];
        }];
        if (self.tableView.contentSize.height > self.tableView.bounds.size.height && offset.y > 0) {
            CGFloat maxOffset = MAX(0, self.tableView.contentSize.height - self.tableView.bounds.size.height);
            self.tableView.contentOffset = CGPointMake(offset.x, MIN(offset.y, maxOffset));
        }
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if (self.snapshotSections.count) return (NSInteger)self.snapshotSections.count;
    return self.snapshotRows.count ? 1 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.snapshotSections.count) {
        if (section < 0 || section >= (NSInteger)self.snapshotSections.count) return 0;
        NSArray *rows = self.snapshotSections[(NSUInteger)section][@"rows"];
        return [rows isKindOfClass:NSArray.class] ? (NSInteger)rows.count : 0;
    }
    return (NSInteger)self.snapshotRows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (self.snapshotSections.count) {
        if (section < 0 || section >= (NSInteger)self.snapshotSections.count) return nil;
        return [self.snapshotSections[(NSUInteger)section][@"title"] description];
    }
    return self.snapshotRows.count ? @"实时播放链路指标 · 点按任意行可复制" : nil;
}

- (NSDictionary *)rowDictionaryAtIndexPath:(NSIndexPath *)ip {
    if (self.snapshotSections.count) {
        if (ip.section < 0 || ip.section >= (NSInteger)self.snapshotSections.count) return @{};
        NSArray *rows = self.snapshotSections[(NSUInteger)ip.section][@"rows"];
        if (![rows isKindOfClass:NSArray.class] || ip.row < 0 || ip.row >= (NSInteger)rows.count) return @{};
        return [rows[(NSUInteger)ip.row] isKindOfClass:NSDictionary.class] ? rows[(NSUInteger)ip.row] : @{};
    }
    if (ip.row < 0 || ip.row >= (NSInteger)self.snapshotRows.count) return @{};
    return [self.snapshotRows[(NSUInteger)ip.row] isKindOfClass:NSDictionary.class] ? self.snapshotRows[(NSUInteger)ip.row] : @{};
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    (void)tableView; (void)section;
    HostStyleSectionHeaderView(view);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *row = [self rowDictionaryAtIndexPath:ip];
    NSString *titleText = [(row[@"title"] ?: @"") description];
    NSString *valueText = [(row[@"value"] ?: @"") description];
    BOOL useSubtitle = valueText.length > 26 || [titleText containsString:@"地址"] || [titleText containsString:@"阶段"] || [titleText containsString:@"错误"] || [titleText containsString:@"参数"];
    NSString *reuse = useSubtitle ? @"playback.info.subtitle" : @"playback.info.row";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:useSubtitle ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1 reuseIdentifier:reuse];
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 13;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.clipsToBounds = YES;
    c.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(c, HostBorder());
    c.textLabel.text = titleText;
    c.detailTextLabel.text = valueText;
    NSString *symbol = ([titleText containsString:@"带宽"] || [titleText containsString:@"速率"] || [titleText containsString:@"码率"]) ? @"speedometer" :
        (([titleText containsString:@"分辨率"] || [titleText containsString:@"画面"] || [titleText containsString:@"帧率"]) ? @"rectangle.expand.vertical" :
        (([titleText containsString:@"节点"] || [titleText containsString:@"线路"] || [titleText containsString:@"地址"] || [titleText containsString:@"备用"]) ? @"network" :
        ([titleText containsString:@"频道名称"] ? @"tv.fill" :
        (([titleText containsString:@"频道 ID"] || [titleText containsString:@"标识"]) ? @"number.square" :
        (([titleText containsString:@"引擎"] || [titleText containsString:@"解码"] || [titleText containsString:@"编码"]) ? @"cpu" :
        (([titleText containsString:@"首帧"] || [titleText containsString:@"耗时"] || [titleText containsString:@"缓冲"] || [titleText containsString:@"丢帧"] || [titleText containsString:@"卡顿"]) ? @"bolt.fill" :
        ([titleText containsString:@"版本"] ? @"app.badge.checkmark" : @"waveform.path.ecg")))))));
    c.imageView.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    BOOL isAlertValue = ([valueText containsString:@"失败"] || [valueText containsString:@"错误"] || [valueText containsString:@"异常"] || [valueText containsString:@"超时"]);
    c.imageView.tintColor = HostAccent();
    if (isAlertValue) c.imageView.tintColor = UIColor.systemOrangeColor;
    else if ([titleText containsString:@"码率"] || [titleText containsString:@"速率"] || [titleText containsString:@"带宽"]) c.imageView.tintColor = UIColor.systemGreenColor;
    c.textLabel.textColor = HostText();
    c.detailTextLabel.textColor = HostSecondaryText();
    if (isAlertValue) c.detailTextLabel.textColor = UIColor.systemOrangeColor;
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    c.textLabel.adjustsFontForContentSizeCategory = YES;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]];
    c.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    c.accessibilityHint = @"点按复制此项指标";
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *row = [self rowDictionaryAtIndexPath:ip];
    if (!row.count) return;
    NSString *line = [NSString stringWithFormat:@"%@：%@", [(row[@"title"] ?: @"") description], [(row[@"value"] ?: @"") description]];
    UIPasteboard.generalPasteboard.string = line;
    [self showTransientPrompt:@"指标已复制"];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"指标已复制");
}

- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell || UIAccessibilityIsReduceMotionEnabled()) return;
    [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        cell.transform = CGAffineTransformMakeScale(0.985, 0.985);
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        cell.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    (void)tableView; (void)point;
    NSDictionary *row = [self rowDictionaryAtIndexPath:ip];
    NSString *title = [(row[@"title"] ?: @"") description];
    NSString *value = [(row[@"value"] ?: @"") description];
    if (!title.length && !value.length) return nil;
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ip previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *copyVal = [UIAction actionWithTitle:@"复制指标数值" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a) {
            UIPasteboard.generalPasteboard.string = value.length ? value : title;
            [weakSelf showTransientPrompt:@"指标已复制"];
        }];
        UIAction *copyPair = [UIAction actionWithTitle:@"复制完整键值" image:[UIImage systemImageNamed:@"list.clipboard"] identifier:nil handler:^(__unused UIAction *a) {
            UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"%@：%@", title, value];
            [weakSelf showTransientPrompt:@"指标已复制"];
        }];
        UIAction *copyAll = [UIAction actionWithTitle:@"复制全部播放诊断信息" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(__unused UIAction *a) {
            [weakSelf copyAllDiagnostics];
        }];
        return [UIMenu menuWithTitle:title children:@[copyVal, copyPair, copyAll]];
    }];
}
@end
