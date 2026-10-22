#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import "EPGViewController.h"
#import "M3UParser.h"
#import "PyHost.h"
#import "PluginViewController.h"
#import "SettingsViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static NSString *const kBuildTag = @"0.14.0";
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *subscriptionRequestVersions;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *epgCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *epgInflight;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recents;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) CicadaPlayer *cicadaPlayer;
@property (nonatomic, copy) NSString *channelID;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, copy) NSString *currentRemoteURL;
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
@property (nonatomic, assign) BOOL logRefreshPending;
@property (nonatomic, assign) NSUInteger playbackGeneration;
@property (nonatomic, strong) UIToolbar *logToolbar;
@property (nonatomic, assign) BOOL logVisible;
// 计时
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) NSInteger watchdogTicks;
@property (nonatomic, strong) NSTimer *epgTimer;
@property (nonatomic, strong) NSURLSessionDataTask *epgTask;
@property (nonatomic, strong) MPVolumeView *volumeView;
@property (nonatomic, assign) NSTimeInterval playStartedAt;
@property (nonatomic, assign) NSTimeInterval firstFrameSeconds;
@property (nonatomic, strong) NSMutableArray<NSString *> *favorites;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *altSources;
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, strong) PluginViewController *pluginPage;
@property (nonatomic, strong) UIStackView *bottomBar;
@property (nonatomic, assign) NSInteger activeTab;
@property (nonatomic, assign) BOOL favoritesOnly;
@property (nonatomic, strong) UIButton *pipBtn;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"插件" style:UIBarButtonItemStylePlain target:self action:@selector(openPluginPage)];
    [self activateAudioSession];
    [self setupRemoteCommands];
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
        if (self.logVisible && !self.logRefreshPending) {
            self.logRefreshPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.logRefreshPending = NO;
                if (!self.logVisible) return;
                self.logView.text = self.logBuffer;
                [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
            });
        }
        NSString *one = [msg componentsSeparatedByString:@"\n"].firstObject ?: @"";
        if (one.length > 30) one = [[one substringToIndex:30] stringByAppendingString:@"…"];
        self.infoLabel.text = one;
    });
}

- (void)togglePiP {
    if (!AVPictureInPictureController.isPictureInPictureSupported) { [self log:@"设备不支持画中画"]; return; }
    if (!self.avLayer) { [self log:@"画中画仅支持订阅源（AVPlayer）"]; return; }
    if (self.pip && self.pip.isPictureInPictureActive) { [self.pip stopPictureInPicture]; return; }
    self.pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.avLayer];
    [self.pip startPictureInPicture];
    [self log:@"进入画中画"];
}

- (void)toggleLog {
    if (self.logVisible) {
        self.logView.hidden = YES;
        self.logToolbar.hidden = YES;
        self.logVisible = NO;
        [self.logBtn setTitle:@"日志" forState:UIControlStateNormal];
        return;
    }
    self.logVisible = YES;
    self.logView.text = self.logBuffer;
    self.logView.hidden = NO;
    [self.view bringSubviewToFront:self.logView];
    self.logToolbar.hidden = NO;
    [self.view bringSubviewToFront:self.logToolbar];
    [self.view setNeedsLayout];
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
    self.pipBtn = [self barButton:@"画中画" action:@selector(togglePiP)];
    for (UIButton *b in @[self.playPauseBtn, self.muteBtn, self.routeBtn, self.epgBtn, self.fullBtn, self.logBtn, self.pipBtn]) {
        [self.controlBar addArrangedSubview:b];
    }
    [self.playerBox addSubview:self.controlBar];

    self.volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-2000, -2000, 10, 10)];
    self.volumeView.showsRouteButton = NO;
    [self.view addSubview:self.volumeView];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.playerBox addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleOverlay)];
    [self.playerBox addGestureRecognizer:tap];
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFullscreen)];
    doubleTap.numberOfTapsRequired = 2;
    [self.playerBox addGestureRecognizer:doubleTap];
    [tap requireGestureRecognizerToFail:doubleTap];
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
    self.groupControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"央视", @"卫视", @"地方", @"教育", @"熊猫", @"订阅"]];
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
    self.table.rowHeight = 158;
    self.table.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.table.separatorColor = [UIColor colorWithWhite:0.16 alpha:1];
    [self.view addSubview:self.table];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;
    [self buildBottomBar];

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
    self.logToolbar = [[UIToolbar alloc] init];
    self.logToolbar.barStyle = UIBarStyleBlack;
    self.logToolbar.items = @[
        [[UIBarButtonItem alloc] initWithTitle:@"关闭日志" style:UIBarButtonItemStyleDone target:self action:@selector(toggleLog)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(copyDiagnosticLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearDiagnosticLog)]
    ];
    self.logToolbar.hidden = YES;
    [self.view addSubview:self.logToolbar];
}

