#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import "EPGViewController.h"
#import "M3UParser.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static NSString *const kBuildTag = @"0.9.0";
// 这两个键名来自 CNPlayerSDK 导出常量（值即常量名本身），SDK 缺 Title 会直接拒播并报错误码 4012
static NSString *const kOptTitle = @"CNPlayerConfigOptionKey_Title";
static NSString *const kOptDefaultRate = @"CNPlayerConfigOptionKey_DefaultRate";
static NSString *const kLicenseUrl = @"https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense";

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
// 播放
@property (nonatomic, strong) UIView *playerBox;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIStackView *controlBar;
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) UIButton *muteBtn;
@property (nonatomic, strong) UIButton *routeBtn;
@property (nonatomic, strong) UIButton *epgBtn;
@property (nonatomic, strong) UIButton *fullBtn;
@property (nonatomic, strong) UIButton *logBtn;
@property (nonatomic, strong) id currentPlayer;
@property (nonatomic, strong) id sdkPlayer;
@property (nonatomic, strong) AVPlayer *avPlayer;
@property (nonatomic, strong) AVPlayerLayer *avLayer;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *subscriptions;
@property (nonatomic, strong) NSMutableSet<NSString *> *subscriptionURLs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *epgCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *epgInflight;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recents;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) CicadaPlayer *cicadaPlayer;
@property (nonatomic, copy) NSString *channelID;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, copy) NSString *routeName;
@property (nonatomic, assign) BOOL firstRender;
@property (nonatomic, assign) BOOL fullscreen;
@property (nonatomic, assign) BOOL stallReported;
// 频道
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISegmentedControl *groupControl;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *allChannels;
@property (nonatomic, strong) NSArray<NSDictionary *> *shownChannels;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) BOOL cicadaPending;
@property (nonatomic, strong) NSTimer *cicadaFallbackTimer;
// 日志
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, assign) BOOL logVisible;
// 计时
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) NSInteger watchdogTicks;
@property (nonatomic, strong) NSTimer *epgTimer;
@property (nonatomic, strong) NSURLSessionDataTask *epgTask;
@property (nonatomic, copy) NSString *epgChannel;
@end

@implementation RootViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1];
    self.title = @"CCTVHost";
    self.logBuffer = [NSMutableString string];
    self.retryCount = 0;

    [self loadChannels];
    [self buildPlayer];
    [self buildList];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"订阅" style:UIBarButtonItemStylePlain target:self action:@selector(addSubscription)];
    [self activateAudioSession];
    [self registerCallbackProtocol];
    [self setupSDK];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.watchdog invalidate];
    [self.epgTimer invalidate];
    [self.epgTask cancel];
}

- (void)onBackground {
    [self call:self.currentPlayer sel:@"resignActive"];
    [self log:@"进入后台"];
}

- (void)onForeground {
    [self call:self.currentPlayer sel:@"becomeActive"];
    [self log:@"回到前台"];
}

#pragma mark - 日志

- (void)log:(NSString *)format, ... {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"[CCTVHost] %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendFormat:@"%@\n", msg];
        if (self.logBuffer.length > 20000) {
            [self.logBuffer deleteCharactersInRange:NSMakeRange(0, self.logBuffer.length - 16000)];
        }
        if (self.logVisible) {
            self.logView.text = self.logBuffer;
            [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
        }
        NSString *one = [msg componentsSeparatedByString:@"\n"].firstObject ?: @"";
        if (one.length > 30) one = [[one substringToIndex:30] stringByAppendingString:@"…"];
        self.infoLabel.text = one;
    });
}

- (void)toggleLog {
    if (self.logVisible) {
        self.logView.hidden = YES;
        self.logVisible = NO;
        [self.logBtn setTitle:@"日志" forState:UIControlStateNormal];
        return;
    }
    self.logVisible = YES;
    self.logView.text = self.logBuffer;
    self.logView.hidden = NO;
    [self.view bringSubviewToFront:self.logView];
    [self.logBtn setTitle:@"关闭日志" forState:UIControlStateNormal];
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
}

#pragma mark - 播放区

