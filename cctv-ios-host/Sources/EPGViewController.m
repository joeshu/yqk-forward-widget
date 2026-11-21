#import "HostSyncRequest.h"
#import "EPGViewController.h"
#import <UserNotifications/UserNotifications.h>
#import "HostTheme.h"
#import "ProfileStore.h"
#import "XMLTVStore.h"

@interface EPGViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSString *channelID;
@property(nonatomic,strong) NSDictionary *channel;
@property(nonatomic,copy) NSString *xmlSource;
@property(nonatomic,assign) NSUInteger requestGeneration;
@property(nonatomic,copy) NSString *sourceName;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSArray<NSDictionary *> *allRows;
@property (nonatomic, strong) UISegmentedControl *dates;
@property (nonatomic, strong) NSArray<NSString *> *dateKeys;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property(nonatomic,assign) BOOL pageVisible;
@property(nonatomic,assign) BOOL needsRefreshOnAppear;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *reminders;
@property(nonatomic,copy) NSString *searchQuery;
@property(nonatomic,strong) UISearchController *programSearch;
@property(nonatomic,strong) UIButton *dateMenuButton;
@property(nonatomic,strong) UIBarButtonItem *jumpToLiveItem;
@property(nonatomic,strong) UIBarButtonItem *filterMenuItem;
@property(nonatomic,assign) NSInteger programFilterMode;
@property(nonatomic,strong) UIView *hintCard;
@property(nonatomic,strong) UIStackView *inlineActionStack;
@property(nonatomic,strong) UIButton *inlineLiveButton;
@property(nonatomic,strong) UIButton *inlineSevenDayButton;
@property(nonatomic,strong) UIButton *inlineReturnLiveButton;
@property(nonatomic,strong) UIButton *inlineFilterButton;
@property(nonatomic,strong) NSMutableSet<NSString *> *loadedOfficialDates;
- (UIButton *)makeInlineChipButtonWithTitle:(NSString *)title symbol:(NSString *)symbol accent:(BOOL)accent identifier:(NSString *)identifier action:(SEL)action;
- (void)handleInlineReturnToLive;
- (void)refreshInlineActionBar;
- (void)fetchOfficialSevenDayLookback;
- (void)rebuildDates;
- (void)updateEmptyState;
- (void)fetchOfficial;
- (NSArray<NSDictionary *> *)normalize:(NSArray *)rows;
- (void)clearChannelReminders;
- (void)fetch;
- (void)filterDate;
-  (NSString *)effectiveChannelIdentifier;
-  (UIMenu *)buildProgramFilterMenu;
-  (void)pruneExpiredReminders;
-  (void)scheduleRefreshTimer;
-  (void)cancelPageRequest;
-  (void)saveReminders;
-  (BOOL)isProgramReminded:(NSDictionary *)program;
-  (void)scrollToCurrentProgramAnimated:(BOOL)animated;
-  (void)updateDateMenuButton;
@end

@implementation EPGViewController