- (void)copyDiagnosticLog {
    UIPasteboard.generalPasteboard.string = self.logBuffer ?: @"";
}

- (void)clearDiagnosticLog {
    [self.logBuffer setString:@""];
    self.logView.text = @"";
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
    self.favorites = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"favorites"] ?: @[]];
    self.altSources = [NSMutableDictionary dictionary];
    self.epgCache = [NSMutableDictionary dictionary];
    [self loadEPGCache];
    self.epgInflight = [NSMutableSet set];
    self.recents = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:@"recents"] ?: @[]];
    self.subscriptions = [NSMutableArray array];
    self.subscriptionURLs = [NSMutableSet set];
    self.subscriptionRequestVersions = [NSMutableDictionary dictionary];
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"subscriptions"];
    for (NSString *u in saved) {
        NSString *key = [self stableURLKey:u];
        if (key.length) [self.subscriptionURLs addObject:key];
        [self fetchSubscription:key ?: u silent:YES];
    }
    [self log:@"频道 %lu 个 / 线路 %lu 条",
         (unsigned long)self.allChannels.count,
         (unsigned long)[[self.allChannels valueForKeyPath:@"@sum.routes.@count"] integerValue]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSArray *rows = [self channelsForSection:ip.section tableView:t];
    if (ip.row >= rows.count) return nil;
    NSDictionary *ch = rows[ip.row];
    NSString *cid = ch[@"id"] ?: @"";
    BOOL fav = [self.favorites containsObject:cid];
    NSString *label = fav ? @"取消收藏" : @"收藏";
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:label
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        if (fav) [self.favorites removeObject:cid];
        else [self.favorites addObject:cid];
        [[NSUserDefaults standardUserDefaults] setObject:self.favorites forKey:@"favorites"];
        [self applyFilter];
        done(YES);
    }];
    action.backgroundColor = fav ? [UIColor colorWithWhite:0.35 alpha:1] : [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

- (void)onGroupChanged {
    self.favoritesOnly=NO; self.activeTab=0;
    for(UIButton *b in self.bottomBar.arrangedSubviews) [b setTitleColor:b.tag==0?UIColor.systemPinkColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self applyFilter];
}

- (void)buildBottomBar {
    self.bottomBar=[[UIStackView alloc] init]; self.bottomBar.axis=UILayoutConstraintAxisHorizontal; self.bottomBar.distribution=UIStackViewDistributionFillEqually; self.bottomBar.spacing=4; self.bottomBar.backgroundColor=[UIColor colorWithWhite:0.13 alpha:0.98]; self.bottomBar.layer.cornerRadius=24; self.bottomBar.clipsToBounds=YES;
    NSArray *titles=@[@"◉\n频道",@"♥\n收藏",@"▣\n服务",@"⚙\n设置"];
    for (NSInteger i=0;i<titles.count;i++) { UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=i; b.titleLabel.numberOfLines=2; b.titleLabel.textAlignment=NSTextAlignmentCenter; b.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; [b setTitle:titles[i] forState:UIControlStateNormal]; [b setTitleColor:i==0?UIColor.systemPinkColor:UIColor.whiteColor forState:UIControlStateNormal]; [b addTarget:self action:@selector(selectBottomTab:) forControlEvents:UIControlEventTouchUpInside]; [self.bottomBar addArrangedSubview:b]; }
    [self.view addSubview:self.bottomBar];
}

- (void)selectBottomTab:(UIButton *)sender {
    self.activeTab=sender.tag;
    for (UIButton *b in self.bottomBar.arrangedSubviews) [b setTitleColor:b.tag==sender.tag?UIColor.systemPinkColor:UIColor.whiteColor forState:UIControlStateNormal];
    if (sender.tag==2) { [self openPluginPage]; return; }
    if (sender.tag==3) { [self openSettingsPage]; return; }
    self.favoritesOnly=(sender.tag==1);
    if (!self.favoritesOnly) self.groupControl.selectedSegmentIndex=0;
    [self applyFilter];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    return self.recents.count && !self.favoritesOnly && !self.query.length && self.groupControl.selectedSegmentIndex == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if ([self numberOfSectionsInTableView:t] == 2) return s == 0 ? @"最近观看" : @"全部频道";
    return nil;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if ([self numberOfSectionsInTableView:t] == 2 && s == 0) return (NSInteger)((self.recents.count + 1) / 2);
    return (NSInteger)((self.shownChannels.count + 1) / 2);
}

- (NSArray<NSDictionary *> *)channelsForSection:(NSInteger)section tableView:(UITableView *)t {
    if ([self numberOfSectionsInTableView:t] == 2 && section == 0) return self.recents;
    return self.shownChannels;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *reuse=@"channel.grid";
    UITableViewCell *cell=[t dequeueReusableCellWithIdentifier:reuse];
    if(!cell){ cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuse]; cell.backgroundColor=UIColor.clearColor; cell.selectionStyle=UITableViewCellSelectionStyleNone; }
    for(UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];
    NSArray *items=[self channelsForSection:ip.section tableView:t];
    CGFloat gap=8, width=(CGRectGetWidth(t.bounds)-3*gap)/2, cardH=148;
    for(NSInteger col=0;col<2;col++){
        NSUInteger idx=(NSUInteger)ip.row*2+(NSUInteger)col; if(idx>=items.count) break;
        NSDictionary *ch=items[idx];
        UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom]; card.frame=CGRectMake(gap+col*(width+gap),5,width,cardH); card.backgroundColor=[UIColor colorWithWhite:0.12 alpha:1]; card.layer.cornerRadius=12; card.clipsToBounds=YES; card.tag=500+col;
        objc_setAssociatedObject(card, @selector(onChannelCardTap:), ch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIImageView *cover=[[UIImageView alloc]initWithFrame:CGRectMake(5,5,width-10,88)]; cover.backgroundColor=[UIColor colorWithWhite:0.2 alpha:1]; cover.contentMode=UIViewContentModeScaleAspectFit; cover.layer.cornerRadius=8; cover.clipsToBounds=YES; [card addSubview:cover];
        if([ch[@"logo"] length]) [self loadLogo:ch[@"logo"] into:cover];
        else { UILabel *mark=[[UILabel alloc]initWithFrame:cover.bounds]; mark.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight; mark.text=[ch[@"name"] isKindOfClass:NSString.class]?ch[@"name"]:ch[@"id"]; mark.textAlignment=NSTextAlignmentCenter; mark.textColor=UIColor.whiteColor; mark.font=[UIFont boldSystemFontOfSize:16]; mark.numberOfLines=2; [cover addSubview:mark]; }
        UILabel *name=[[UILabel alloc]initWithFrame:CGRectMake(7,98,width-14,21)]; name.text=[NSString stringWithFormat:@"%@%@",[self.channelID isEqual:ch[@"id"]]?@"● ":@"",[self.favorites containsObject:ch[@"id"]?:@""]?[@"★ " stringByAppendingString:ch[@"name"]?:ch[@"id"]]:ch[@"name"]?:ch[@"id"]]; name.textColor=[self.channelID isEqual:ch[@"id"]]?UIColor.systemGreenColor:UIColor.whiteColor; name.font=[UIFont boldSystemFontOfSize:13]; name.lineBreakMode=NSLineBreakByTruncatingTail; [card addSubview:name];
        NSDictionary *epg=self.epgCache[ch[@"id"]?:@""];
        NSString *detail=epg[@"now"]?[NSString stringWithFormat:@"正在播：%@",epg[@"now"]]:([ch[@"remoteURL"] length]?@"M3U 订阅":(ch[@"group"]?:@"直播"));
        UILabel *sub=[[UILabel alloc]initWithFrame:CGRectMake(7,121,width-14,18)]; sub.text=detail; sub.textColor=[UIColor colorWithWhite:0.68 alpha:1]; sub.font=[UIFont systemFontOfSize:10]; sub.lineBreakMode=NSLineBreakByTruncatingTail; [card addSubview:sub];
        [card addTarget:self action:@selector(onChannelCardTap:) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp=[[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(onLongPress:)]; [card addGestureRecognizer:lp];
        [cell.contentView addSubview:card]; [self loadEPGForChannel:ch[@"id"] section:ip];
    }
    return cell;
}

- (void)onChannelCardTap:(UIButton *)sender {
    NSDictionary *ch=objc_getAssociatedObject(sender,@selector(onChannelCardTap:)); if(!ch) return;
    [self rememberChannel:ch]; [[NSUserDefaults standardUserDefaults] setObject:ch forKey:@"lastChannel"];
    if([ch[@"remoteURL"] length]) [self playRemote:ch]; else [self playChannel:ch route:nil];
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip { }

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if(g.state!=UIGestureRecognizerStateBegan) return;
    NSDictionary *ch=objc_getAssociatedObject(g.view,@selector(onChannelCardTap:)); if(!ch) return;
    if([ch[@"remoteURL"] length]) { [self presentSubscriptionActions:ch sourceView:g.view]; return; }
    [self presentRouteSheetForChannel:ch fromIndexPath:[self indexPathForChannelID:ch[@"id"]]];
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

    // 续播：启动 2.5 秒后恢复上次频道
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"lastChannel"];
        if (![last[@"id"] length] || self.channelID.length) return;
        [self log:@"续播上次频道 %@", last[@"name"] ?: last[@"id"]];
        if ([last[@"remoteURL"] length]) [self playRemote:last];
        else [self playChannel:last route:nil];
    });

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
    self.playbackGeneration += 1;
    self.currentRemoteURL = nil;
    NSString *cid = ch[@"id"];
    if (!cid.length) return;
    self.channelID = cid;
    self.channelName = ch[@"name"] ?: cid;
    self.routeName = route ? [NSString stringWithFormat:@"%@", [route[@"provider"] uppercaseString]] : @"自动";
    self.firstRender = NO;
    self.stallReported = NO;
    self.retryCount = 0;
    self.playStartedAt = NSDate.date.timeIntervalSince1970;
    self.firstFrameSeconds = 0;
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    CGFloat top = safe.top;
    if (self.fullscreen) {
        self.playerBox.frame = self.view.bounds;
        self.bottomBar.hidden = YES;
    } else {
        CGFloat ph = MIN(w * 9.0 / 16.0, MAX(120, (height - top - safe.bottom) * 0.55));
        self.playerBox.frame = CGRectMake(0, top, w, ph);
        CGFloat y = CGRectGetMaxY(self.playerBox.frame);
        self.groupControl.frame = CGRectMake(8, y + 6, MAX(0, w - 16), 30);
        self.versionLabel.frame = CGRectMake(12, y + 39, MAX(0, w - 24), 16);
        CGFloat tabH=58;
        self.table.frame = CGRectMake(0, y + 60, w, MAX(0, height - safe.bottom - y - 60 - tabH));
        self.bottomBar.frame=CGRectMake(20, height-safe.bottom-tabH, MAX(0,w-40), 50);
        self.bottomBar.hidden=self.fullscreen;
    }
    [self relayoutPlayer];
    CGFloat overlayTop = self.fullscreen ? safe.top : 0;
    self.titleLabel.frame = CGRectMake(12 + safe.left, overlayTop + 8, MAX(0, w - safe.left - safe.right - 24), 20);
    self.infoLabel.frame = CGRectMake(12 + safe.left, overlayTop + 30, MAX(0, w - safe.left - safe.right - 24), 16);
    CGFloat bottom = self.fullscreen ? safe.bottom : 0;
    self.controlBar.frame = CGRectMake(8 + safe.left, CGRectGetHeight(self.playerBox.bounds) - bottom - 48,
                                      MAX(0, w - safe.left - safe.right - 16), 40);
    self.avLayer.frame = self.playerBox.bounds;
    self.logToolbar.frame = CGRectMake(safe.left, top, MAX(0, w - safe.left - safe.right), 44);
    self.logView.frame = CGRectMake(safe.left, top + 44, MAX(0, w - safe.left - safe.right), MAX(0, height - top - safe.bottom - 44));
    [self attachVideoView];
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
        self.bottomBar.hidden = NO;
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