- (void)buildPlayer {
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = w * 9.0 / 16.0;
    self.playerBox = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    self.playerBox.backgroundColor = UIColor.blackColor;
    self.playerBox.clipsToBounds = YES;
    [self.view addSubview:self.playerBox];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 20)];
    self.titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    self.titleLabel.text = @"选择频道开始播放";
    [self.playerBox addSubview:self.titleLabel];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 26, w - 24, 16)];
    self.infoLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    self.infoLabel.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.infoLabel.text = [NSString stringWithFormat:@"版本 %@", kBuildTag];
    [self.playerBox addSubview:self.infoLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(w / 2, h / 2);
    self.spinner.hidesWhenStopped = YES;
    [self.playerBox addSubview:self.spinner];

    self.controlBar = [[UIStackView alloc] initWithFrame:CGRectMake(8, h - 36, w - 16, 28)];
    self.controlBar.axis = UILayoutConstraintAxisHorizontal;
    self.controlBar.distribution = UIStackViewDistributionFillEqually;
    self.controlBar.spacing = 5;
    self.playPauseBtn = [self barButton:@"暂停" action:@selector(togglePlayPause)];
    self.muteBtn = [self barButton:@"静音" action:@selector(toggleMute)];
    self.routeBtn = [self barButton:@"线路" action:@selector(showRoutes)];
    self.epgBtn = [self barButton:@"节目单" action:@selector(openEPG)];
    self.fullBtn = [self barButton:@"全屏" action:@selector(toggleFullscreen)];
    self.logBtn = [self barButton:@"日志" action:@selector(toggleLog)];
    for (UIButton *b in @[self.playPauseBtn, self.muteBtn, self.routeBtn, self.epgBtn, self.fullBtn, self.logBtn]) {
        [self.controlBar addArrangedSubview:b];
    }
    [self.playerBox addSubview:self.controlBar];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleOverlay)];
    [self.playerBox addGestureRecognizer:tap];
}

- (UIButton *)barButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b.titleLabel setFont:[UIFont systemFontOfSize:11]];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    b.layer.cornerRadius = 5;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)toggleOverlay {
    self.titleLabel.hidden = !self.titleLabel.hidden;
    self.infoLabel.hidden = !self.infoLabel.hidden;
    self.controlBar.hidden = !self.controlBar.hidden;
}

#pragma mark - 列表

- (void)buildList {
    CGFloat y = CGRectGetMaxY(self.playerBox.frame);
    self.groupControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"央视", @"卫视", @"地方", @"教育", @"订阅"]];
    self.groupControl.frame = CGRectMake(8, y + 6, self.view.bounds.size.width - 16, 28);
    self.groupControl.selectedSegmentIndex = 0;
    self.groupControl.tintColor = [UIColor colorWithWhite:0.75 alpha:1];
    [self.groupControl addTarget:self action:@selector(onGroupChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.groupControl];

    self.versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, y + 38, self.view.bounds.size.width - 16, 14)];
    self.versionLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];
    self.versionLabel.font = [UIFont systemFontOfSize:9];
    self.versionLabel.text = [NSString stringWithFormat:@"%@ · 点击自动播放 · 长按选线路", kBuildTag];
    [self.view addSubview:self.versionLabel];

    CGFloat ty = y + 54;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, ty, self.view.bounds.size.width, self.view.bounds.size.height - ty) style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 48;
    self.table.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.table.separatorColor = [UIColor colorWithWhite:0.16 alpha:1];
    [self.view addSubview:self.table];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.table addGestureRecognizer:lp];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索频道";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;

    self.logView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.03 alpha:0.98];
    self.logView.textColor = [UIColor colorWithRed:0.62 green:0.9 blue:0.65 alpha:1];
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.hidden = YES;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.logView];
}

- (void)loadChannels {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"channels" ofType:@"json"];
    NSArray *arr = nil;
    if (path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    }
    self.allChannels = [arr isKindOfClass:NSArray.class] ? arr : @[];
    self.shownChannels = self.allChannels;
    self.epgCache = [NSMutableDictionary dictionary];
    self.epgInflight = [NSMutableSet set];
    self.recents = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"recents"] ?: @[]];
    self.subscriptions = [NSMutableArray array];
    self.subscriptionURLs = [NSMutableSet set];
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"subscriptions"];
    for (NSString *u in saved) {
        [self.subscriptionURLs addObject:u];
        [self fetchSubscription:u silent:YES];
    }
    [self log:@"频道 %lu 个 / 线路 %lu 条",
         (unsigned long)self.allChannels.count,
         (unsigned long)[[self.allChannels valueForKeyPath:@"@sum.routes.@count"] integerValue]];
}

- (void)onGroupChanged {
    [self applyFilter];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    return self.recents.count && !self.query.length && self.groupControl.selectedSegmentIndex == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if ([self numberOfSectionsInTableView:t] == 2) return s == 0 ? @"最近观看" : @"全部频道";
    return nil;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if ([self numberOfSectionsInTableView:t] == 2 && s == 0) return (NSInteger)self.recents.count;
    return (NSInteger)self.shownChannels.count;
}