- (instancetype)initWithChannel:(NSDictionary *)channel officialID:(NSString *)officialID {
    if(self=[self initWithChannelID:officialID name:channel[@"name"]?:@"节目单"]){self.channel=channel;self.xmlSource=[ProfileStore epgSourceForChannel:channel];}return self;
}
- (instancetype)initWithChannelID:(NSString *)channelID name:(NSString *)name {
    if (self = [super init]) {
        _channelID = [channelID copy];
        _channelName = [name copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = self.channelName.length ? self.channelName : [self effectiveChannelIdentifier];
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.jumpToLiveItem=[[UIBarButtonItem alloc] initWithTitle:@"正在播" style:UIBarButtonItemStylePlain target:self action:@selector(scrollToLiveProgram)];
    self.filterMenuItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] menu:[self buildProgramFilterMenu]];
    self.filterMenuItem.accessibilityIdentifier=@"epg.filter.menu";
    self.filterMenuItem.accessibilityLabel=@"筛选节目单与预约管理";
    self.navigationItem.rightBarButtonItems=@[self.jumpToLiveItem, self.filterMenuItem, [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showSourceInfo)]];

    self.loadedOfficialDates = [NSMutableSet set];
    self.hintCard = [[UIView alloc] initWithFrame:CGRectMake(16, 12, self.view.bounds.size.width - 32, 28)];
    HostStyleGlassCard(self.hintCard, 12);
    [self.view addSubview:self.hintCard];
    self.hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, self.view.bounds.size.width - 32, 20)];
    self.hint.textColor = HostSecondaryText();
    self.hint.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12]];
    self.hint.adjustsFontForContentSizeCategory = YES;
    self.hint.numberOfLines = 2;
    self.hint.text = @"正在获取节目单…";
    [self.view addSubview:self.hint];

    self.inlineActionStack = [UIStackView new];
    self.inlineActionStack.axis = UILayoutConstraintAxisHorizontal;
    self.inlineActionStack.alignment = UIStackViewAlignmentCenter;
    self.inlineActionStack.distribution = UIStackViewDistributionFillProportionally;
    self.inlineActionStack.spacing = 6;
    self.inlineActionStack.accessibilityIdentifier = @"epg.inline.toolbar";
    self.inlineLiveButton = [self makeInlineChipButtonWithTitle:@"正在播" symbol:@"dot.radiowaves.left.and.right" accent:NO identifier:@"epg.inline.live" action:@selector(scrollToLiveProgram)];
    self.inlineSevenDayButton = [self makeInlineChipButtonWithTitle:@"7天回看" symbol:@"calendar.badge.clock" accent:NO identifier:@"epg.inline.7days" action:@selector(fetchOfficialSevenDayLookback)];
    self.inlineReturnLiveButton = [self makeInlineChipButtonWithTitle:@"返回直播" symbol:@"arrow.uturn.left.circle.fill" accent:YES identifier:@"epg.inline.return-live" action:@selector(handleInlineReturnToLive)];
    self.inlineFilterButton = [self makeInlineChipButtonWithTitle:@"筛选" symbol:@"line.3.horizontal.decrease.circle" accent:NO identifier:@"epg.inline.filter" action:NULL];
    self.inlineFilterButton.showsMenuAsPrimaryAction = YES;
    self.inlineFilterButton.menu = [self buildProgramFilterMenu];
    for (UIButton *b in @[self.inlineLiveButton, self.inlineSevenDayButton, self.inlineReturnLiveButton, self.inlineFilterButton]) {
        [self.inlineActionStack addArrangedSubview:b];
    }
    [self.view addSubview:self.inlineActionStack];
    [self refreshInlineActionBar];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.accessibilityLabel = @"正在加载节目单";
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2, 120);
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = @"暂无节目单\n下拉可重新加载";
    self.emptyLabel.textColor = HostSecondaryText();
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.emptyLabel.adjustsFontForContentSizeCategory = YES;
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 40, self.view.bounds.size.width, self.view.bounds.size.height - 40)
                                              style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 68;
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(fetch) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = refresh;
    self.table.backgroundView = self.emptyLabel;
    HostInstallGlassBackdrop(self.table);
    [self.view addSubview:self.table];

    self.dates=[[UISegmentedControl alloc] initWithItems:@[]];self.dates.selectedSegmentTintColor=HostAccentFill();self.dates.apportionsSegmentWidthsByContent=YES;self.dates.accessibilityLabel=@"选择节目单日期";[self.dates setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12]]} forState:UIControlStateNormal];[self.dates setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]]} forState:UIControlStateSelected];[self.dates addTarget:self action:@selector(filterDate) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.dates];
    self.reminders=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.epgReminders.v1"] mutableCopy]?:[NSMutableDictionary dictionary];
    [self pruneExpiredReminders];
    self.dateMenuButton=[UIButton buttonWithType:UIButtonTypeSystem];self.dateMenuButton.hidden=YES;self.dateMenuButton.accessibilityLabel=@"选择节目单日期";HostStylePillButton(self.dateMenuButton,NO);HostInstallPressFeedback(self.dateMenuButton);self.dateMenuButton.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15]];self.dateMenuButton.titleLabel.adjustsFontForContentSizeCategory=YES;self.dateMenuButton.showsMenuAsPrimaryAction=YES;[self.view addSubview:self.dateMenuButton];
    self.programSearch=[[UISearchController alloc] initWithSearchResultsController:nil];self.programSearch.searchResultsUpdater=self;self.programSearch.obscuresBackgroundDuringPresentation=NO;self.programSearch.searchBar.placeholder=@"搜索本页节目";self.navigationItem.searchController=self.programSearch;self.definesPresentationContext=YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self fetch];

}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.hint.textColor = HostSecondaryText();
    if (self.hintCard) HostStyleGlassCard(self.hintCard, 10);
    self.emptyLabel.textColor = HostSecondaryText();
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
    self.dates.selectedSegmentTintColor = HostAccentFill();
    [self.dates setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12]]} forState:UIControlStateNormal];
    [self.dates setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]]} forState:UIControlStateSelected];
    HostStylePillButton(self.dateMenuButton, NO);
    self.dateMenuButton.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15]];
    self.dateMenuButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    for (UIButton *b in @[self.inlineLiveButton ?: [UIButton new], self.inlineSevenDayButton ?: [UIButton new], self.inlineFilterButton ?: [UIButton new]]) {
        b.backgroundColor = HostRaisedSurface();
        b.tintColor = HostText();
        HostSetLayerBorderColor(b, HostBorder());
    }
    if (self.inlineReturnLiveButton) {
        self.inlineReturnLiveButton.backgroundColor = HostSelectedSurface();
        self.inlineReturnLiveButton.tintColor = HostAccent();
        HostSetLayerBorderColor(self.inlineReturnLiveButton, [HostAccent() colorWithAlphaComponent:0.40]);
    }
    [self.table reloadData];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self reloadThemeAppearance];
    }
}

- (UIButton *)makeInlineChipButtonWithTitle:(NSString *)title symbol:(NSString *)symbol accent:(BOOL)accent identifier:(NSString *)identifier action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:[NSString stringWithFormat:@" %@", title] forState:UIControlStateNormal];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    [btn setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    btn.titleLabel.font = HostMonospacedDigitFont(11.5, UIFontWeightSemibold, UIFontTextStyleCaption1);
    btn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    btn.contentEdgeInsets = UIEdgeInsetsMake(4, 9, 4, 9);
    btn.backgroundColor = accent ? HostSelectedSurface() : HostRaisedSurface();
    btn.tintColor = accent ? HostAccent() : HostText();
    btn.layer.cornerRadius = 9.5;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(btn, accent ? [HostAccent() colorWithAlphaComponent:0.40] : HostBorder());
    btn.accessibilityIdentifier = identifier;
    HostInstallPressFeedback(btn);
    if (action) [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)handleInlineReturnToLive {
    if (self.onReturnToLive) self.onReturnToLive();
}

- (void)refreshInlineActionBar {
    if (!self.inlineActionStack) return;
    self.inlineSevenDayButton.hidden = (self.xmlSource.length > 0 || !self.channelID.length);
    self.inlineReturnLiveButton.hidden = (self.onReturnToLive == nil);
    self.inlineFilterButton.menu = [self buildProgramFilterMenu];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];self.pageVisible=YES;
    if(self.needsRefreshOnAppear){self.needsRefreshOnAppear=NO;[self fetch];}
    [self scheduleRefreshTimer];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];self.pageVisible=NO;self.needsRefreshOnAppear=YES;
    [self cancelPageRequest];[self.refreshTimer invalidate];self.refreshTimer=nil;
}
- (void)scheduleRefreshTimer {
    [self.refreshTimer invalidate];self.refreshTimer=nil;
    if(!self.pageVisible||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    __weak typeof(self) w=self;self.refreshTimer=[NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t){EPGViewController *owner=w;if(!owner){[t invalidate];return;}[owner fetch];}];
}
- (void)cancelPageRequest {
    self.requestGeneration++;[self.task cancel];self.task=nil;
    [self.spinner stopAnimating];[self.table.refreshControl endRefreshing];
}
- (void)applicationDidEnterBackground {
    self.needsRefreshOnAppear=YES;[self.refreshTimer invalidate];self.refreshTimer=nil;[self cancelPageRequest];
}
- (void)applicationWillEnterForeground {
    if(!self.pageVisible)return;
    self.needsRefreshOnAppear=NO;[self fetch];[self scheduleRefreshTimer];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.refreshTimer invalidate];
    [self.task cancel];
}