#pragma mark - 订阅管理

- (void)manageSubscriptions {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"订阅源" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (!self.subscriptionURLs.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"暂无订阅" style:UIAlertActionStyleDefault handler:nil]];
    }
    for (NSString *u in self.subscriptionURLs.allObjects) {
        NSString *title = u.length > 42 ? [[u substringToIndex:42] stringByAppendingString:@"…"] : u;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            UIAlertController *op = [UIAlertController alertControllerWithTitle:u message:nil preferredStyle:UIAlertControllerStyleActionSheet];
            [op addAction:[UIAlertAction actionWithTitle:@"刷新" style:UIAlertActionStyleDefault handler:^(UIAlertAction *y) {
                [self fetchSubscription:u silent:NO];
            }]];
            [op addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *y) {
                NSString *sourceKey = [self stableURLKey:u];
                [self.subscriptionURLs removeObject:sourceKey ?: u];
                NSString *deletedKey = sourceKey ?: u;
                self.subscriptionRequestVersions[deletedKey] = @([self.subscriptionRequestVersions[deletedKey] unsignedIntegerValue] + 1);
                [self removeSubscriptionSource:deletedKey];
                [[NSUserDefaults standardUserDefaults] setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
                [self log:@"已删除订阅 %@", u];
            }]];
            [op addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:op animated:YES completion:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 内置插件

- (void)openPluginPage {
    PluginViewController *page = [PluginViewController new];
    self.pluginPage = page;
    __weak typeof(self) weakSelf = self;
    page.onStart = ^{ [weakSelf startBuiltinPlugin]; };
    page.onStop = ^{ [weakSelf stopBuiltinPlugin]; };
    page.onAddSubscription = ^{ [weakSelf addSubscription]; };
    page.onManageSubscriptions = ^{ [weakSelf manageSubscriptions]; };
    page.onOpenLog = ^{
        [weakSelf.navigationController popViewControllerAnimated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ if (!weakSelf.logVisible) [weakSelf toggleLog]; });
    };
    [page updateRunning:PyHost.running subscriptionCount:self.subscriptionURLs.count];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)openSettingsPage {
    SettingsViewController *page=[SettingsViewController new]; [self.navigationController pushViewController:page animated:YES];
}