- (NSArray<NSDictionary *> *)channelsForSection:(NSInteger)section tableView:(UITableView *)t {
    if ([self numberOfSectionsInTableView:t] == 2 && section == 0) return self.recents;
    return self.shownChannels;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"ch";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        UIView *bg = [[UIView alloc] init];
        bg.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        cell.selectedBackgroundView = bg;
    }
    NSArray *rows = [self channelsForSection:ip.section tableView:t];
    NSDictionary *ch = rows[ip.row];
    BOOL playing = [ch[@"id"] isEqualToString:self.channelID];
    cell.textLabel.textColor = playing ? [UIColor colorWithRed:0.35 green:0.85 blue:0.55 alpha:1] : UIColor.whiteColor;
    cell.textLabel.text = playing ? [NSString stringWithFormat:@"● %@", ch[@"name"]] : ch[@"name"];

    NSDictionary *epg = self.epgCache[ch[@"id"] ?: @""];
    if (epg[@"now"]) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"正在播：%@", epg[@"now"]];
    } else if ([ch[@"remoteURL"] length]) {
        cell.detailTextLabel.text = @"订阅源";
    } else {
        NSUInteger n = [ch[@"routes"] isKindOfClass:NSArray.class] ? [ch[@"routes"] count] : 0;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu 线路", ch[@"group"], (unsigned long)n];
    }
    [self loadEPGForChannel:ch[@"id"] section:ip];
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSArray *rows = [self channelsForSection:ip.section tableView:t];
    NSDictionary *ch = rows[ip.row];
    [self rememberChannel:ch];
    if ([ch[@"remoteURL"] length]) { [self playRemote:ch]; return; }
    [self playChannel:ch route:nil];      // 单击 = 自动选线直接播放
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint pt = [g locationInView:self.table];
    NSIndexPath *ip = [self.table indexPathForRowAtPoint:pt];
    if (!ip) return;
    NSArray *rows = [self channelsForSection:ip.section tableView:self.table];
    NSDictionary *ch = rows[ip.row];
    if ([ch[@"remoteURL"] length]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:ch[@"name"] message:@"订阅条目" preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"从列表移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            NSMutableArray *m = [self.allChannels mutableCopy];
            [m removeObject:ch];
            self.allChannels = m; self.shownChannels = m;
            [self.table reloadData];
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = self.table;
        a.popoverPresentationController.sourceRect = [self.table rectForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    [self presentRouteSheetForChannel:ch fromIndexPath:ip];
}

#pragma mark - 线路

- (void)showRoutes {
    if (!self.channelID.length) { [self log:@"请先选择频道"]; return; }
    NSDictionary *ch = [self channelWithID:self.channelID];
    if (!ch) return;
    [self presentRouteSheetForChannel:ch fromIndexPath:nil];
}

- (NSDictionary *)channelWithID:(NSString *)cid {
    for (NSDictionary *c in self.allChannels) {
        if ([c[@"id"] isEqualToString:cid]) return c;
    }
    return nil;
}

- (void)presentRouteSheetForChannel:(NSDictionary *)ch fromIndexPath:(NSIndexPath *)ip {
    NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:ch[@"name"]
                                                                  message:[NSString stringWithFormat:@"当前：%@ · %lu 条线路",
                                                                           self.routeName ?: @"自动", (unsigned long)routes.count]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"自动选线（推荐）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self playChannel:ch route:nil];
    }]];
    for (NSDictionary *r in routes) {
        NSString *res = [r[@"w"] intValue] > 0 ? [NSString stringWithFormat:@"%dx%d", [r[@"w"] intValue], [r[@"h"] intValue]] : @"";
        NSString *title = [NSString stringWithFormat:@"节点 %@ %@", [r[@"provider"] uppercaseString], res];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self playChannel:ch route:r];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self openEPGforChannel:ch[@"id"] name:ch[@"name"]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ip && self.table) {
        sheet.popoverPresentationController.sourceView = self.table;
        sheet.popoverPresentationController.sourceRect = [self.table rectForRowAtIndexPath:ip];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - SDK

- (void)registerCallbackProtocol {
    Protocol *proto = NSProtocolFromString(@"CNPlayerCallbackProtocol");
    if (!proto) { [self log:@"回调协议不可见"]; return; }
    if (!class_conformsToProtocol(self.class, proto)) {
        class_addProtocol(self.class, proto);
        [self log:@"已注册回调协议"];
    }
}

- (void)activateAudioSession {
    Class sessionCls = NSClassFromString(@"AVAudioSession");
    if (!sessionCls) return;
    id session = ((id (*)(id, SEL))objc_msgSend)(sessionCls, NSSelectorFromString(@"sharedInstance"));
    if (!session) return;
    BOOL (*setCategory)(id, SEL, NSString *, NSError **) = (void *)objc_msgSend;
    BOOL (*setActive)(id, SEL, BOOL, NSError **) = (void *)objc_msgSend;
    setCategory(session, NSSelectorFromString(@"setCategory:error:"), @"AVAudioSessionCategoryPlayback", NULL);
    setActive(session, NSSelectorFromString(@"setActive:error:"), YES, NULL);
}

- (void)setupSDK {
    Class cls = NSClassFromString(@"CNPlayer");
    if (!cls) { self.titleLabel.text = @"SDK 未加载"; return; }
    @try { [CNPlayer logEnabled:YES]; } @catch (NSException *e) {}
    [self callClass:cls sel:@"configSDK_CICADA_UDRMUrl:" args:@[kLicenseUrl]];
    @try {
        [CNPlayer startPlayerSDK_Options:[CNPlayer defaultOptions]];
    } @catch (NSException *e) {
        [self log:@"启动异常 %@", e.reason];
        return;
    }
    id ver = [self callClass:cls sel:@"SDKVersion" args:@[]];
    [self log:@"SDK 启动版本 %@", ver];
    [self callClass:cls sel:@"authed" args:@[]];

    // 预热：提前建好播放器实例，缩短首次起播时间
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.sdkPlayer) return;
        id inst = nil;
        @try { inst = [[cls alloc] init]; } @catch (NSException *e) {}
        if (inst) { weakSelf.sdkPlayer = inst; [weakSelf log:@"播放器实例已预热"]; }
    });
}