- (void)fetch {
    if(self.xmlSource.length){NSUInteger request=++self.requestGeneration;BOOL force=self.table.refreshControl.refreshing;__weak typeof(self) w=self;
        [[XMLTVStore shared] loadSource:self.xmlSource channel:[ProfileStore epgIDForChannel:self.channel] force:force completion:^(NSArray *rows,NSError *error){if(!w||request!=w.requestGeneration)return;[w.spinner stopAnimating];[w.table.refreshControl endRefreshing];
            if(rows.count){w.allRows=rows;w.sourceName=w.xmlSource;[w rebuildDates];w.hint.text=error?@"使用上次缓存，刷新暂不可用":[NSString stringWithFormat:@"XMLTV · %lu 个节目",(unsigned long)rows.count];}
            else if(error.code==NSURLErrorCancelled){w.hint.text=@"正在优先加载视频，稍后下拉刷新节目单";[w updateEmptyState];}
            else if(w.channelID.length){[w fetchOfficial];}
            else {w.hint.text=w.allRows.count?@"刷新失败，显示上次节目单":(error.localizedDescription?:@"暂无匹配节目；请在频道菜单中设置 EPG ID");[w updateEmptyState];}
        }];return;}
    [self fetchOfficial];
}
- (void)fetchOfficial {
    if(!self.channelID.length){self.hint.text=@"暂无匹配的官方节目单";[self.spinner stopAnimating];[self.table.refreshControl endRefreshing];[self updateEmptyState];return;}
    NSString *encoded = [self.channelID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox", encoded];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __weak typeof(self) weakSelf = self;NSUInteger generation=++self.requestGeneration;
    [self.task cancel];
    self.task = HostBoundedDataTask(req, 2*1024*1024, ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray *rows = nil;
        // 官方 EPG 响应无大小限制：超过 4 MiB 按失败处理，避免后台线程解析超大 JSON。
        if (data.length&&data.length<=4*1024*1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([json isKindOfClass:NSDictionary.class]) {
                NSDictionary *dict = json;
                NSArray *epg = dict[@"EPG"] ?: dict[@"data"];
                if ([epg isKindOfClass:NSArray.class]) rows = [weakSelf normalize:epg];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if(!weakSelf||generation!=weakSelf.requestGeneration)return;weakSelf.sourceName=@"央视官方 EPG";
            [weakSelf.spinner stopAnimating];
            [weakSelf.table.refreshControl endRefreshing];
            if (rows.count) {
                weakSelf.allRows = rows;
                [weakSelf rebuildDates];
                weakSelf.hint.text = [NSString stringWithFormat:@"%lu 个节目 · 每分钟自动刷新",
                                      (unsigned long)rows.count];
            } else if (weakSelf.allRows.count) {
                // 刷新失败时保留上次节目单：提示必须说清是旧数据，
                // 不能一边展示旧节目一边写“暂无有效节目单”。
                weakSelf.hint.text = @"刷新失败，显示上次节目单";
            } else {
                weakSelf.hint.text = err ? [NSString stringWithFormat:@"获取失败：%@", err.localizedDescription]
                                         : @"官方暂无有效节目单";
            }
            [weakSelf updateEmptyState];
        });
    });
    [self.task resume];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGFloat top=self.view.safeAreaInsets.top;CGFloat bottom=self.view.safeAreaInsets.bottom;CGFloat width=self.view.bounds.size.width;
    CGFloat hintHeight=ceil(self.hint.font.lineHeight*2);
    self.dates.frame=CGRectMake(16,top+8,width-32,44);self.dateMenuButton.frame=self.dates.frame;
    self.inlineActionStack.frame=CGRectMake(16,top+58,MAX(0,width-32),30);
    CGFloat hintTop=top+94;
    self.hintCard.frame=CGRectMake(16,hintTop,MAX(0,width-32),hintHeight+6);
    self.hint.frame=CGRectMake(26,hintTop+3,MAX(0,width-52),hintHeight);
    CGFloat tableTop=hintTop+hintHeight+10;
    self.table.frame=CGRectMake(0,tableTop,width,MAX(0,self.view.bounds.size.height-tableTop-8-bottom));
    self.spinner.center=CGPointMake(width/2,tableTop+64);
}
- (void)updateEmptyState {
    self.emptyLabel.hidden = self.rows.count > 0 || self.spinner.isAnimating;
}
- (NSDateFormatter *)dayFormatter {static NSDateFormatter *f=nil;static dispatch_once_t onceToken;dispatch_once(&onceToken,^{f=[NSDateFormatter new];f.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Shanghai"];f.dateFormat=@"yyyy-MM-dd";});return f;}
- (NSString *)dayKeyForTimestamp:(NSTimeInterval)ts {
    NSDateFormatter *f=[self dayFormatter];
    @synchronized(f){return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]]?:@"";}
}
- (NSString *)effectiveChannelIdentifier {
    if(self.channelID.length)return self.channelID;
    NSString *cid=[self.channel[@"id"] isKindOfClass:NSString.class]?self.channel[@"id"]:@"";
    if(cid.length)return cid;
    NSString *epgID=[ProfileStore epgIDForChannel:self.channel];
    if(epgID.length)return epgID;
    return self.channelName.length?self.channelName:@"channel";
}
- (void)rebuildDates {
    NSString *previous=(self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count)?self.dateKeys[self.dates.selectedSegmentIndex]:nil;NSMutableOrderedSet *days=[NSMutableOrderedSet orderedSet];for(NSDictionary *row in self.allRows)[days addObject:[self dayKeyForTimestamp:[row[@"start"] doubleValue]]];self.dateKeys=days.array;
    [self.dates removeAllSegments];NSString *today=[self dayKeyForTimestamp:NSDate.date.timeIntervalSince1970];NSInteger selected=NSNotFound;for(NSUInteger i=0;i<self.dateKeys.count;i++){NSString *key=self.dateKeys[i];NSString *title=[key isEqualToString:today]?@"今天":[key substringFromIndex:5];[self.dates insertSegmentWithTitle:title atIndex:i animated:NO];if(previous.length&&[key isEqualToString:previous])selected=i;}
    if(selected==NSNotFound)for(NSUInteger i=0;i<self.dateKeys.count;i++)if([self.dateKeys[i] isEqualToString:today]){selected=i;break;}
    self.dates.selectedSegmentIndex=self.dateKeys.count?(selected==NSNotFound?(NSInteger)self.dateKeys.count-1:selected):UISegmentedControlNoSegment;[self updateDateMenuButton];[self filterDate];
}
- (void)updateDateMenuButton {
    // 日期超过 5 天时分段控件会被挤扁：隐藏它，改用下拉菜单选日期。
    BOOL overflow=self.dateKeys.count>5;
    self.dates.hidden=overflow;self.dateMenuButton.hidden=!overflow;
    if(!overflow)return;
    NSString *today=[self dayKeyForTimestamp:NSDate.date.timeIntervalSince1970];
    NSString *selected=(self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count)?self.dateKeys[self.dates.selectedSegmentIndex]:nil;
    [self.dateMenuButton setTitle:selected?([selected isEqualToString:today]?@"今天":selected):@"选择日期" forState:UIControlStateNormal];
    NSMutableArray<UIAction *> *actions=[NSMutableArray array];
    for(NSUInteger i=0;i<self.dateKeys.count;i++){NSString *key=self.dateKeys[i];NSString *title=[key isEqualToString:today]?@"今天":key;__weak typeof(self) w=self;UIAction *dayAct=[UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"calendar"] identifier:nil handler:^(__unused UIAction *a){w.dates.selectedSegmentIndex=(NSInteger)i;[w updateDateMenuButton];[w filterDate];}];dayAct.state=(selected&&[key isEqualToString:selected])?UIMenuElementStateOn:UIMenuElementStateOff;[actions addObject:dayAct];}
    self.dateMenuButton.menu=[UIMenu menuWithTitle:@"选择日期" children:actions];
}
- (UIMenu *)buildProgramFilterMenu {
    __weak typeof(self) weakSelf=self;
    UIAction *all=[UIAction actionWithTitle:@"全部节目" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil handler:^(__unused UIAction *a){weakSelf.programFilterMode=0;weakSelf.filterMenuItem.menu=[weakSelf buildProgramFilterMenu];[weakSelf refreshInlineActionBar];[weakSelf filterDate];}];
    all.state=(self.programFilterMode==0)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *replayOnly=[UIAction actionWithTitle:@"仅看已播 / 可回看" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(__unused UIAction *a){weakSelf.programFilterMode=1;weakSelf.filterMenuItem.menu=[weakSelf buildProgramFilterMenu];[weakSelf refreshInlineActionBar];[weakSelf filterDate];}];
    replayOnly.state=(self.programFilterMode==1)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *remindedOnly=[UIAction actionWithTitle:@"仅看已预约提醒" image:[UIImage systemImageNamed:@"bell.badge"] identifier:nil handler:^(__unused UIAction *a){weakSelf.programFilterMode=2;weakSelf.filterMenuItem.menu=[weakSelf buildProgramFilterMenu];[weakSelf refreshInlineActionBar];[weakSelf filterDate];}];
    remindedOnly.state=(self.programFilterMode==2)?UIMenuElementStateOn:UIMenuElementStateOff;
    UIMenu *filterGroup=[UIMenu menuWithTitle:@"节目筛选" image:nil identifier:@"epg.menu.filter" options:UIMenuOptionsDisplayInline children:@[all,replayOnly,remindedOnly]];
    NSMutableArray<UIMenuElement *> *actionItems=[NSMutableArray array];
    if(!self.xmlSource.length && self.channelID.length){
        UIAction *load7Days=[UIAction actionWithTitle:@"加载近 7 天回看节目单" image:[UIImage systemImageNamed:@"calendar.badge.clock"] identifier:@"epg.load.7days" handler:^(__unused UIAction *a){[weakSelf fetchOfficialSevenDayLookback];}];
        [actionItems addObject:load7Days];
    }
    if(self.onReturnToLive){
        UIAction *backLive=[UIAction actionWithTitle:@"返回实时直播" image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"] identifier:@"epg.return.live" handler:^(__unused UIAction *a){if(weakSelf.onReturnToLive)weakSelf.onReturnToLive();}];
        [actionItems addObject:backLive];
    }
    UIAction *clearReminders=[UIAction actionWithTitle:@"清空本频道预约提醒" image:[UIImage systemImageNamed:@"bell.slash"] identifier:nil handler:^(__unused UIAction *a){[weakSelf clearChannelReminders];}];
    clearReminders.attributes=UIMenuElementAttributesDestructive;
    NSMutableArray<UIMenuElement *> *sections=[NSMutableArray arrayWithObject:filterGroup];
    if(actionItems.count)[sections addObject:[UIMenu menuWithTitle:@"回看与直播" image:nil identifier:@"epg.menu.actions" options:UIMenuOptionsDisplayInline children:actionItems]];
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"epg.menu.danger" options:UIMenuOptionsDisplayInline children:@[clearReminders]]];
    return [UIMenu menuWithTitle:@"" children:sections];
}