- (void)presentSubscriptionActions:(NSDictionary *)channel sourceView:(UIView *)source {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:channel[@"name"]?:@"订阅频道" message:channel[@"remoteURL"] preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"从列表移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ NSMutableArray *m=[self.allChannels mutableCopy]; [m removeObject:channel]; self.allChannels=m; [self applyFilter]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView=source; a.popoverPresentationController.sourceRect=source.bounds; [self presentViewController:a animated:YES completion:nil];
}

- (void)stopBuiltinPlugin {
    NSError *error = nil;
    BOOL stopped = [PyHost stopWithError:&error];
    [self log:@"内置插件停止 %@ %@", stopped ? @"成功" : @"失败", error.localizedDescription ?: @""];
    [self.pluginPage updateRunning:PyHost.running subscriptionCount:self.subscriptionURLs.count];
}

- (void)startBuiltinPlugin {
    [PyHost setLogHandler:^(NSString *line) {
        if (!line.length) return;
        [self log:@"[py] %@", line];
    }];
    NSString *dataDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ysp"];
    NSError *err = nil;
    BOOL ok = [PyHost startWithScript:@"ysp-live.py" port:8767 dataDir:dataDir error:&err];
    [self log:@"内置插件启动 %@ %@", ok ? @"成功" : @"失败", err.localizedDescription ?: @""];
    [self.pluginPage updateRunning:PyHost.running subscriptionCount:self.subscriptionURLs.count];
    if (!ok) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%ld/all.m3u", (long)PyHost.port];
        NSString *key = [self stableURLKey:u];
        if (!key.length) return;
        [self.subscriptionURLs addObject:key];
        [[NSUserDefaults standardUserDefaults] setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
        [self.pluginPage updateRunning:PyHost.running subscriptionCount:self.subscriptionURLs.count];
        [self fetchSubscription:key silent:NO];
    });
}