#pragma mark - 播放

- (void)playChannel:(NSDictionary *)ch route:(NSDictionary *)route {
    NSString *cid = ch[@"id"];
    if (!cid.length) return;
    self.channelID = cid;
    self.channelName = ch[@"name"] ?: cid;
    self.routeName = route ? [NSString stringWithFormat:@"%@", [route[@"provider"] uppercaseString]] : @"自动";
    self.firstRender = NO;
    self.stallReported = NO;
    self.retryCount = 0;
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · 连接中", self.channelName];
    [self.spinner startAnimating];
    [self.table reloadData];
    [self log:@"起播 %@ (%@) 线路=%@", self.channelName, cid, self.routeName];

    [self stopPlayback];
    if (route[@"provider"]) {
        BOOL applied = [self applyCDNPreference:route[@"provider"]];
        if (!applied) [self log:@"CDN 偏好未生效，按默认调度播放"];
    }
    self.cicadaPending = NO;
    [self playViaSDK:cid title:self.channelName];

    [self refreshNowNext];
    [self restartEPGTimer];
}

- (void)playViaSDK:(NSString *)cid title:(NSString *)title {
    Class cls = NSClassFromString(@"CNPlayer");
    SEL playSel = NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    id inst = self.sdkPlayer;
    if (!inst || ![inst respondsToSelector:playSel]) {
        @try { inst = [[cls alloc] init]; } @catch (NSException *e) { [self log:@"init 异常 %@", e.reason]; return; }
        self.sdkPlayer = inst;
        [self log:@"创建播放器实例"];
    } else {
        [self call:inst sel:@"reset"];
        [self log:@"复用播放器实例"];
    }
    self.currentPlayer = inst;
    self.cicadaPlayer = nil;
    @try { [inst setValue:@(YES) forKey:@"autoPlay"]; } @catch (NSException *e) {}

    if (![inst respondsToSelector:playSel]) {
        [self log:@"SDK 无 playLIVEWithChannelID:"];
        self.titleLabel.text = @"接口不匹配";
        return;
    }
    NSDictionary *options = @{kOptTitle: title ?: cid};
    [self log:@"configOptions=%@", options];
    id ok = [self invokeTarget:inst selector:playSel args:@[cid, self, options]];
    if ([ok isKindOfClass:NSNumber.class] && ![ok boolValue]) {
        [self log:@"起播返回 0，重建实例重试"];
        id fresh = nil;
        @try { fresh = [[cls alloc] init]; } @catch (NSException *e) {}
        if (fresh) {
            self.sdkPlayer = fresh;
            self.currentPlayer = fresh;
            @try { [fresh setValue:@(YES) forKey:@"autoPlay"]; } @catch (NSException *e) {}
            ok = [self invokeTarget:fresh selector:playSel args:@[cid, self, options]];
            inst = fresh;
        }
    }
    if ([ok isKindOfClass:NSNumber.class] && ![ok boolValue]) {
        self.titleLabel.text = [NSString stringWithFormat:@"%@ · 起播被拒绝", self.channelName];
        [self log:@"两次起播均返回 0"];
        return;
    }
    [self attachVideoView];
    [self call:inst sel:@"prepareToPlay"];
    [self startWatchdog];
}