- (void)fetchOfficialSevenDayLookback {
    if (!self.channelID.length) return;
    NSString *encoded = [self.channelID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
    if (!encoded.length) return;
    self.hint.text = @"正在同步近 7 天央视官方回看节目单…";
    [self.spinner startAnimating];
    NSDateFormatter *compactFmt = [NSDateFormatter new];
    compactFmt.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"];
    compactFmt.dateFormat = @"yyyyMMdd";
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSMutableArray<NSString *> *dayStrings = [NSMutableArray arrayWithCapacity:7];
    for (NSInteger offset = -6; offset <= 0; offset++) {
        NSString *d = [compactFmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:now + offset * 86400.0]];
        if (d.length) [dayStrings addObject:d];
    }
    NSUInteger generation = ++self.requestGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSDictionary *> *collected = [NSMutableArray array];
    for (NSString *dayStr in dayStrings) {
        dispatch_group_enter(group);
        NSString *u = [NSString stringWithFormat:@"https://api.cntv.cn/epg/epginfo3?serviceId=cbox&c=%@&d=%@", encoded, dayStr];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            EPGViewController *owner = weakSelf;
            if (!owner || generation != owner.requestGeneration) {
                dispatch_group_leave(group);
                return;
            }
            if (!err && data.length > 0 && data.length <= 4 * 1024 * 1024) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if ([json isKindOfClass:NSDictionary.class]) {
                    NSString *cid = owner.channelID ?: @"";
                    NSDictionary *channelNode = (cid.length && [json[cid] isKindOfClass:NSDictionary.class]) ? json[cid] : json;
                    NSArray *programList = [channelNode[@"program"] isKindOfClass:NSArray.class] ? channelNode[@"program"] : (channelNode[@"EPG"] ?: channelNode[@"data"]);
                    if ([programList isKindOfClass:NSArray.class]) {
                        NSArray *norm = [owner normalize:programList];
                        if (norm.count) { @synchronized(collected) { [collected addObjectsFromArray:norm]; } }
                    }
                }
            }
            dispatch_group_leave(group);
        }] resume];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        EPGViewController *owner = weakSelf;
        if (!owner || generation != owner.requestGeneration) return;
        [owner.spinner stopAnimating];
        if (collected.count) {
            NSMutableDictionary<NSNumber *, NSDictionary *> *dedup = [NSMutableDictionary dictionary];
            for (NSDictionary *r in owner.allRows ?: @[]) dedup[r[@"start"] ?: @0] = r;
            for (NSDictionary *r in collected) dedup[r[@"start"] ?: @0] = r;
            NSArray *merged = [dedup.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [a[@"start"] compare:b[@"start"]];
            }];
            owner.allRows = merged;
            [owner rebuildDates];
            owner.hint.text = [NSString stringWithFormat:@"已加载 %lu 天共 %lu 个节目 · 点选任意已播节目即可回看", (unsigned long)owner.dateKeys.count, (unsigned long)merged.count];
        } else {
            owner.hint.text = @"近 7 天扩展节目单暂不可用，已保留当前节目单";
        }
        [owner updateEmptyState];
    });
}