#pragma mark - 手势 / 锁屏

- (UISlider *)systemVolumeSlider {
    for (UIView *v in self.volumeView.subviews) {
        if ([v isKindOfClass:UISlider.class]) return (UISlider *)v;
    }
    return nil;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.playerBox];
    CGFloat dy = [g translationInView:self.playerBox].y;
    BOOL rightSide = p.x > self.playerBox.bounds.size.width / 2;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.infoLabel.hidden = NO;
        self.controlBar.hidden = NO;
    }
    CGFloat delta = -dy / 220.0;   // 上滑增大
    if (rightSide) {
        UISlider *slider = [self systemVolumeSlider];
        if (slider) {
            float v = MIN(1.0, MAX(0.0, slider.value + delta * 0.35));
            [slider setValue:v animated:NO];
            [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
            self.titleLabel.text = [NSString stringWithFormat:@"音量 %d%%", (int)(v * 100)];
        }
    } else {
        CGFloat b = MIN(1.0, MAX(0.0, UIScreen.mainScreen.brightness + delta * 0.5));
        UIScreen.mainScreen.brightness = b;
        self.titleLabel.text = [NSString stringWithFormat:@"亮度 %d%%", (int)(b * 100)];
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [g setTranslation:CGPointZero inView:self.playerBox];
        self.titleLabel.text = self.channelName;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (![self.titleLabel.text isEqualToString:self.channelName]) return;
            self.controlBar.hidden = NO;
        });
    }
}