- (void)stopPlayback {
    if (self.currentPlayer) {
        [self call:self.currentPlayer sel:@"stop"];
        @try { [self.currentPlayer setValue:nil forKey:@"delegate"]; } @catch (NSException *e) {}
    }
    if (self.cicadaPlayer) {
        [self call:self.cicadaPlayer sel:@"destroy"];
    }
    if (self.avPlayer) {
        [self.avPlayer pause];
        @try { [self.avPlayer.currentItem removeObserver:self forKeyPath:@"status"]; } @catch (NSException *e) {}
        self.avPlayer = nil;
    }
    [self.avLayer removeFromSuperlayer];
    self.avLayer = nil;
    self.currentPlayer = nil;
    self.cicadaPlayer = nil;
    [self.watchdog invalidate];
    self.watchdog = nil;
    [self.cicadaFallbackTimer invalidate];
    self.cicadaFallbackTimer = nil;
    for (UIView *v in self.playerBox.subviews.copy) {
        if (v == self.titleLabel || v == self.infoLabel || v == self.spinner || v == self.controlBar) continue;
        [v removeFromSuperview];
    }
}

- (void)attachVideoView {
    id view = nil;
    @try { view = [self.currentPlayer valueForKey:@"view"]; } @catch (NSException *e) { return; }
    if (![view isKindOfClass:UIView.class]) return;
    UIView *v = view;
    if (v.superview != self.playerBox) {
        [self.playerBox insertSubview:v atIndex:0];
    }
    v.translatesAutoresizingMaskIntoConstraints = YES;
    v.frame = self.playerBox.bounds;
    [self.playerBox sendSubviewToBack:v];
}

- (void)togglePlayPause {
    if (self.avPlayer) {
        BOOL playing = self.avPlayer.rate > 0;
        if (playing) [self.avPlayer pause]; else [self.avPlayer play];
        [self.playPauseBtn setTitle:(playing ? @"继续" : @"暂停") forState:UIControlStateNormal];
        return;
    }
    if (!self.currentPlayer) return;
    BOOL playing = NO;
    @try { playing = [[self.currentPlayer valueForKey:@"isPlaying"] boolValue]; } @catch (NSException *e) {}
    [self call:self.currentPlayer sel:(playing ? @"pause" : @"play")];
    [self.playPauseBtn setTitle:(playing ? @"继续" : @"暂停") forState:UIControlStateNormal];
}

- (void)toggleMute {
    static BOOL muted = NO;
    if (self.avPlayer) {
        muted = !muted;
        self.avPlayer.muted = muted;
        [self.muteBtn setTitle:(muted ? @"发声" : @"静音") forState:UIControlStateNormal];
        return;
    }
    muted = !muted;
    @try { [self.currentPlayer setValue:@(muted) forKey:@"muted"]; } @catch (NSException *e) {}
    [self.muteBtn setTitle:(muted ? @"发声" : @"静音") forState:UIControlStateNormal];
}

- (void)toggleFullscreen {
    self.fullscreen = !self.fullscreen;
    CGFloat w = self.view.bounds.size.width;
    if (self.fullscreen) {
        self.playerBox.frame = CGRectMake(0, 0, w, self.view.bounds.size.height);
        self.table.hidden = YES;
        self.groupControl.hidden = YES;
        self.versionLabel.hidden = YES;
        self.navigationController.navigationBarHidden = YES;
    } else {
        self.playerBox.frame = CGRectMake(0, 0, w, w * 9.0 / 16.0);
        self.table.hidden = NO;
        self.groupControl.hidden = NO;
        self.versionLabel.hidden = NO;
        self.navigationController.navigationBarHidden = NO;
    }
    [self relayoutPlayer];
    [self attachVideoView];
    self.avLayer.frame = self.playerBox.bounds;
}

- (void)relayoutPlayer {
    CGRect b = self.playerBox.bounds;
    self.controlBar.frame = CGRectMake(8, b.size.height - 36, b.size.width - 16, 28);
    self.titleLabel.frame = CGRectMake(12, 8, b.size.width - 24, 20);
    self.infoLabel.frame = CGRectMake(12, 26, b.size.width - 24, 16);
    self.spinner.center = CGPointMake(b.size.width / 2, b.size.height / 2);
}

#pragma mark - 搜索 / 最近 / 节目单缓存

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.query = sc.searchBar.text;
    [self applyFilter];
}

- (void)applyFilter {
    NSArray *base = self.allChannels;
    NSInteger idx = self.groupControl.selectedSegmentIndex;
    NSArray *groups = @[@"全部", @"央视", @"卫视", @"地方", @"教育", @"订阅"];
    if (idx > 0 && idx < (NSInteger)groups.count) {
        NSString *g = groups[idx];
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b) {
            return [o[@"group"] isEqualToString:g];
        }]];
    }
    if (self.query.length) {
        NSString *q = self.query.lowercaseString;
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b) {
            return [[o[@"name"] lowercaseString] containsString:q] || [[o[@"id"] lowercaseString] containsString:q];
        }]];
    }
    self.shownChannels = base;
    [self.table reloadData];
}