- (void)clearChannelReminders {
    NSString *prefix=[NSString stringWithFormat:@"%@|",[self effectiveChannelIdentifier]];
    NSMutableArray<NSString *> *toRemove=[NSMutableArray array];
    for(NSString *key in self.reminders.allKeys)if([key hasPrefix:prefix])[toRemove addObject:key];
    if(!toRemove.count){self.hint.text=@"当前频道没有已预约的节目提醒";return;}
    [self.reminders removeObjectsForKeys:toRemove];[self saveReminders];
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:toRemove];
    self.hint.text=[NSString stringWithFormat:@"已清空本频道 %lu 条预约提醒",(unsigned long)toRemove.count];
    [self filterDate];
}

- (void)filterDate {
    NSInteger idx=self.dates.selectedSegmentIndex;if(idx<0||idx>=self.dateKeys.count){[self updateEmptyState];return;}NSString *key=self.dateKeys[idx];self.rows=[self.allRows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [[self dayKeyForTimestamp:[row[@"start"] doubleValue]] isEqualToString:key];}]];
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(self.programFilterMode==1)self.rows=[self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [row[@"start"] doubleValue]<=now;}]];
    else if(self.programFilterMode==2)self.rows=[self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [self isProgramReminded:row];}]];
    if(self.searchQuery.length){NSString *q=self.searchQuery.lowercaseString;self.rows=[self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return [[(row[@"title"]?:@"") description].lowercaseString containsString:q];}]];}
    [self.table reloadData];if(!self.searchQuery.length&&self.programFilterMode==0)[self scrollToCurrentProgramAnimated:NO];
    [self updateEmptyState];
}
- (void)scrollToCurrentProgramAnimated:(BOOL)animated {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;for(NSUInteger i=0;i<self.rows.count;i++){NSDictionary *row=self.rows[i];if(now>=[row[@"start"] doubleValue]&&now<[row[@"end"] doubleValue]){[self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0] atScrollPosition:UITableViewScrollPositionMiddle animated:animated];break;}}
}
- (void)scrollToLiveProgram {[self scrollToCurrentProgramAnimated:YES];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {self.searchQuery=searchController.searchBar.text;[self filterDate];}
- (NSString *)reminderKeyForProgram:(NSDictionary *)program {
    // 提醒以“频道 | 开播时间戳”为键，同一节目只会有一条提醒。
    return [NSString stringWithFormat:@"%@|%lld",[self effectiveChannelIdentifier],(long long)[program[@"start"] doubleValue]];
}
- (BOOL)isProgramReminded:(NSDictionary *)program {return self.reminders[[self reminderKeyForProgram:program]]!=nil;}
- (void)pruneExpiredReminders {
    NSTimeInterval cutoff=NSDate.date.timeIntervalSince1970-86400;
    NSMutableArray<NSString *> *expired=[NSMutableArray array];
    for(NSString *key in self.reminders.allKeys){NSDictionary *entry=self.reminders[key];NSTimeInterval start=[entry isKindOfClass:NSDictionary.class]?[entry[@"start"] doubleValue]:0;if(start<=cutoff)[expired addObject:key];}
    if(expired.count){[self.reminders removeObjectsForKeys:expired];[self saveReminders];}
}
- (void)saveReminders {[NSUserDefaults.standardUserDefaults setObject:self.reminders forKey:@"cctv.epgReminders.v1"];}
- (void)toggleReminderForProgram:(NSDictionary *)program {
    NSString *key=[self reminderKeyForProgram:program];NSString *title=[program[@"title"] isKindOfClass:NSString.class]?program[@"title"]:@"节目";
    if(self.reminders[key]){[self.reminders removeObjectForKey:key];[self saveReminders];[[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[key]];self.hint.text=[NSString stringWithFormat:@"已取消提醒：%@",title];[self.table reloadData];return;}
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSTimeInterval start=[program[@"start"] doubleValue];if(start<=now)return;
    __weak typeof(self) w=self;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:UNAuthorizationOptionAlert|UNAuthorizationOptionSound completionHandler:^(BOOL granted,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{EPGViewController *owner=w;if(!owner)return;
            if(!granted){owner.hint.text=@"通知未开启，请在设置中允许通知后重试";return;}
            NSTimeInterval fire=start-300>now?start-300:start;
            UNMutableNotificationContent *content=[UNMutableNotificationContent new];content.title=owner.channelName.length?owner.channelName:@"CCTV";content.body=[NSString stringWithFormat:@"即将播出：%@",title];content.sound=[UNNotificationSound defaultSound];
            UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:key content:content trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:MAX(1,fire-now) repeats:NO]];
            [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
            owner.reminders[key]=@{@"title":title,@"channelName":owner.channelName?:@"",@"start":@(start)};[owner saveReminders];
            owner.hint.text=[NSString stringWithFormat:@"已预约：%@，开播前 5 分钟提醒",title];[owner.table reloadData];
        });
    }];
}
- (NSString *)safeSourceDescription {
    NSString *raw=self.xmlSource?:@"";NSURLComponents *components=[NSURLComponents componentsWithString:raw];
    if(!components.host.length)return self.sourceName?:@"央视官方 EPG";
    BOOL hidden=components.user.length||components.password.length||components.query.length||components.path.length>1;
    components.user=nil;components.password=nil;components.fragment=nil;components.query=nil;components.path=@"";
    NSString *value=components.string?:@"XMLTV";return hidden?[value stringByAppendingString:@"（凭据已隐藏）"]:value;
}
- (void)showSourceInfo {
    NSDictionary *mappings=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{};
    NSString *manual=mappings[self.channel[@"id"]?:@""];
    NSString *tvgID=self.channel[@"epgID"]?:@"";NSString *tvgName=self.channel[@"tvgName"]?:@"";
    NSString *match=manual.length?@"手动 EPG 映射":(tvgID.length?@"M3U tvg-id":(tvgName.length?@"M3U tvg-name / 频道名称":@"频道 ID / 名称"));
    NSString *matchID=self.xmlSource.length?[ProfileStore epgIDForChannel:self.channel]:self.channelID;
    NSString *date=self.dates.selectedSegmentIndex>=0&&self.dates.selectedSegmentIndex<self.dateKeys.count?self.dateKeys[self.dates.selectedSegmentIndex]:@"未选择日期";
    NSString *status=self.allRows.count?[NSString stringWithFormat:@"已读取 %lu 个节目",(unsigned long)self.allRows.count]:(self.hint.text?:@"等待数据");
    NSString *message=[NSString stringWithFormat:@"频道：%@\nM3U tvg-id：%@\nM3U tvg-name：%@\n实际匹配 ID：%@\n匹配依据：%@\n数据来源：%@\n所选日期：%@\n数据状态：%@\n时区：北京时间\n\n节目仅展示数据源实际返回的内容。CCTV 原生频道可点按已播节目请求回看，范围与版权由频道服务确认。",self.channelName,self.channel[@"epgID"]?:@"—",self.channel[@"tvgName"]?:@"—",matchID?:@"—",match,[self safeSourceDescription],date,status];
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"EPG 频道信息" message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)normalize:(NSArray *)rows {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in rows) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        double start = [row[@"startTime"] doubleValue];
        double end = [row[@"endTime"] doubleValue];
        if (start > 1e11) start /= 1000.0;
        if (end > 1e11) end /= 1000.0;
        NSString *title = row[@"title"];
        if (![title isKindOfClass:NSString.class] || !title.length) continue;
        if (start <= 0 || end <= start) continue;
        [out addObject:@{@"start": @(start), @"end": @(end), @"title": title}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    return out;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"epg";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.backgroundColor = HostCard();
        cell.textLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:15.5 weight:UIFontWeightMedium]];
        cell.detailTextLabel.font = HostMonospacedDigitFont(12.0, UIFontWeightRegular, UIFontTextStyleCaption1);
        cell.textLabel.adjustsFontForContentSizeCategory=YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
        cell.textLabel.numberOfLines=0;
        cell.detailTextLabel.numberOfLines=0;
        cell.textLabel.textColor = HostText();
        cell.detailTextLabel.textColor = HostSecondaryText();
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSDictionary *row = self.rows[indexPath.row];
    double start = [row[@"start"] doubleValue];
    double end = [row[@"end"] doubleValue];
    double now = NSDate.date.timeIntervalSince1970;

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ fmt = [[NSDateFormatter alloc] init]; fmt.dateFormat = @"HH:mm"; fmt.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Shanghai"]; });
    NSString *range = nil;
    @synchronized(fmt) {
        range = [NSString stringWithFormat:@"%@ - %@",
                 [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:start]],
                 [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:end]]];
    }
    cell.textLabel.attributedText = nil;
    NSString *rawTitle = [row[@"title"] isKindOfClass:NSString.class] ? row[@"title"] : @"";
    cell.textLabel.text = rawTitle;
    cell.detailTextLabel.text = range;
    cell.detailTextLabel.textColor = HostSecondaryText();

    BOOL live = (now >= start && now < end);
    NSDictionary *liveCandidate = live ? @{@"start":@(start), @"end":@(MAX(start + 1, now)), @"title":row[@"title"] ?: @"", @"liveRestart":@YES} : row;
    BOOL replayable = self.onReplay && (end <= now || (live && (now - start >= 15))) && (!self.canReplay || self.canReplay(live ? liveCandidate : row));
    BOOL activeReplayRow = (self.activeReplayStart > 0 && fabs(start - self.activeReplayStart) < 2.0);
    cell.accessoryType=replayable?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;
    cell.selectionStyle=(replayable||start>now)?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
    cell.transform = CGAffineTransformIdentity;
    cell.backgroundColor = (live || activeReplayRow) ? HostSelectedSurface() : HostCard();
    cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous; cell.clipsToBounds=YES;
    cell.layer.borderWidth=(live || activeReplayRow)?1.15:0.6; HostSetLayerBorderColor(cell,live?HostAccent():HostBorder()); if(activeReplayRow)HostSetLayerBorderColor(cell,HostAccent());
    UIView *epgSpecular = [cell.contentView viewWithTag:9103];
    if (!epgSpecular) {
        epgSpecular = [[UIView alloc] initWithFrame:CGRectMake(12, 0, MAX(0, CGRectGetWidth(cell.contentView.bounds) - 24), 0.5)]; epgSpecular.tag = 9103; epgSpecular.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin; epgSpecular.userInteractionEnabled = NO;
        [cell.contentView addSubview:epgSpecular];
    }
    epgSpecular.frame = CGRectMake(12, 0, MAX(0, CGRectGetWidth(cell.contentView.bounds) - 24), 0.5);
    epgSpecular.backgroundColor = HostIsDarkThemeSelected() ? [UIColor colorWithWhite:1.0 alpha:(live || activeReplayRow) ? 0.16 : 0.06] : [(live || activeReplayRow) ? HostAccent() : HostBorder() colorWithAlphaComponent:(live || activeReplayRow) ? 0.28 : 0.65];
    UIView *epgAccentBar = [cell.contentView viewWithTag:9104];
    if (!epgAccentBar) {
        epgAccentBar = [[UIView alloc] initWithFrame:CGRectMake(4, floor((CGRectGetHeight(cell.contentView.bounds) - 24.0) * 0.5), 3.5, 24.0)]; epgAccentBar.tag = 9104; epgAccentBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin; epgAccentBar.layer.cornerRadius = 1.75; epgAccentBar.layer.cornerCurve = kCACornerCurveContinuous; epgAccentBar.userInteractionEnabled = NO;
        [cell.contentView addSubview:epgAccentBar];
    }
    epgAccentBar.frame = CGRectMake(4, floor((CGRectGetHeight(cell.contentView.bounds) - 24.0) * 0.5), 3.5, 24.0);
    BOOL isRemindedRow = [self isProgramReminded:row];
    epgAccentBar.backgroundColor = (live || activeReplayRow) ? HostAccent() : (isRemindedRow ? UIColor.systemOrangeColor : (replayable ? [HostAccent() colorWithAlphaComponent:0.38] : UIColor.clearColor));
    NSString *statusPillText = activeReplayRow ? @"  ↺ 回看中  " : (live ? @"  ● 直播中  " : (replayable ? @"  ↺ 回看  " : (isRemindedRow ? @"  ⏰ 已预约  " : @"")));
    if (statusPillText.length) {
        UILabel *pill = ([cell.accessoryView isKindOfClass:UILabel.class] && cell.accessoryView.tag == 9105) ? (UILabel *)cell.accessoryView : nil;
        if (!pill) {
            pill = [UILabel new];
            pill.tag = 9105;
            pill.font = HostMonospacedDigitFont(10.5, UIFontWeightSemibold, UIFontTextStyleCaption2);
            pill.textAlignment = NSTextAlignmentCenter;
            pill.layer.cornerRadius = 7; pill.layer.cornerCurve = kCACornerCurveContinuous;
            pill.layer.borderWidth = 0.55; pill.clipsToBounds = YES;
            pill.accessibilityIdentifier = @"epg.row.status.badge";
        }
        pill.text = statusPillText;
        if (live || activeReplayRow) {
            pill.textColor = HostAccent(); pill.backgroundColor = HostSelectedSurface(); HostSetLayerBorderColor(pill, [HostAccent() colorWithAlphaComponent:0.42]);
        } else if (isRemindedRow) {
            pill.textColor = UIColor.systemOrangeColor; pill.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.14]; HostSetLayerBorderColor(pill, [UIColor.systemOrangeColor colorWithAlphaComponent:0.35]);
        } else {
            pill.textColor = HostSecondaryText(); pill.backgroundColor = HostRaisedSurface(); HostSetLayerBorderColor(pill, HostBorder());
        }
        [pill sizeToFit];
        pill.frame = CGRectMake(0, 0, MAX(48, ceil(pill.bounds.size.width) + 4), 22);
        cell.accessoryView = pill;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        cell.accessoryView = nil;
    }
    UIProgressView *liveProgress = (UIProgressView *)[cell.contentView viewWithTag:9102];
    if (!liveProgress) {
        liveProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        liveProgress.tag = 9102;
        liveProgress.accessibilityIdentifier = @"epg.live.progress";
        liveProgress.layer.cornerRadius = 1.5;
        liveProgress.clipsToBounds = YES;
        liveProgress.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [cell.contentView addSubview:liveProgress];
    }
    liveProgress.trackTintColor = [HostBorder() colorWithAlphaComponent:0.25];
    liveProgress.progressTintColor = HostAccent();
    liveProgress.hidden = !live;
    if (live) {
        float progress = (end > start) ? (float)MIN(1.0, MAX(0.05, (now - start) / (end - start))) : 0.5f;
        liveProgress.progress = progress;
        liveProgress.frame = CGRectMake(16, MAX(0, CGRectGetHeight(cell.contentView.bounds) - 6), MAX(0, CGRectGetWidth(cell.contentView.bounds) - 32), 3);
        cell.textLabel.textColor = HostAccent();
        NSString *liveSuffix = activeReplayRow ? @"  ● 正在回看本节目" : (replayable ? @"  点按从头回看" : @"");
        cell.detailTextLabel.text = [range stringByAppendingFormat:@"  ● 正在播出 · %.0f%%%@", progress * 100.0, liveSuffix];
    } else if (end <= now) {
        cell.textLabel.textColor = activeReplayRow ? HostAccent() : (replayable ? HostText() : HostSecondaryText());
        if (activeReplayRow) cell.detailTextLabel.text = [range stringByAppendingString:@"  ● 正在回看"];
        else if (replayable) cell.detailTextLabel.text = [range stringByAppendingString:@"  点按回看"];
    } else {
        cell.textLabel.textColor = HostText();
        if([self isProgramReminded:row])cell.detailTextLabel.text=[range stringByAppendingString:@"  ⏰ 已预约"];
    }
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@，%@%@", row[@"title"] ?: @"", range, activeReplayRow ? @"，正在回看" : (live ? (replayable ? @"，正在播出，点按从头回看" : @"，正在播出") : (end <= now ? (replayable ? @"，已播出，点按回看" : @"，已播出") : ([self isProgramReminded:row] ? @"，尚未播出，已预约" : @"，尚未播出")))];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if(indexPath.row>=self.rows.count)return;
    NSDictionary *program=self.rows[indexPath.row];NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    NSTimeInterval start=[program[@"start"] doubleValue],end=[program[@"end"] doubleValue];
    if(start>now){[self toggleReminderForProgram:program];return;}
    if(!self.onReplay)return;
    if(now>=start && now<end){
        NSMutableDictionary *liveProgram=[program mutableCopy];
        liveProgram[@"end"]=@(MAX(start+1,now));
        liveProgram[@"liveRestart"]=@YES;
        if(self.canReplay && !self.canReplay(liveProgram))return;
        self.onReplay(liveProgram.copy);
        return;
    }
    if(end>now || (self.canReplay&&!self.canReplay(program)))return;
    self.onReplay(program);
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

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)point;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.rows.count) return nil;
    NSDictionary *program = self.rows[(NSUInteger)indexPath.row];
    NSString *title = [program[@"title"] isKindOfClass:NSString.class] ? program[@"title"] : @"节目";
    NSTimeInterval start = [program[@"start"] doubleValue], end = [program[@"end"] doubleValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL live = (now >= start && now < end);
    NSDictionary *liveCandidate = live ? @{@"start":@(start), @"end":@(MAX(start + 1, now)), @"title":title, @"liveRestart":@YES} : program;
    BOOL replayable = self.onReplay && (end <= now || (live && (now - start >= 15))) && (!self.canReplay || self.canReplay(live ? liveCandidate : program));
    BOOL reminded = [self isProgramReminded:program];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:indexPath previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
        if (replayable) {
            [actions addObject:[UIAction actionWithTitle:live ? @"从头回看本节目" : @"回看此节目" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(__unused UIAction *a) {
                EPGViewController *owner = weakSelf;
                if (owner && owner.onReplay) owner.onReplay(live ? liveCandidate : program);
            }]];
        }
        if (start > now) {
            [actions addObject:[UIAction actionWithTitle:reminded ? @"取消开播提醒" : @"预约开播前 5 分钟提醒" image:[UIImage systemImageNamed:reminded ? @"bell.slash" : @"bell.badge"] identifier:nil handler:^(__unused UIAction *a) {
                [weakSelf toggleReminderForProgram:program];
            }]];
        }
        [actions addObject:[UIAction actionWithTitle:@"复制节目名称与时间" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a) {
            UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
            NSString *detail = c.detailTextLabel.text ?: @"";
            UIPasteboard.generalPasteboard.string = detail.length ? [NSString stringWithFormat:@"%@（%@）", title, detail] : title;
            weakSelf.hint.text = [NSString stringWithFormat:@"已复制节目：%@", title];
        }]];
        return [UIMenu menuWithTitle:title children:actions];
    }];
}

@end