- (void)setupRemoteCommands {
    MPRemoteCommandCenter *c = MPRemoteCommandCenter.sharedCommandCenter;
    [c.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [self togglePlayPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        [self togglePlayPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)updateNowPlaying {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = self.channelName ?: @"CCTVHost";
    info[MPMediaItemPropertyArtist] = @"CCTVHost";
    if (self.avPlayer.currentItem) {
        CMTime d = self.avPlayer.currentItem.duration;
        if (CMTIME_IS_NUMERIC(d)) info[MPMediaItemPropertyPlaybackDuration] = @(CMTimeGetSeconds(d));
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

#pragma mark - EPG 缓存

- (NSString *)epgCachePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@"epg-cache.json"];
}

- (void)loadEPGCache {
    NSData *data = [NSData dataWithContentsOfFile:[self epgCachePath]];
    if (!data) return;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return;
    double now = NSDate.date.timeIntervalSince1970;
    [(NSDictionary *)json enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if (![obj isKindOfClass:NSDictionary.class]) return;
        double ts = [obj[@"ts"] doubleValue];
        if (ts > 0 && ts <= now && now - ts < 6 * 3600 &&
            [obj[@"now"] isKindOfClass:NSString.class]) self.epgCache[key] = obj;
    }];
    [self log:@"EPG 缓存载入 %lu 条", (unsigned long)self.epgCache.count];
}

- (void)saveEPGCache {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.epgCache options:0 error:NULL];
    [data writeToFile:[self epgCachePath] atomically:YES];
}

- (NSIndexPath *)indexPathForChannelID:(NSString *)cid {
    NSUInteger row = [self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *o, NSUInteger i, BOOL *stop) {
        return [o[@"id"] isEqualToString:cid ?: @""];
    }];
    if (row == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:(NSInteger)(row / 2) inSection:([self numberOfSectionsInTableView:self.table] == 2 ? 1 : 0)];
}

#pragma mark - 台标

static NSCache *LogoCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 200; });
    return cache;
}

- (void)loadLogo:(NSString *)url into:(UIImageView *)iv {
    iv.image = nil;
    iv.accessibilityIdentifier = url;
    if (!url.length) return;
    UIImage *cached = [LogoCache() objectForKey:url];
    if (cached) { iv.image = cached; return; }
    __weak UIImageView *weakIV = iv;
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data.length) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        [LogoCache() setObject:img forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakIV && [weakIV.accessibilityIdentifier isEqualToString:url]) weakIV.image = img;
        });
    }] resume];
}

#pragma mark - 搜索 / 最近 / 节目单缓存

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.query = sc.searchBar.text;
    [self applyFilter];
}