- (void)rememberChannel:(NSDictionary *)ch {
    if (!ch[@"id"]) return;
    NSMutableDictionary *entry = [@{@"id": ch[@"id"],
                                    @"name": ch[@"name"] ?: ch[@"id"],
                                    @"group": ch[@"group"] ?: @""} mutableCopy];
    if ([ch[@"remoteURL"] length]) entry[@"remoteURL"] = ch[@"remoteURL"];
    NSMutableArray *m = [NSMutableArray arrayWithObject:entry];
    for (NSDictionary *r in self.recents) {
        if (![r[@"id"] isEqualToString:ch[@"id"]] && m.count < 8) [m addObject:r];
    }
    self.recents = m;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"recents"];
}

- (void)onPullRefresh {
    for (NSString *u in self.subscriptionURLs.allObjects) [self fetchSubscription:u silent:YES];
    [self.table.refreshControl endRefreshing];
}

- (void)loadEPGForChannel:(NSString *)cid section:(NSIndexPath *)ip {
    if (!cid.length || self.epgCache[cid] || [self.epgInflight containsObject:cid]) return;
    if (self.epgInflight.count >= 3) return;
    [self.epgInflight addObject:cid];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox",
                     [cid stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 8;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.epgInflight removeObject:cid];
            if (!data.length) return;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSArray *rows = [json isKindOfClass:NSDictionary.class] ? [(NSDictionary *)json objectForKey:@"EPG"] : nil;
            if (![rows isKindOfClass:NSArray.class]) return;
            double now = NSDate.date.timeIntervalSince1970;
            NSString *cur = nil, *nxt = nil;
            for (NSDictionary *row in rows) {
                if (![row isKindOfClass:NSDictionary.class]) continue;
                double s0 = [row[@"startTime"] doubleValue], e0 = [row[@"endTime"] doubleValue];
                if (s0 > 1e11) s0 /= 1000; if (e0 > 1e11) e0 /= 1000;
                if (now >= s0 && now < e0) cur = row[@"title"];
                else if (s0 > now && !nxt) nxt = row[@"title"];
            }
            if (cur || nxt) {
                weakSelf.epgCache[cid] = @{@"now": cur ?: @"", @"next": nxt ?: @""};
                [weakSelf.table reloadData];
            }
        });
    }] resume];
}

#pragma mark - 订阅（m3u 源 / 本地插件）

- (void)addSubscription {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加订阅"
                                                              message:@"输入 m3u/m3u8 地址，例如插件输出的 http://127.0.0.1:8767/all.m3u"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"http://127.0.0.1:8767/all.m3u";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *u = a.textFields.firstObject.text;
        if (!u.length) return;
        [self.subscriptionURLs addObject:u];
        [[NSUserDefaults standardUserDefaults] setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
        [self fetchSubscription:u silent:NO];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)fetchSubscription:(NSString *)urlString silent:(BOOL)silent {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSArray<M3UChannel *> *list = text.length ? [M3UParser parse:text baseURL:url] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!list.count) {
                [weakSelf log:@"订阅失败 %@ %@", urlString, err.localizedDescription ?: @"无有效条目"];
                return;
            }
            NSMutableArray *merged = [NSMutableArray arrayWithArray:weakSelf.allChannels ?: @[]];
            NSMutableSet *names = [NSMutableSet set];
            for (NSDictionary *c in merged) [names addObject:c[@"id"]];
            NSUInteger added = 0;
            for (M3UChannel *c in list) {
                id key = c.url;
                if ([names containsObject:key]) continue;
                [names addObject:key];
                [merged addObject:@{@"id": c.name ?: c.url,
                                    @"name": c.name ?: c.url,
                                    @"group": c.group ?: @"订阅",
                                    @"verified": @NO,
                                    @"remoteURL": c.url}];
                added++;
            }
            weakSelf.allChannels = merged;
            weakSelf.shownChannels = merged;
            [weakSelf.table reloadData];
            [weakSelf log:@"订阅 %@ 新增 %lu 个频道（共 %lu）", urlString, (unsigned long)added, (unsigned long)list.count];
        });
    }] resume];
}

- (void)playRemote:(NSDictionary *)ch {
    NSString *u = ch[@"remoteURL"];
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return;
    [self stopPlayback];
    self.channelID = ch[@"id"];
    self.channelName = ch[@"name"];
    self.routeName = @"订阅";
    self.firstRender = NO;
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · 连接中", self.channelName];
    [self.spinner startAnimating];
    [self log:@"订阅起播 %@", u];
    [self.table reloadData];

    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.avPlayer = [AVPlayer playerWithPlayerItem:item];
    self.avLayer = [AVPlayerLayer playerLayerWithPlayer:self.avPlayer];
    self.avLayer.frame = self.playerBox.bounds;
    self.avLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.playerBox.layer insertSublayer:self.avLayer atIndex:0];
    [self.avPlayer play];

    __weak typeof(self) weakSelf = self;
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakSelf.firstRender) {
            [weakSelf log:@"订阅 12 秒未出画面"];
            weakSelf.titleLabel.text = [NSString stringWithFormat:@"%@ · 无画面", weakSelf.channelName];
        }
    });
}