- (void)applyFilter {
    NSArray *base = self.allChannels;
    if (self.favoritesOnly) {
        NSSet *ids=[NSSet setWithArray:self.favorites ?: @[]];
        base=[base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b){ return [ids containsObject:o[@"id"] ?: @""]; }]];
    }
    NSInteger idx = self.groupControl.selectedSegmentIndex;
    NSArray *groups = @[@"全部", @"央视", @"卫视", @"地方", @"教育", @"熊猫", @"订阅"];
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
    NSMutableArray *sorted = [base mutableCopy];
    [sorted sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL fa = [self.favorites containsObject:a[@"id"] ?: @""];
        BOOL fb = [self.favorites containsObject:b[@"id"] ?: @""];
        if (fa != fb) return fa ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    self.shownChannels = sorted;
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
                weakSelf.epgCache[cid] = @{@"now": cur ?: @"", @"next": nxt ?: @"", @"ts": @(now)};
                [weakSelf saveEPGCache];
                NSIndexPath *path = [weakSelf indexPathForChannelID:cid];
                if (path) [weakSelf.table reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
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
        NSString *key = [self stableURLKey:u];
        if (!key.length) return;
        [self.subscriptionURLs addObject:key];
        [[NSUserDefaults standardUserDefaults] setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
        [self fetchSubscription:key silent:NO];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)stableURLKey:(NSString *)urlString {
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    if (!components.URL || !components.scheme.length || !components.host.length) return nil;
    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;
    components.fragment = nil;
    if (([components.scheme isEqualToString:@"http"] && components.port.integerValue == 80) ||
        ([components.scheme isEqualToString:@"https"] && components.port.integerValue == 443)) components.port = nil;
    return components.URL.absoluteString;
}

- (void)removeSubscriptionSource:(NSString *)sourceKey {
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *channel in self.allChannels ?: @[]) {
        NSMutableSet *sources = [NSMutableSet setWithArray:channel[@"subscriptionSources"] ?: @[]];
        if ([sources containsObject:sourceKey]) {
            [sources removeObject:sourceKey];
            if (!sources.count) continue;
            NSMutableDictionary *copy = [channel mutableCopy];
            copy[@"subscriptionSources"] = sources.allObjects;
            [kept addObject:copy];
        } else {
            [kept addObject:channel];
        }
    }
    self.allChannels = kept;
    self.shownChannels = kept;
    [self applyFilter];
}

- (void)fetchSubscription:(NSString *)urlString silent:(BOOL)silent {
    NSString *sourceKey = [self stableURLKey:urlString];
    if (!sourceKey.length) return;
    NSUInteger requestVersion = [self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] + 1;
    self.subscriptionRequestVersions[sourceKey] = @(requestVersion);
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
            if ([weakSelf.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] != requestVersion) return;
            if (!list.count) {
                [weakSelf log:@"订阅失败 %@ %@", urlString, err.localizedDescription ?: @"无有效条目"];
                return;
            }
            NSMutableArray *merged = [NSMutableArray array];
            for (NSDictionary *existing in weakSelf.allChannels ?: @[]) {
                NSMutableSet *owners = [NSMutableSet setWithArray:existing[@"subscriptionSources"] ?: @[]];
                if ([owners containsObject:sourceKey]) {
                    [owners removeObject:sourceKey];
                    if (!owners.count) continue;
                    NSMutableDictionary *copy = [existing mutableCopy];
                    copy[@"subscriptionSources"] = owners.allObjects;
                    [merged addObject:copy];
                } else {
                    [merged addObject:existing];
                }
            }
            NSMutableDictionary<NSString *, NSNumber *> *urlIndexes = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < merged.count; i++) {
                NSString *stable = [weakSelf stableURLKey:merged[i][@"remoteURL"]];
                if (stable.length) urlIndexes[stable] = @(i);
            }
            NSUInteger added = 0;
            for (M3UChannel *c in list) {
                if (!c.name.length || !c.url.length) continue;
                NSString *stable = [weakSelf stableURLKey:c.url];
                if (!stable.length) continue;
                NSMutableArray *alts = weakSelf.altSources[c.name];
                if (!alts) { alts = [NSMutableArray array]; weakSelf.altSources[c.name] = alts; }
                if (![alts containsObject:c.url]) [alts addObject:c.url];
                NSNumber *existingIndex = urlIndexes[stable];
                if (existingIndex) {
                    NSMutableDictionary *entry = [merged[existingIndex.unsignedIntegerValue] mutableCopy];
                    NSMutableSet *owners = [NSMutableSet setWithArray:entry[@"subscriptionSources"] ?: @[]];
                    [owners addObject:sourceKey];
                    entry[@"subscriptionSources"] = owners.allObjects;
                    entry[@"name"] = c.name;
                    entry[@"group"] = c.group ?: @"订阅";
                    if (c.logo.length) entry[@"logo"] = c.logo; else [entry removeObjectForKey:@"logo"];
                    entry[@"remoteURL"] = c.url;
                    merged[existingIndex.unsignedIntegerValue] = entry;
                } else {
                    NSMutableDictionary *entry = [@{@"id": stable,
                                                    @"name": c.name,
                                                    @"group": c.group ?: @"订阅",
                                                    @"verified": @NO,
                                                    @"remoteURL": c.url,
                                                    @"subscriptionSources": @[sourceKey]} mutableCopy];
                    if (c.logo.length) entry[@"logo"] = c.logo;
                    urlIndexes[stable] = @(merged.count);
                    [merged addObject:entry];
                    added++;
                }
            }
            weakSelf.allChannels = merged;
            weakSelf.shownChannels = merged;
            [weakSelf.table reloadData];
            [weakSelf log:@"订阅 %@ 新增 %lu 个频道（共 %lu）", urlString, (unsigned long)added, (unsigned long)list.count];
        });
    }] resume];
}

- (void)playRemote:(NSDictionary *)ch {
    self.playbackGeneration += 1;
    NSString *u = ch[@"remoteURL"];
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return;
    self.currentRemoteURL = u;
    [self stopPlayback];
    self.channelID = ch[@"id"];
    self.channelName = ch[@"name"];
    self.routeName = @"订阅";
    self.firstRender = NO;
    self.playStartedAt = NSDate.date.timeIntervalSince1970;
    self.firstFrameSeconds = 0;
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
    [self tryAlternateSource];
}