- (void)avItemFailed:(NSNotification *)n {
    NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self log:@"订阅播放失败 %@", e.localizedDescription];
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)ch context:(void *)ctx {
    if ([kp isEqualToString:@"status"]) {
        AVPlayerItem *item = obj;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            self.firstRender = YES;
            [self.spinner stopAnimating];
            self.titleLabel.text = self.channelName;
            [self log:@"订阅就绪，开始播放"];
        } else if (item.status == AVPlayerItemStatusFailed) {
            [self.spinner stopAnimating];
            self.titleLabel.text = [NSString stringWithFormat:@"%@ · 失败", self.channelName];
            [self log:@"订阅失败 %@", item.error.localizedDescription];
        }
    }
}

#pragma mark - CDN 偏好

- (BOOL)applyCDNPreference:(NSString *)code {
    Class itemCls = NSClassFromString(@"CNPlayerHlsCdnInfoItem");
    Class playerCls = NSClassFromString(@"CNPlayer");
    SEL setSel = NSSelectorFromString(@"configSDK_CDN_LIVEDefaultCDNInfo:");
    SEL getSel = NSSelectorFromString(@"getVDNConfig_CDNLive_DefaultCDNInfo");
    if (!itemCls || !playerCls || ![playerCls respondsToSelector:setSel]) {
        [self log:@"SDK 无 CDN 偏好接口"];
        return NO;
    }
    id item = nil;
    @try { item = [[itemCls alloc] init]; } @catch (NSException *e) { return NO; }
    [item setValue:code.lowercaseString forKey:@"cdn_code"];
    [item setValue:code.uppercaseString forKey:@"cdn_name"];
    @try { [item setValue:@(0) forKey:@"cdn_vip"]; } @catch (NSException *e) {}

    // 参数既可能是数组也可能是单个对象，两种都试，并用 getter 校验
    [self invokeTarget:playerCls selector:setSel args:@[@[item]]];
    id now = [self invokeTarget:playerCls selector:getSel args:@[]];
    if (!now) {
        [self invokeTarget:playerCls selector:setSel args:@[item]];
        now = [self invokeTarget:playerCls selector:getSel args:@[]];
    }
    [self log:@"CDN 偏好 %@ 生效值=%@", code, now ?: @"(空)"];
    return now != nil;
}

#pragma mark - 节点失败自动回退

- (void)armCicadaFallback {
    [self.cicadaFallbackTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.cicadaFallbackTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || !self2.cicadaPending) { [t invalidate]; return; }
        if (self2.firstRender) { [t invalidate]; return; }
        if (self2.watchdogTicks < 7) return;      // 约 7 秒仍未出画面
        [t invalidate];
        self2.cicadaPending = NO;
        [self2 log:@"节点 7 秒无画面，回退自动选线"];
        self2.titleLabel.text = [NSString stringWithFormat:@"%@ · 节点无画面，切回自动", self2.channelName];
        [self2 stopPlayback];
        [self2 playViaSDK:self2.channelID title:self2.channelName];
    }];
}

#pragma mark - 节目单

- (void)openEPG {
    if (!self.channelID.length) { [self log:@"请先选择频道"]; return; }
    [self openEPGforChannel:self.channelID name:self.channelName];
}

- (void)openEPGforChannel:(NSString *)cid name:(NSString *)name {
    [self.navigationController pushViewController:[[EPGViewController alloc] initWithChannelID:cid name:name] animated:YES];
}

- (void)restartEPGTimer {
    [self.epgTimer invalidate];
    self.epgTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshNowNext) userInfo:nil repeats:YES];
}

- (void)refreshNowNext {
    NSString *cid = self.channelID;
    if (!cid.length) return;
    self.epgChannel = cid;
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox",
                     [cid stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 8;

    __weak typeof(self) weakSelf = self;
    [self.epgTask cancel];
    self.epgTask = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data.length) return;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        NSArray *rows = [(NSDictionary *)json objectForKey:@"EPG"];
        if (![rows isKindOfClass:NSArray.class]) return;
        double now = NSDate.date.timeIntervalSince1970;
        NSString *cur = nil, *next = nil;
        for (NSDictionary *row in rows) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            double s0 = [row[@"startTime"] doubleValue], e0 = [row[@"endTime"] doubleValue];
            if (s0 > 1e11) s0 /= 1000; if (e0 > 1e11) e0 /= 1000;
            if (now >= s0 && now < e0) cur = row[@"title"];
            else if (s0 > now && !next) next = row[@"title"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![weakSelf.epgChannel isEqualToString:cid]) return;
            NSMutableArray *parts = [NSMutableArray array];
            if (cur) [parts addObject:[NSString stringWithFormat:@"正在播：%@", cur]];
            if (next) [parts addObject:[NSString stringWithFormat:@"接下来：%@", next]];
            if (parts.count) weakSelf.infoLabel.text = [parts componentsJoinedByString:@"  "];
        });
    }];
    [self.epgTask resume];
}