- (void)tryAlternateSource {
    NSString *name = self.channelName;
    NSMutableArray *alts = self.altSources[name];
    if (alts.count < 2) return;
    NSString *current = self.channelID;
    for (NSString *u in alts) {
        if ([u isEqualToString:current]) continue;
        [self log:@"换源重试 %@", u];
        [self playRemote:@{@"id": u, @"name": name ?: u, @"group": @"订阅", @"remoteURL": u}];
        return;
    }
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)ch context:(void *)ctx {
    if ([kp isEqualToString:@"status"]) {
        AVPlayerItem *item = obj;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            self.firstRender = YES;
            [self.spinner stopAnimating];
            self.firstFrameSeconds = NSDate.date.timeIntervalSince1970 - self.playStartedAt;
            self.titleLabel.text = self.channelName;
            [self.infoLabel setText:[NSString stringWithFormat:@"首帧 %.1fs · 版本 %@", self.firstFrameSeconds, kBuildTag]];
            [self updateNowPlaying];
            [self log:@"订阅就绪 %.2fs", self.firstFrameSeconds];
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
    NSDictionary *cached = self.epgCache[cid];
    if (cached && [cached[@"ts"] doubleValue] <= NSDate.date.timeIntervalSince1970 &&
        NSDate.date.timeIntervalSince1970 - [cached[@"ts"] doubleValue] < 6 * 3600) {
        NSMutableArray *cachedParts = [NSMutableArray array];
        if ([cached[@"now"] length]) [cachedParts addObject:[NSString stringWithFormat:@"正在播：%@", cached[@"now"]]];
        if ([cached[@"next"] length]) [cachedParts addObject:[NSString stringWithFormat:@"接下来：%@", cached[@"next"]]];
        if (cachedParts.count) self.infoLabel.text = [cachedParts componentsJoinedByString:@"  "];
    }
    NSUInteger epgGeneration = self.playbackGeneration;
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
            if (![weakSelf.epgChannel isEqualToString:cid] || epgGeneration != weakSelf.playbackGeneration ||
                ![weakSelf.channelID isEqualToString:cid]) return;
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
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player loadStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    [self attachVideoView];
    if (state == 4) {                     // PrepareDone
        [self log:@"PrepareDone → play"];
        [self call:self.currentPlayer sel:@"play"];
    } else if (state == 13) {
        [self log:@"加载取消"];
    }
}

- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player vdnRequestStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    if (state == 3) [self log:@"VDN 成功"];
    else if (state == 2) [self log:@"VDN 失败"];
}

- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player statEvent:event value:value]; }); return; }
    if (player != self.currentPlayer) return;
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
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player playBackStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    if (state == 1) [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    if (state == 2) [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal];
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player playbackFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"播放失败 %ld %@", (long)error.code, error.localizedDescription];
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · 播放失败", self.channelName];
    [self.spinner stopAnimating];
    if (error.code >= 4000 && error.code < 5000) {
        [self log:@"参数/调度错误不自动重试，请查看错误详情"];
        return;
    }
    if (self.retryCount < 2) {
        self.retryCount += 1;
        double delay = self.retryCount == 1 ? 1.0 : 3.0;
        [self log:@"断流重连 第 %ld 次（%.0fs 后）", (long)self.retryCount, delay];
        NSUInteger generation = self.playbackGeneration;
        NSString *cid = self.channelID;
        NSString *name = self.channelName;
        BOOL remotePlayback = self.avPlayer != nil;
        NSString *remoteURL = remotePlayback ? self.currentRemoteURL : nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.playbackGeneration || player != self.currentPlayer || ![cid isEqualToString:self.channelID]) return;
            if (remotePlayback) {
                if (remoteURL.length) [self playRemote:@{@"id": cid, @"name": name ?: cid, @"remoteURL": remoteURL}];
            } else {
                [self playViaSDK:cid title:name];
            }
        });
    }
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player vdnRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"VDN 请求失败 %ld", (long)error.code];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player parameterError:error rate:rate]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"参数错误 %ld", (long)error.code];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self player:player publicRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"版权请求失败 %ld", (long)error.code];
}

- (void)authFailed:(NSError *)error {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self authFailed:error]; }); return; }
    [self log:@"鉴权失败 %ld", (long)error.code];
    self.titleLabel.text = @"鉴权失败";
}

@end