#pragma mark - 监视

- (void)startWatchdog {
    [self.watchdog invalidate];
    self.watchdogTicks = 0;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (void)tick:(NSTimer *)timer {
    self.watchdogTicks += 1;
    if (!self.currentPlayer) { [timer invalidate]; return; }
    [self attachVideoView];
    if (self.firstRender) { [timer invalidate]; return; }
    if (self.watchdogTicks == 20) {     // 10 秒
        self.titleLabel.text = [NSString stringWithFormat:@"%@ · 缓冲中…", self.channelName];
        [self log:@"10 秒未首帧"];
    }
    if (self.watchdogTicks >= 40) {     // 20 秒
        [timer invalidate];
        [self.spinner stopAnimating];
        self.titleLabel.text = [NSString stringWithFormat:@"%@ · 无画面", self.channelName];
        [self log:@"20 秒未首帧，停止等待"];
    }
}

#pragma mark - 通用调用

- (id)callClass:(Class)cls sel:(NSString *)name args:(NSArray *)args {
    return [self invokeTarget:cls selector:NSSelectorFromString(name) args:args];
}

- (id)call:(id)obj sel:(NSString *)name {
    return [self invokeTarget:obj selector:NSSelectorFromString(name) args:@[]];
}

- (id)call:(id)obj sel:(NSString *)name args:(NSArray *)args {
    return [self invokeTarget:obj selector:NSSelectorFromString(name) args:args];
}

- (id)invokeTarget:(id)target selector:(SEL)sel args:(NSArray *)args {
    if (!target || ![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    for (NSUInteger i = 0; i < args.count && i + 2 < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i + 2];
        id v = args[i];
        if (v == NSNull.null) { id z = nil; [inv setArgument:&z atIndex:i + 2]; continue; }
        if (strcmp(t, "@") == 0 || strcmp(t, "@?") == 0) {
            id a = v; [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "B") == 0 || strcmp(t, "c") == 0) {
            char a = [v boolValue]; [inv setArgument:&a atIndex:i + 2];
        } else if (strcmp(t, "q") == 0 || strcmp(t, "l") == 0) {
            long long a = [v longLongValue]; [inv setArgument:&a atIndex:i + 2];
        }
    }
    @try { [inv invoke]; } @catch (NSException *e) {
        [self log:@"调用 %@ 异常 %@", NSStringFromSelector(sel), e.reason];
        return nil;
    }
    const char *rt = sig.methodReturnType;
    if (rt[0] == '@') { void *p = NULL; [inv getReturnValue:&p]; return (__bridge id)p; }
    if (rt[0] == 'B' || rt[0] == 'c') { char r = 0; [inv getReturnValue:&r]; return @(r != 0); }
    return nil;
}

#pragma mark - SDK 回调

- (void)player:(id)player loadStateDidChanged:(NSUInteger)state {
    [self attachVideoView];
    if (state == 4) {                     // PrepareDone
        [self log:@"PrepareDone → play"];
        [self call:self.currentPlayer sel:@"play"];
    } else if (state == 13) {
        [self log:@"加载取消"];
    }
}

- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    if (state == 3) [self log:@"VDN 成功"];
    else if (state == 2) [self log:@"VDN 失败"];
}

- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if (event == 3) {
        self.firstRender = YES;
        self.cicadaPending = NO;
        [self.cicadaFallbackTimer invalidate];
        [self.spinner stopAnimating];
        self.titleLabel.text = self.channelName;
        [self log:@"首帧渲染"];
    }
}

- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    if (state == 1) [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    if (state == 2) [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal];
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    [self log:@"播放失败 %ld %@", (long)error.code, error.localizedDescription];
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · 播放失败", self.channelName];
    [self.spinner stopAnimating];
    if (self.retryCount < 1 && !self.firstRender) {
        self.retryCount += 1;
        [self log:@"失败重试一次"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.channelID.length) [self playViaSDK:self.channelID title:self.channelName];
        });
    }
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    [self log:@"VDN 请求失败 %ld", (long)error.code];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    [self log:@"参数错误 %ld", (long)error.code];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    [self log:@"版权请求失败 %ld", (long)error.code];
}

- (void)authFailed:(NSError *)error {
    [self log:@"鉴权失败 %ld", (long)error.code];
    self.titleLabel.text = @"鉴权失败";
}

@end
