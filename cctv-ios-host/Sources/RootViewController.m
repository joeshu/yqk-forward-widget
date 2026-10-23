#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import "EPGViewController.h"
#import "M3UParser.h"
#import "PyHost.h"
#import "PluginViewController.h"
#import "SettingsViewController.h"
#import "ServicesViewController.h"
#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "ProfileStore.h"
#import "XMLTVStore.h"
#import "ServiceStore.h"
#import "HostBackup.h"
#import "LocalServiceReadiness.h"
#import "PlaybackStartupTrace.h"
#import "PlaybackInfoViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static NSString *const kBuildTag = @"0.17.0";
static void *const kAVItemStatusContext = (void *)&kAVItemStatusContext;
static void *const kAVLayerFrameContext = (void *)&kAVLayerFrameContext;
// 这两个键名来自 CNPlayerSDK 导出常量（值即常量名本身），SDK 缺 Title 会直接拒播并报错误码 4012
static NSString *const kOptTitle = @"CNPlayerConfigOptionKey_Title";
static NSString *const kOptDefaultRate = @"CNPlayerConfigOptionKey_DefaultRate";
static NSString *const kLicenseUrl = @"https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense";
static BOOL CCTVBoolPreference(NSString *key, BOOL fallback) {
    id value=[[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ? [value boolValue] : fallback;
}

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate>
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
@property (nonatomic, assign) BOOL sdkPlayerUsed;
@property (nonatomic, strong) dispatch_queue_t epgDiskQueue;
@property (nonatomic, assign) BOOL epgWriteScheduled;
@property (nonatomic, strong) NSMutableDictionary<NSString *,NSURLSessionDataTask *> *epgListTasks;
@property (nonatomic, assign) NSUInteger epgListGeneration;
@property (nonatomic, strong) PlaybackStartupTrace *startupTrace;
@property (nonatomic, strong) LocalServiceReadiness *playbackReadiness;
@property (nonatomic, strong) NSMutableDictionary<NSString *,LocalServiceReadiness *> *subscriptionReadiness;
@property (nonatomic, strong) NSMutableDictionary<NSString *,NSNumber *> *readyLocalOrigins;
@property (nonatomic, strong) NSMutableSet<NSString *> *deferredLocalSubscriptions;
@property (nonatomic, strong) id initialCDNPreference;
@property (nonatomic, assign) BOOL customCDNPreference;
@property (nonatomic, assign) BOOL avLayerObserved;
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
@property (nonatomic, strong) UICollectionView *channelGrid;
@property (nonatomic, strong) UISegmentedControl *playerTabs;
@property (nonatomic, strong) UIViewController *playbackPanel;
@property (nonatomic, strong) UIViewController *tabPage;
@property (nonatomic, assign) BOOL gridMode;
@property (nonatomic, assign) BOOL playerExpanded;
@property (nonatomic, copy) NSString *activeSource;
@property (nonatomic, strong) UISegmentedControl *groupControl;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *allChannels;
@property (nonatomic, strong) NSArray<NSDictionary *> *shownChannels;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, assign) BOOL cicadaPending;
@property (nonatomic, strong) NSTimer *cicadaFallbackTimer;
// 日志
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, copy) NSString *diagnosticLogPath;
@property (nonatomic, strong) dispatch_queue_t diagnosticLogQueue;
@property (nonatomic, strong) NSMutableString *pendingLogWrites;
@property (nonatomic, strong) NSTimer *logFlushTimer;
@property (nonatomic, assign) NSUInteger diagnosticLogGeneration;
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
@property (nonatomic, assign) BOOL subscriptionCatalog;
@property (nonatomic, assign) BOOL favoritesOnly;
@property (nonatomic, strong) UIButton *pipBtn;
@property (nonatomic, strong) UIButton *moreBtn;
@property (nonatomic, copy) NSString *epgChannel;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSURLSessionDataTask *> *subscriptionTasks;
@property(nonatomic,strong) NSMutableArray<NSURLSessionDataTask *> *logoTasks;
@property(nonatomic,strong) NSMutableDictionary *catalogStates;
@property(nonatomic,strong) AVPlayer *previewPlayer;
@property(nonatomic,strong) AVPlayerLayer *previewLayer;
@property(nonatomic,strong) UIView *previewBox;
@property(nonatomic,strong) NSTimer *previewTimer;
@property(nonatomic,assign) BOOL importingPlaylist;
@property(nonatomic,assign) NSUInteger selectionVersion;
@property(nonatomic,assign) NSUInteger playbackIntentVersion;
@property(nonatomic,assign) NSUInteger subscriptionParseGeneration;
@end

@implementation RootViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1];
    self.title = @"CCTV";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    HostStyleNavigation(self.navigationController);
    self.view.tintColor=HostAccent();
    self.gridMode = [[NSUserDefaults standardUserDefaults] objectForKey:@"channelGridMode"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"channelGridMode"] : YES;
    self.logBuffer = [NSMutableString string];
    self.diagnosticLogQueue = dispatch_queue_create("com.cctvhost.diagnostic-log", DISPATCH_QUEUE_SERIAL);
    self.pendingLogWrites = [NSMutableString string];
    self.logFlushTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(flushDiagnosticLog) userInfo:nil repeats:YES];
    NSString *supportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    self.diagnosticLogPath = [[supportDir stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"cctvhost.log"];
    [self restoreDiagnosticLog];
    self.retryCount = 0;

    self.epgDiskQueue=dispatch_queue_create("com.cctvhost.epg-disk",DISPATCH_QUEUE_SERIAL);
    self.epgListTasks=[NSMutableDictionary dictionary];
    self.subscriptionReadiness=[NSMutableDictionary dictionary];
    self.readyLocalOrigins=[NSMutableDictionary dictionary];
    self.deferredLocalSubscriptions=[NSMutableSet set];
    self.subscriptionTasks=[NSMutableDictionary dictionary];self.logoTasks=[NSMutableArray array];self.catalogStates=[NSMutableDictionary dictionary];
    [self loadChannels];
    [self buildPlayer];
    [self buildList];
    [self configureCatalogNavigation];
    [self activateAudioSession];
    [self setupRemoteCommands];
    [self registerCallbackProtocol];
    [self setupSDK];
    [self log:@"日志持久化已启用（每秒批量保存）"];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.playbackReadiness cancel];
    for(LocalServiceReadiness *probe in self.subscriptionReadiness.allValues)[probe cancel];
    [self.watchdog invalidate];
    [self.epgTimer invalidate];
    [self.epgTask cancel];
    [self.logFlushTimer invalidate];
    [self flushDiagnosticLog];
}

- (void)onBackground {
    [self stopPreview];
    [self call:self.currentPlayer sel:@"resignActive"];
    if (CCTVBoolPreference(@"autoPiP",NO) && self.avLayer && AVPictureInPictureController.isPictureInPictureSupported && !self.pip.isPictureInPictureActive) {
        self.pip=[[AVPictureInPictureController alloc] initWithPlayerLayer:self.avLayer];
        [self.pip startPictureInPicture];
        [self log:@"后台自动进入画中画"];
    }
    [self log:@"进入后台"];
}

- (void)onForeground {
    [self call:self.currentPlayer sel:@"becomeActive"];
    [self log:@"回到前台"];
}

#pragma mark - 日志

- (void)restoreDiagnosticLog {
    NSError *error=nil;
    NSString *text=[NSString stringWithContentsOfFile:self.diagnosticLogPath encoding:NSUTF8StringEncoding error:&error];
    if (text.length) {
        [self.logBuffer appendString:@"—— 上次运行日志（崩溃/强制退出前）——\n"];
        [self.logBuffer appendString:text];
        if (![text hasSuffix:@"\n"]) [self.logBuffer appendString:@"\n"];
        [self.logBuffer appendString:@"—— 本次启动 ——\n"];
        NSLog(@"[CCTVHost] 已恢复上次运行日志，%lu 字符",(unsigned long)text.length);
    }
}
- (void)persistDiagnosticLine:(NSString *)line {
    @synchronized (self.pendingLogWrites) {
        [self.pendingLogWrites appendString:line];
    }
}
- (void)flushDiagnosticLog {
    __block NSString *batch=nil;
    __block NSUInteger generation=0;
    @synchronized (self.pendingLogWrites) {
        if (!self.pendingLogWrites.length) return;
        batch=[self.pendingLogWrites copy];
        generation=self.diagnosticLogGeneration;
        [self.pendingLogWrites setString:@""];
    }
    if (!self.diagnosticLogPath.length) return;
    dispatch_async(self.diagnosticLogQueue, ^{
        @synchronized (self.pendingLogWrites) { if (generation != self.diagnosticLogGeneration) return; }
        NSFileManager *fm=[NSFileManager defaultManager];
        [fm createDirectoryAtPath:[self.diagnosticLogPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:self.diagnosticLogPath];
        if (!fh) { [batch writeToFile:self.diagnosticLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
        [fh seekToEndOfFile]; [fh writeData:[batch dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile];
        NSDictionary *a=[fm attributesOfItemAtPath:self.diagnosticLogPath error:nil];
        if ([a fileSize] > 512*1024) {
            NSData *d=[NSData dataWithContentsOfFile:self.diagnosticLogPath];
            if (d.length > 256*1024) {
                NSData *tail=[d subdataWithRange:NSMakeRange(d.length-256*1024,256*1024)];
                [tail writeToFile:self.diagnosticLogPath atomically:YES];
            }
        }
    });
}
- (void)log:(NSString *)format, ... {
    va_list ap; va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[[NSDate date] description],msg];
    NSLog(@"[CCTVHost] %@", msg);
    [self persistDiagnosticLine:line];
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
    self.moreBtn = [self barButton:@"更多" action:@selector(showMorePlaybackActions)];
    for (UIButton *b in @[self.playPauseBtn, self.muteBtn, self.routeBtn, self.epgBtn, self.moreBtn]) {
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
    if (self.firstRender) {
        self.titleLabel.hidden = YES;
        self.infoLabel.hidden = YES;
    } else {
        self.titleLabel.hidden = !self.titleLabel.hidden;
        self.infoLabel.hidden = !self.infoLabel.hidden;
    }
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
    self.playerTabs=[[UISegmentedControl alloc] initWithItems:@[@"频道",@"节目",@"信息"]];self.playerTabs.selectedSegmentIndex=0;self.playerTabs.selectedSegmentTintColor=HostAccent();[self.playerTabs addTarget:self action:@selector(selectPlayerPanel) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.playerTabs];

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

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;
    UILongPressGestureRecognizer *routePress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.table addGestureRecognizer:routePress];
    UICollectionViewFlowLayout *flow=[UICollectionViewFlowLayout new]; flow.minimumInteritemSpacing=8; flow.minimumLineSpacing=10; flow.sectionInset=UIEdgeInsetsMake(8,12,16,12);
    self.channelGrid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:flow]; self.channelGrid.backgroundColor=UIColor.blackColor; self.channelGrid.dataSource=self; self.channelGrid.delegate=self; self.channelGrid.accessibilityIdentifier=@"channel.grid";
    [self.channelGrid registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"channel.card"]; [self.view addSubview:self.channelGrid];
    UIRefreshControl *gridRefresh=[UIRefreshControl new];[gridRefresh addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];self.channelGrid.refreshControl=gridRefresh;
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
    self.logView.text = self.logBuffer ?: @"";
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:self.logView];
    self.logToolbar = [[UIToolbar alloc] init];
    self.logToolbar.barStyle = UIBarStyleBlack;
    self.logToolbar.items = @[
        [[UIBarButtonItem alloc] initWithTitle:@"关闭日志" style:UIBarButtonItemStyleDone target:self action:@selector(toggleLog)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain target:self action:@selector(copyDiagnosticLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"导出" style:UIBarButtonItemStylePlain target:self action:@selector(exportDiagnosticLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearDiagnosticLog)]
    ];
    self.logToolbar.hidden = YES;
    [self.view addSubview:self.logToolbar];
}

- (void)copyDiagnosticLog {
    UIPasteboard.generalPasteboard.string = self.logBuffer ?: @"";
}

- (void)exportDiagnosticLog {
    [self flushDiagnosticLog];
    dispatch_async(self.diagnosticLogQueue, ^{
        NSURL *source=[NSURL fileURLWithPath:self.diagnosticLogPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![NSFileManager.defaultManager fileExistsAtPath:source.path]) { [self log:@"日志文件尚未生成"]; return; }
            UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[source] applicationActivities:nil];
            UIPopoverPresentationController *pop=share.popoverPresentationController;
            if(pop){ pop.barButtonItem=self.navigationItem.rightBarButtonItem; }
            [self presentViewController:share animated:YES completion:nil];
        });
    });
}
- (void)clearDiagnosticLog {
    [self.logBuffer setString:@""];
    @synchronized (self.pendingLogWrites) { self.diagnosticLogGeneration++; [self.pendingLogWrites setString:@""]; }
    dispatch_async(self.diagnosticLogQueue, ^{ [@"" writeToFile:self.diagnosticLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; });
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
        NSString *key=[ProfileStore isHTTP:u]?[self stableURLKey:u]:([ProfileStore isSource:u]?u:nil);
        if(!key.length)continue;[self.subscriptionURLs addObject:key];
        NSArray *cache=[ProfileStore metadata:key][@"cachedChannels"];
        if([cache isKindOfClass:NSArray.class])self.allChannels=[self.allChannels arrayByAddingObjectsFromArray:cache];
        [self.deferredLocalSubscriptions addObject:key];
    }
    self.shownChannels=self.allChannels;
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
    self.favoritesOnly=NO;
    if(self.activeTab==2)self.activeTab=self.subscriptionCatalog?1:0;
    for(UIButton *b in self.bottomBar.arrangedSubviews) { UIButtonConfiguration *cfg=b.configuration; cfg.baseForegroundColor=b.tag==self.activeTab?UIColor.systemPinkColor:UIColor.whiteColor; b.configuration=cfg; }
    [self configureCatalogNavigation];[self applyFilter];
}

- (void)buildBottomBar {
    self.bottomBar=[[UIStackView alloc] init]; self.bottomBar.axis=UILayoutConstraintAxisHorizontal; self.bottomBar.distribution=UIStackViewDistributionFillEqually; self.bottomBar.spacing=4; self.bottomBar.backgroundColor=[UIColor colorWithWhite:0.13 alpha:0.98]; self.bottomBar.layer.cornerRadius=24; self.bottomBar.clipsToBounds=YES;
    NSArray *titles=@[@"CCTV",@"频道",@"收藏",@"配置",@"设置"];
    NSArray *icons=@[@"tv.fill",@"play.rectangle.on.rectangle",@"heart.fill",@"externaldrive.fill",@"gearshape"];
    for (NSInteger i=0;i<titles.count;i++) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=i;
        UIButtonConfiguration *cfg=[UIButtonConfiguration plainButtonConfiguration]; cfg.title=titles[i]; cfg.image=[UIImage systemImageNamed:icons[i]]; cfg.imagePlacement=NSDirectionalRectEdgeTop; cfg.imagePadding=3; cfg.baseForegroundColor=(i==0?UIColor.systemPinkColor:UIColor.whiteColor); b.configuration=cfg;
        b.titleLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]; b.accessibilityLabel=titles[i];
        [b addTarget:self action:@selector(selectBottomTab:) forControlEvents:UIControlEventTouchUpInside]; [self.bottomBar addArrangedSubview:b];
    }
    [self.view addSubview:self.bottomBar];
}

- (void)selectBottomTab:(UIButton *)sender {
    [self stopPreview];
    if(self.activeTab<3)self.catalogStates[@(self.activeTab)]=@{@"query":self.query?:@"",@"group":@(self.groupControl.selectedSegmentIndex),@"gridY":@(self.channelGrid.contentOffset.y),@"listY":@(self.table.contentOffset.y)};
    self.activeTab=sender.tag;
    for (UIButton *b in self.bottomBar.arrangedSubviews) { UIButtonConfiguration *cfg=b.configuration; cfg.baseForegroundColor=b.tag==sender.tag?HostAccent():UIColor.whiteColor; b.configuration=cfg; }
    if(self.tabPage){[self.tabPage willMoveToParentViewController:nil];[self.tabPage.view removeFromSuperview];[self.tabPage removeFromParentViewController];self.tabPage=nil;}
    if(sender.tag==3){ [self openConfigurationTab]; }
    else if(sender.tag==4){ SettingsViewController *page=[self makeSettingsPage]; [self showTabPage:page title:@"设置"]; }
    else {self.favoritesOnly=sender.tag==2;if(sender.tag<2)self.subscriptionCatalog=sender.tag==1;self.activeSource=nil;self.playerTabs.selectedSegmentIndex=0;[self selectPlayerPanel];NSDictionary *state=self.catalogStates[@(sender.tag)];self.query=state[@"query"]?:@"";self.searchController.searchBar.text=self.query;self.groupControl.selectedSegmentIndex=[state[@"group"] integerValue];[self configureCatalogNavigation];[self applyFilter];[self.view layoutIfNeeded];self.channelGrid.contentOffset=CGPointMake(0,[state[@"gridY"] doubleValue]);self.table.contentOffset=CGPointMake(0,[state[@"listY"] doubleValue]);
        if(sender.tag==1&&!self.channelID.length)[self refreshSubscriptionsWhenIdle];}
    [self.view setNeedsLayout];
}

- (void)configureCatalogNavigation {
    self.title=self.favoritesOnly?@"收藏频道":(self.subscriptionCatalog?@"频道":@"CCTV");
    self.navigationItem.largeTitleDisplayMode=(self.playerExpanded&&(self.favoritesOnly||self.subscriptionCatalog==([self.currentRemoteURL length]>0)))?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.searchController=self.searchController; self.navigationItem.hidesSearchBarWhenScrolling=NO;
    __weak typeof(self) w=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"square.grid.2x2",@"title":@"列表与网格",@"action":[UIAction actionWithHandler:^(UIAction *a){w.gridMode=!w.gridMode;[NSUserDefaults.standardUserDefaults setBool:w.gridMode forKey:@"channelGridMode"];[w.view setNeedsLayout];}]},
        @{@"icon":@"arrow.clockwise",@"title":@"刷新当前页面",@"action":[UIAction actionWithHandler:^(UIAction *a){[w onPullRefresh];}]},
        @{@"icon":@"ellipsis",@"title":@"更多",@"menu":[self catalogMenu]}
    ])];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"全部频道" style:UIBarButtonItemStylePlain target:self action:@selector(showGroupMenu)];
}
- (UIMenu *)catalogMenu {
    __weak typeof(self) w=self;
    UIAction *grid=[UIAction actionWithTitle:self.gridMode?@"切换列表样式":@"切换网格样式" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction *a){w.gridMode=!w.gridMode;[NSUserDefaults.standardUserDefaults setBool:w.gridMode forKey:@"channelGridMode"];[w configureCatalogNavigation];[w.view setNeedsLayout];}];
    UIAction *refresh=[UIAction actionWithTitle:@"刷新播放列表" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){[w onPullRefresh];}];
    UIAction *add=[UIAction actionWithTitle:@"添加订阅" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *a){[w addSubscription];}];
    UIAction *hide=[UIAction actionWithTitle:self.playerExpanded?@"收起播放器":@"展开播放器" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){w.playerExpanded=!w.playerExpanded;[w configureCatalogNavigation];[w.view setNeedsLayout];}];
    UIAction *history=[UIAction actionWithTitle:@"最近观看" image:[UIImage systemImageNamed:@"clock"] identifier:nil handler:^(UIAction *a){[w showHistory];}];
    UIAction *manage=[UIAction actionWithTitle:@"整理收藏" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){[w showFavoriteManager];}];
    return [UIMenu menuWithTitle:@"" children:self.subscriptionCatalog?@[grid,refresh,add,hide,history,manage]:@[grid,hide,history,manage]];
}
- (void)showGroupMenu {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"频道分组" message:nil preferredStyle:UIAlertControllerStyleActionSheet];NSArray *groups=@[@"全部",@"央视",@"卫视",@"地方",@"教育",@"熊猫",@"订阅"];
    for(NSUInteger i=0;i<groups.count;i++){[a addAction:[UIAlertAction actionWithTitle:groups[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.groupControl.selectedSegmentIndex=i;[self onGroupChanged];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.barButtonItem=self.navigationItem.leftBarButtonItem;[self presentViewController:a animated:YES completion:nil];
}
- (void)showTabPage:(UIViewController *)page title:(NSString *)title {
    self.tabPage=page;[self addChildViewController:page];[self.view addSubview:page.view];[page didMoveToParentViewController:self];self.title=title;self.navigationItem.searchController=page.navigationItem.searchController;self.navigationItem.leftBarButtonItem=nil;
    self.navigationItem.rightBarButtonItems=page.navigationItem.rightBarButtonItems;[self.view bringSubviewToFront:self.bottomBar];
}
- (void)openConfigurationTab {
    ConfigCenterViewController *page=[ConfigCenterViewController new];__weak typeof(self) w=self;
    page.profilesProvider=^{return [w configurationProfiles];};page.onServices=^{[w openServicesPage];};page.onAdd=^{[w addSubscription];};page.onRefresh=^{[w onPullRefresh];};
    page.onToggleProfile=^(NSString *source,BOOL enabled){if(!source.length)[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"nativeChannelsEnabled"];else{NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabled removeObject:source];if(!enabled)[disabled addObject:source];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}[w applyFilter];};
    page.onSelectProfile=^(NSString *source){UIButton *b=(UIButton *)w.bottomBar.arrangedSubviews[source.length?1:0];[w selectBottomTab:b];w.activeSource=source;w.title=source.length?@"订阅直播":@"央视直播";[w applyFilter];};
    page.onEditProfile=^(NSString *source){[w editProfile:source];};
    page.onDeleteProfile=^(NSString *source){[w deleteSubscription:source];};
    [self showTabPage:page title:@"配置中心"];
}
- (NSArray *)configurationProfiles {
    NSMutableArray *rows=[NSMutableArray array];NSUInteger native=0;for(NSDictionary *c in self.allChannels)if(![c[@"remoteURL"] length])native++;
    [rows addObject:@{@"name":@"央视直播 · 官方频道",@"source":@"",@"count":@(native),@"enabled":@(CCTVBoolPreference(@"nativeChannelsEnabled",YES))}];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    for(NSString *u in [ProfileStore orderedSources:self.subscriptionURLs.allObjects]){NSUInteger count=0;for(NSDictionary *c in self.allChannels)if([c[@"subscriptionSources"] containsObject:u])count++;[rows addObject:@{@"name":[ProfileStore metadata:u][@"name"]?:[NSURL URLWithString:u].host?:@"本地播放列表",@"status":[ProfileStore metadata:u][@"status"]?:@"等待刷新",@"source":u,@"count":@(count),@"enabled":@(![disabled containsObject:u])}];}return rows;
}
- (void)deleteSubscription:(NSString *)source {
    [self.subscriptionTasks[source] cancel];[self.subscriptionTasks removeObjectForKey:source];[ProfileStore remove:source];
    [self.subscriptionURLs removeObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.shownChannels.count;}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {CGFloat width=collectionView.bounds.size.width;NSInteger columns=width>700?4:2;return CGSizeMake(floor((width-24-(columns-1)*8)/columns),126);}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"channel.card" forIndexPath:ip];for(UIView *v in cell.contentView.subviews.copy)[v removeFromSuperview];NSDictionary *ch=self.shownChannels[ip.item];
    cell.contentView.backgroundColor=UIColor.blackColor;cell.contentView.layer.cornerRadius=9;cell.contentView.clipsToBounds=YES;
    UIView *poster=[[UIView alloc] initWithFrame:CGRectMake(0,0,cell.bounds.size.width,90)];poster.autoresizingMask=UIViewAutoresizingFlexibleWidth;poster.backgroundColor=HostCard();poster.layer.cornerRadius=8;[cell.contentView addSubview:poster];
    UIImageView *logo=[[UIImageView alloc] initWithFrame:CGRectMake(16,20,cell.bounds.size.width-32,48)];logo.autoresizingMask=UIViewAutoresizingFlexibleWidth;logo.contentMode=UIViewContentModeScaleAspectFit;[poster addSubview:logo];
    if([ch[@"logo"] length])[self loadLogo:ch[@"logo"] into:logo];else{UILabel *brand=[[UILabel alloc] initWithFrame:logo.frame];brand.text=ch[@"name"];brand.textAlignment=NSTextAlignmentCenter;brand.font=[UIFont italicSystemFontOfSize:19];brand.textColor=UIColor.whiteColor;brand.autoresizingMask=UIViewAutoresizingFlexibleWidth;[poster addSubview:brand];}
    UILabel *number=[[UILabel alloc] initWithFrame:CGRectMake(7,72,70,12)];number.font=[UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];number.textColor=UIColor.secondaryLabelColor;number.text=[NSString stringWithFormat:@"%03lu",(unsigned long)ip.item+1];[poster addSubview:number];
    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(2,94,cell.bounds.size.width-4,16)];title.autoresizingMask=UIViewAutoresizingFlexibleWidth;title.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];title.textColor=[ch[@"id"] isEqualToString:self.channelID]?HostAccent():UIColor.whiteColor;title.text=[NSString stringWithFormat:@"%@%@",[self.favorites containsObject:ch[@"id"]]?@"♥ ":@"",ch[@"name"]?:ch[@"id"]];[cell.contentView addSubview:title];
    UILabel *subtitle=[[UILabel alloc] initWithFrame:CGRectMake(2,111,cell.bounds.size.width-4,12)];subtitle.autoresizingMask=UIViewAutoresizingFlexibleWidth;subtitle.font=[UIFont systemFontOfSize:9];subtitle.textColor=UIColor.secondaryLabelColor;subtitle.text=self.epgCache[ch[@"id"]][@"now"]?:ch[@"group"];[cell.contentView addSubview:subtitle];return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip { [self selectChannel:self.shownChannels[ip.item]]; }
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSDictionary *ch=self.shownChannels[ip.item];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ch[@"id"] previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){BOOL favorite=[w.favorites containsObject:ch[@"id"]];UIAction *fav=[UIAction actionWithTitle:favorite?@"取消收藏":@"收藏频道" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){if(favorite)[w.favorites removeObject:ch[@"id"]];else[w.favorites addObject:ch[@"id"]];[NSUserDefaults.standardUserDefaults setObject:w.favorites forKey:@"favorites"];[w applyFilter];}];UIAction *route=[UIAction actionWithTitle:@"线路与节目单" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil handler:^(UIAction *a){if([ch[@"remoteURL"] length])[w openEPGforChannel:ch[@"id"] name:ch[@"name"]];else[w presentRouteSheetForChannel:ch fromIndexPath:nil];}];NSMutableArray *actions=[NSMutableArray arrayWithObjects:fav,route,nil];
        if([ch[@"remoteURL"] length]){[actions addObject:[UIAction actionWithTitle:@"静音预览（30 秒）" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){[w previewChannel:ch];}]];[actions addObject:[UIAction actionWithTitle:@"EPG 手动匹配" image:[UIImage systemImageNamed:@"calendar"] identifier:nil handler:^(UIAction *a){[w editEPGMapping:ch];}]];}
        return [UIMenu menuWithTitle:ch[@"name"] children:actions];}];
}
- (void)selectChannel:(NSDictionary *)ch {
    // Immediately invalidate pending work; rapid taps commit only the final selection.
    NSUInteger selection=++self.selectionVersion;self.playbackIntentVersion++;[self.playbackReadiness cancel];[self stopPreview];
    self.playerTabs.selectedSegmentIndex=0;[self selectPlayerPanel];self.playerExpanded=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(selection!=self.selectionVersion)return;
        [self rememberChannel:ch];if(CCTVBoolPreference(@"rememberLastChannel",YES))[NSUserDefaults.standardUserDefaults setObject:ch forKey:@"lastChannel"];
        [self routePlayback:ch];[self configureCatalogNavigation];[self.view setNeedsLayout];
    });
}
- (void)routePlayback:(NSDictionary *)ch {
    if([ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]]){NSMutableDictionary *remote=[ch mutableCopy];if(![remote[@"remoteURL"] length])remote[@"remoteURL"]=remote[@"id"];[self playRemote:remote];}
    else [self playChannel:ch route:nil];
}

- (NSArray *)visibleRecents {NSSet *ids=[NSSet setWithArray:[self.shownChannels valueForKey:@"id"]?:@[]];return [self.recents filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r,NSDictionary *b){return [ids containsObject:r[@"id"]];}]];}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    return [self visibleRecents].count && !self.favoritesOnly && !self.query.length && self.groupControl.selectedSegmentIndex == 0 ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if ([self numberOfSectionsInTableView:t] == 2) return s == 0 ? @"最近观看" : @"全部频道";
    return nil;
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if ([self numberOfSectionsInTableView:t] == 2 && s == 0) return (NSInteger)[self visibleRecents].count;
    return (NSInteger)self.shownChannels.count;
}

- (NSArray<NSDictionary *> *)channelsForSection:(NSInteger)section tableView:(UITableView *)t {
    if ([self numberOfSectionsInTableView:t] == 2 && section == 0) return [self visibleRecents];
    return self.shownChannels;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *reuse = @"channel.list";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
        cell.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1];
        cell.textLabel.font = [UIFont systemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        cell.selectedBackgroundView = selected;
    }
    NSArray<NSDictionary *> *rows = [self channelsForSection:ip.section tableView:t];
    if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return cell;
    NSDictionary *ch = rows[(NSUInteger)ip.row];
    NSString *cid = [ch[@"id"] isKindOfClass:NSString.class] ? ch[@"id"] : @"";
    BOOL playing = [cid isEqualToString:self.channelID];
    NSString *title = [ch[@"name"] isKindOfClass:NSString.class] ? ch[@"name"] : cid;
    if ([self.favorites containsObject:cid]) title = [@"★ " stringByAppendingString:title];
    cell.textLabel.text = playing ? [NSString stringWithFormat:@"● %@", title] : title;
    cell.textLabel.textColor = playing ? HostAccent() : UIColor.whiteColor;
    NSString *logo = [ch[@"logo"] isKindOfClass:NSString.class] ? ch[@"logo"] : @"";
    cell.imageView.image = nil;
    if (logo.length) [self loadLogo:logo into:cell.imageView];
    NSDictionary *epg = self.epgCache[cid];
    if ([epg[@"now"] isKindOfClass:NSString.class]) cell.detailTextLabel.text = [NSString stringWithFormat:@"正在播：%@", epg[@"now"]];
    else if ([ch[@"remoteURL"] length]) cell.detailTextLabel.text = @"订阅源";
    else {
        NSUInteger routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? [ch[@"routes"] count] : 0;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu 线路", ch[@"group"] ?: @"直播", (unsigned long)routes];
    }
    [self loadEPGForChannel:cid section:ip];
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];NSArray *rows=[self channelsForSection:ip.section tableView:t];if(ip.row>=rows.count)return;[self selectChannel:rows[ip.row]];
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSDictionary *ch = nil;
    NSIndexPath *ip = nil;
    UIView *source = g.view;
    if (g.view == self.table) {
        CGPoint point = [g locationInView:self.table];
        ip = [self.table indexPathForRowAtPoint:point];
        if (!ip) return;
        NSArray<NSDictionary *> *rows = [self channelsForSection:ip.section tableView:self.table];
        if (ip.row < 0 || ip.row >= (NSInteger)rows.count) return;
        ch = rows[(NSUInteger)ip.row];
        source = [self.table cellForRowAtIndexPath:ip] ?: self.table;
    } else {
        ch = objc_getAssociatedObject(g.view, @selector(onChannelCardTap:));
        if (!ch) return;
        ip = [self indexPathForChannelID:ch[@"id"]];
    }
    if ([ch[@"remoteURL"] length]) { [self presentSubscriptionActions:ch sourceView:source]; return; }
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
    if([ch[@"remoteURL"] length]){[self showRemoteTools:ch];return;}
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
    if (ip && self.table && !self.table.hidden) {
        sheet.popoverPresentationController.sourceView = self.table;
        sheet.popoverPresentationController.sourceRect = [self.table rectForRowAtIndexPath:ip];
    }
    if(!sheet.popoverPresentationController.sourceView&&!sheet.popoverPresentationController.barButtonItem){sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,self.view.bounds.size.height/2,1,1);}
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
    NSString *category=CCTVBoolPreference(@"allowBackgroundAudio",YES)?@"AVAudioSessionCategoryPlayback":@"AVAudioSessionCategoryAmbient";
    setCategory(session, NSSelectorFromString(@"setCategory:error:"), category, NULL);
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
    [self log:@"CCTVHost %@ · SDK %@ · 当前原生模式：%@ · Python %@",kBuildTag,ver,CCTVBoolPreference(@"legacyNativePlayback",YES)?@"兼容复用":@"独立实例",PyHost.running?@"运行中":@"未启动"];
    self.initialCDNPreference=[self callClass:cls sel:@"getVDNConfig_CDNLive_DefaultCDNInfo" args:@[]];
    [self callClass:cls sel:@"authed" args:@[]];

    // 续播：启动 2.5 秒后恢复上次频道
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!CCTVBoolPreference(@"resumeLastChannel",YES)) { [self log:@"已关闭启动续播"]; return; }
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
        if (inst) { weakSelf.sdkPlayer = inst; weakSelf.sdkPlayerUsed=NO; [weakSelf log:@"播放器实例已预热"]; }
    });
}

#pragma mark - 播放

- (void)playChannel:(NSDictionary *)ch route:(NSDictionary *)route {
    if([ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]]){[self routePlayback:ch];return;}
    [self beginPlaybackPriority];
    NSString *cid = ch[@"id"];
    if (!cid.length) return;
    if(self.activeTab!=0)[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[0]];
    self.playbackGeneration += 1;
    self.currentRemoteURL = nil;
    self.playerExpanded=YES;
    [self.view setNeedsLayout];
    self.channelID = cid;
    self.channelName = ch[@"name"] ?: cid;
    if(self.playerTabs.selectedSegmentIndex>0)[self selectPlayerPanel];
    self.routeName = route ? [NSString stringWithFormat:@"%@", [route[@"provider"] uppercaseString]] : @"自动";
    self.firstRender = NO;
    self.stallReported = NO;
    self.retryCount = 0;
    self.playStartedAt = CACurrentMediaTime();
    self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    self.firstFrameSeconds = 0;
    self.titleLabel.text = [NSString stringWithFormat:@"%@ · 连接中", self.channelName];
    self.titleLabel.hidden = NO;
    self.infoLabel.hidden = NO;
    self.infoLabel.text = @"";
    [self.spinner startAnimating];
    [self.table reloadData];
    [self.channelGrid reloadData];
    [self log:@"起播 %@ (%@) 线路=%@ · Python %@ · variant %@",self.channelName,cid,self.routeName,PyHost.running?@"running":@"idle",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"]?:@"full"];

    [self stopPlayback];
    [self recordStartupStage:@"teardown"];
    if (route[@"provider"]) {
        self.customCDNPreference=YES;
        BOOL applied = [self applyCDNPreference:route[@"provider"]];
        if (!applied) [self log:@"CDN 偏好未生效，按默认调度播放"];
    } else if(self.customCDNPreference) {
        [self callClass:NSClassFromString(@"CNPlayer") sel:@"configSDK_CDN_LIVEDefaultCDNInfo:" args:@[self.initialCDNPreference?:NSNull.null]];
        id restored=[self callClass:NSClassFromString(@"CNPlayer") sel:@"getVDNConfig_CDNLive_DefaultCDNInfo" args:@[]];
        BOOL matches=restored==self.initialCDNPreference||[restored isEqual:self.initialCDNPreference];
        self.customCDNPreference=!matches;
        [self log:matches?@"已恢复 SDK 默认 CDN 偏好":@"无法确认 CDN 默认值恢复，请重启后使用自动线路"];
    }
    self.cicadaPending = NO;
    [self playViaSDK:cid title:self.channelName];

    // Defer optional EPG traffic until the first video frame.
}

- (void)playViaSDK:(NSString *)cid title:(NSString *)title {
    if([ProfileStore isHTTP:cid]){[self playRemote:@{@"id":cid,@"name":title?:cid,@"remoteURL":cid}];return;}
    [self beginPlaybackPriority];
    // Default matches v0.12: stop the old playback, reset the retained wrapper,
    // then playLIVEWithChannelID + prepareToPlay. Fresh wrappers remain an A/B option.
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    Class cls=NSClassFromString(@"CNPlayer");SEL playSel=NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    BOOL legacy=CCTVBoolPreference(@"legacyNativePlayback",YES);
    id inst=self.sdkPlayer;
    if(!legacy&&self.sdkPlayerUsed)inst=nil;
    if(legacy&&inst&&self.sdkPlayerUsed)[self call:inst sel:@"reset"];
    self.sdkPlayer=nil;
    if(!inst){@try{inst=[[cls alloc] init];}@catch(NSException *e){[self log:@"创建播放器异常 %@",e.reason];}}
    if(!inst||![inst respondsToSelector:playSel]){self.titleLabel.text=@"SDK 接口不可用";[self.spinner stopAnimating];return;}
    self.currentPlayer=inst;self.cicadaPlayer=nil;self.sdkPlayer=legacy?inst:nil;self.sdkPlayerUsed=YES;
    @try{[inst setValue:@YES forKey:@"autoPlay"];}@catch(NSException *e){}
    NSDictionary *options=@{kOptTitle:title?:cid};
    [self log:@"原生起播 %@ · %@",cid,legacy?@"0.12 兼容复用":@"独立实例对比"];
    id accepted=[self invokeTarget:inst selector:playSel args:@[cid,self,options]];
    if([accepted isKindOfClass:NSNumber.class]&&![accepted boolValue]){
        id previous=inst;self.currentPlayer=nil;
        @try{[previous setValue:nil forKey:@"delegate"];}@catch(NSException *e){}
        [self call:previous sel:@"stop"];
        @try{inst=[[cls alloc] init];}@catch(NSException *e){inst=nil;}
        if(inst){self.currentPlayer=inst;self.sdkPlayer=legacy?inst:nil;@try{[inst setValue:@YES forKey:@"autoPlay"];}@catch(NSException *e){}accepted=[self invokeTarget:inst selector:playSel args:@[cid,self,options]];}
    }
    [self recordStartupStage:@"configure"];
    if(!inst||([accepted isKindOfClass:NSNumber.class]&&![accepted boolValue])){
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · 起播被拒绝",self.channelName];[self.spinner stopAnimating];[self log:@"SDK 拒绝起播，等待具体错误回调"];return;
    }
    [self attachVideoView];[self call:inst sel:@"prepareToPlay"];[self recordStartupStage:@"prepareCall"];[self startWatchdog];
}

- (void)recordStartupStage:(NSString *)stage {
    if([self.startupTrace record:stage atTime:CACurrentMediaTime()])
        [self log:@"起播阶段 %@ [%lu] %@ +%.2fs",self.channelID?:@"—",(unsigned long)self.playbackGeneration,stage,[self.startupTrace.stages[stage] doubleValue]];
}

- (void)stopPlayback {
    [self.playbackReadiness cancel];self.playbackReadiness=nil;
    if(self.avLayerObserved){[self.avLayer removeObserver:self forKeyPath:@"readyForDisplay" context:kAVLayerFrameContext];self.avLayerObserved=NO;}

    self.epgListGeneration++;
    for(NSURLSessionDataTask *task in self.epgListTasks.allValues)[task cancel];[self.epgListTasks removeAllObjects];[self.epgInflight removeAllObjects];
    if(self.pip.isPictureInPictureActive)[self.pip stopPictureInPicture];self.pip=nil;
    [self.epgTask cancel];
    self.epgTask = nil;
    [self.epgTimer invalidate];
    self.epgTimer = nil;
    id previous = self.currentPlayer;
    // Ignore synchronous teardown callbacks before changing the core.
    self.currentPlayer = nil;
    if (previous) {
        @try { [previous setValue:nil forKey:@"delegate"]; } @catch (NSException *e) {}
        [self call:previous sel:@"stop"];
    }
    if (self.cicadaPlayer) {
        [self call:self.cicadaPlayer sel:@"destroy"];
    }
    if (self.avPlayer) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:self.avPlayer.currentItem];
        [self.avPlayer pause];
        AVPlayerItem *previousItem=self.avPlayer.currentItem;
        @try { [previousItem removeObserver:self forKeyPath:@"status" context:kAVItemStatusContext]; } @catch (NSException *e) {}
        [previousItem cancelPendingSeeks];[previousItem.asset cancelLoading];[self.avPlayer replaceCurrentItemWithPlayerItem:nil];
        self.avPlayer = nil;
    }
    self.avLayer.player=nil;
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
        self.channelGrid.hidden=YES;
        self.playerTabs.hidden=YES;
        self.playbackPanel.view.hidden=YES;
        self.tabPage.view.hidden=YES;
    } else {
        BOOL catalog=self.activeTab<3;
        BOOL matchingPlayer=self.favoritesOnly||(self.subscriptionCatalog==([self.currentRemoteURL length]>0));
        BOOL expanded=self.playerExpanded&&matchingPlayer;
        CGFloat ph=expanded?MIN(w*9.0/16.0,MAX(120,(height-top-safe.bottom)*0.50)):0;
        self.playerBox.frame=CGRectMake(0,top,w,ph);self.playerBox.hidden=!catalog||!expanded;
        CGFloat y=top+ph;self.groupControl.frame=CGRectMake(12,y+6,w-24,28);self.groupControl.hidden=!catalog||expanded;self.playerTabs.frame=CGRectMake(12,y+6,w-24,28);self.playerTabs.hidden=!catalog||!expanded;
        self.versionLabel.hidden=YES;
        CGFloat contentY=y+42;CGFloat tabY=height-safe.bottom-64;
        CGRect frame=CGRectMake(0,contentY,w,MAX(0,tabY-contentY));self.table.frame=frame;self.channelGrid.frame=frame;
        self.table.hidden=!catalog||self.gridMode||self.playbackPanel!=nil;self.channelGrid.hidden=!catalog||!self.gridMode||self.playbackPanel!=nil;self.playbackPanel.view.frame=frame;self.playbackPanel.view.hidden=!catalog;
        self.bottomBar.frame=CGRectMake(MAX(18,(w-420)/2),height-safe.bottom-60,MIN(w-36,420),52);self.bottomBar.hidden=NO;
        self.tabPage.view.frame=CGRectMake(0,top,w,MAX(0,tabY-top));[self.view bringSubviewToFront:self.bottomBar];
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
    if(self.logVisible){[self.view bringSubviewToFront:self.logView];[self.view bringSubviewToFront:self.logToolbar];}
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
    self.tabPage.view.hidden=NO;
    [self.view setNeedsLayout];
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

- (void)openServicesPage {
    ServicesViewController *page=[ServicesViewController new];
    __weak typeof(self) weakSelf=self;
    page.onOpenYSP=^{ [weakSelf openPluginPage]; };
    page.onToggleService=^(NSDictionary *service,BOOL enabled){[weakSelf toggleService:service enabled:enabled];};
    page.onOpenLog=^{[weakSelf.navigationController popToViewController:weakSelf animated:YES];dispatch_async(dispatch_get_main_queue(), ^{if(!weakSelf.logVisible)[weakSelf toggleLog];});};
    page.onSubscribe=^(NSString *url){NSString *key=[weakSelf stableURLKey:url];if(!key)return;[weakSelf.subscriptionURLs addObject:key];[NSUserDefaults.standardUserDefaults setObject:weakSelf.subscriptionURLs.allObjects forKey:@"subscriptions"];[weakSelf fetchSubscription:key silent:NO];};
    [self.navigationController pushViewController:page animated:YES];
}

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
    [self.navigationController pushViewController:[self makeSettingsPage] animated:YES];
}

- (SettingsViewController *)makeSettingsPage {
    SettingsViewController *page=[SettingsViewController new];
    __weak typeof(self) weakSelf=self;
    page.onExportData=^{[weakSelf exportLocalConfiguration];};page.onImportData=^{[weakSelf importLocalConfiguration];};page.onOpenLog=^{if(!weakSelf.logVisible)[weakSelf toggleLog];};
    page.onClearEPG=^{ [[XMLTVStore shared] clear];[weakSelf.epgCache removeAllObjects]; [weakSelf saveEPGCache]; [weakSelf.table reloadData]; };
    page.onPreferenceChanged=^(NSString *key, BOOL value){
        if ([key isEqualToString:@"allowBackgroundAudio"]) [weakSelf activateAudioSession];
        if ([key isEqualToString:@"autoLoadEPG"]) { [weakSelf.epgTimer invalidate]; weakSelf.epgTimer=nil; if(value) [weakSelf restartEPGTimer]; else weakSelf.infoLabel.text=@"节目单自动获取已关闭"; }
    };
    return page;
}

- (void)exportLocalConfiguration {
    NSData *data=[NSJSONSerialization dataWithJSONObject:[HostBackup snapshot] options:NSJSONWritingPrettyPrinted error:NULL];NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"CCTVHost-configuration.json"];[data writeToFile:path atomically:YES];UIActivityViewController *v=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];v.popoverPresentationController.sourceView=self.bottomBar;v.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:v animated:YES completion:nil];
}
- (void)importLocalConfiguration {self.importingPlaylist=NO;UIDocumentPickerViewController *v=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];v.delegate=self;[self presentViewController:v animated:YES completion:nil];}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u=urls.firstObject;BOOL scoped=[u startAccessingSecurityScopedResource];NSData *data=[NSData dataWithContentsOfURL:u];if(scoped)[u stopAccessingSecurityScopedResource];if(self.importingPlaylist){self.importingPlaylist=NO;[self importPlaylistData:data name:u.lastPathComponent];return;}
    NSError *error=nil;NSDictionary *backup=[HostBackup validatedBackup:data error:&error];if(!backup){[self showServiceError:error.localizedDescription];return;}
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"导入本机配置" message:@"将替换本机订阅、收藏和偏好。Python 服务代码单独导入，不受影响。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        for(NSString *source in self.subscriptionURLs.allObjects){self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];}
        [HostBackup restore:backup];self.subscriptionURLs=[NSMutableSet setWithArray:backup[@"subscriptions"]];self.favorites=[backup[@"favorites"] mutableCopy];self.recents=[[NSUserDefaults.standardUserDefaults arrayForKey:@"recents"] mutableCopy];self.activeSource=nil;self.gridMode=CCTVBoolPreference(@"channelGridMode",YES);for(NSString *source in self.subscriptionURLs)[self fetchSubscription:source silent:YES];[self activateAudioSession];[self applyFilter];[self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews.firstObject];
    }]];[self presentViewController:a animated:YES completion:nil];
}
- (PlaybackInfoViewController *)playbackInformationPage {
    PlaybackInfoViewController *v=[PlaybackInfoViewController new];__weak typeof(self) w=self;v.rowsProvider=^{NSMutableArray *r=[NSMutableArray arrayWithArray:@[@{@"title":@"频道名称",@"value":w.channelName?:@"未选台"},@{@"title":@"频道 ID",@"value":w.channelID?:@"—"},@{@"title":@"播放引擎",@"value":w.avPlayer?@"AVPlayer":@"CNPlayerSDK"},@{@"title":@"线路偏好",@"value":w.routeName?:@"自动"},@{@"title":@"首帧耗时",@"value":w.firstRender?[NSString stringWithFormat:@"%.2f 秒",w.firstFrameSeconds]:@"等待画面"},@{@"title":@"应用版本",@"value":kBuildTag}]];
        AVPlayerItem *item=w.avPlayer.currentItem;if(item){CGSize size=item.presentationSize;[r addObject:@{@"title":@"视频分辨率",@"value":size.width>0?[NSString stringWithFormat:@"%.0f × %.0f",size.width,size.height]:@"等待视频信息"}];AVPlayerItemAccessLogEvent *event=item.accessLog.events.lastObject;if(event)[r addObject:@{@"title":@"观测带宽",@"value":[NSString stringWithFormat:@"%.2f Mbps",event.observedBitrate/1000000.0]}];}return r;};return v;
}
- (void)selectPlayerPanel {
    if(self.playbackPanel){[self.playbackPanel willMoveToParentViewController:nil];[self.playbackPanel.view removeFromSuperview];[self.playbackPanel removeFromParentViewController];self.playbackPanel=nil;}
    NSInteger index=self.playerTabs.selectedSegmentIndex;if(index>0){UIViewController *v=index==1?[[EPGViewController alloc] initWithChannel:[self channelWithID:self.channelID]?:@{@"name":self.channelName?:@"节目单"} officialID:[self epgIDForChannel:[self channelWithID:self.channelID]]?:@""]:[self playbackInformationPage];self.playbackPanel=v;[self addChildViewController:v];[self.view addSubview:v.view];[v didMoveToParentViewController:self];}[self.view setNeedsLayout];
}

- (void)presentSubscriptionActions:(NSDictionary *)channel sourceView:(UIView *)source {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:channel[@"name"]?:@"订阅频道" message:channel[@"remoteURL"] preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"从列表移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ NSMutableArray *m=[self.allChannels mutableCopy]; [m removeObject:channel]; self.allChannels=m; [self applyFilter]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView=source; a.popoverPresentationController.sourceRect=source.bounds; [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)originForURL:(NSURL *)url {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];if(!c.host.length)return nil;
    c.path=@"";c.query=nil;c.fragment=nil;return c.URL.absoluteString;
}
- (NSDictionary *)localServiceForURL:(NSURL *)url {
    NSString *host=url.host.lowercaseString;
    if(![@[@"127.0.0.1",@"localhost",@"::1",@"[::1]"] containsObject:host])return nil;
    NSInteger port=url.port?url.port.integerValue:([url.scheme.lowercaseString isEqualToString:@"https"]?443:80);
    for(NSDictionary *service in [ServiceStore services])if([service[@"port"] integerValue]==port)return service;
    return nil;
}
- (LocalServiceReadiness *)readinessForURL:(NSURL *)url service:(NSDictionary *)service {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.path=[service[@"builtin"] boolValue]?@"/health":@"/";c.query=nil;c.fragment=nil;
    return [[LocalServiceReadiness alloc] initWithURL:c.URL timeout:20 requiresHealthJSON:[service[@"builtin"] boolValue]];
}
- (BOOL)startService:(NSDictionary *)service error:(NSError **)error {
    if(PyHost.running){
        if([[ServiceStore activeIdentifier] isEqualToString:service[@"id"]]&&PyHost.port==[service[@"port"] integerValue])return YES;
        if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:3 userInfo:@{NSLocalizedDescriptionKey:@"已有其他 Python 服务正在运行，请停止后重开 App 再切换服务。"}];return NO;
    }
    NSString *dataDir=[ServiceStore dataDirectoryForService:service error:error];if(!dataDir.length)return NO;
    NSInteger port=[service[@"port"] integerValue];NSString *bind=[service[@"lan"] boolValue]?@"0.0.0.0":@"127.0.0.1";NSMutableArray *args=[NSMutableArray array];
    if([service[@"builtin"] boolValue]){
        [args addObjectsFromArray:@[[NSString stringWithFormat:@"%ld",(long)port],@"--bind",bind,@"--no-engine",@"--data-dir",dataDir,@"--cache-mb",@"32",@"--links-per-device",@"2",@"--zap-debounce",@"15"]];
    }else{
        for(NSString *part in [service[@"arguments"]?:@"" componentsSeparatedByString:@"|"]){if(!part.length)continue;NSString *arg=[part stringByReplacingOccurrencesOfString:@"{port}" withString:[NSString stringWithFormat:@"%ld",(long)port]];arg=[arg stringByReplacingOccurrencesOfString:@"{bind}" withString:bind];[args addObject:[arg stringByReplacingOccurrencesOfString:@"{dataDir}" withString:dataDir]];}
    }
    __weak typeof(self) w=self;[PyHost setLogHandler:^(NSString *line){if(line.length)[w log:@"[py] %@",line];}];
    if(![PyHost startScriptAtPath:[ServiceStore scriptPath:service] port:port dataDir:dataDir arguments:args error:error])return NO;
    [NSUserDefaults.standardUserDefaults setObject:service[@"id"] forKey:@"activePythonService"];
    [self log:@"服务进程启动 %@ · %ld，等待 HTTP 就绪",service[@"name"],(long)port];
    if([service[@"builtin"] boolValue]){
        NSString *url=[NSString stringWithFormat:@"http://127.0.0.1:%ld/all.m3u",(long)port];[self.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
    }
    for(NSString *source in self.subscriptionURLs.allObjects){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:source]];if([owner[@"id"] isEqualToString:service[@"id"]])[self fetchSubscription:source silent:YES];}
    [self.pluginPage updateRunning:PyHost.running subscriptionCount:self.subscriptionURLs.count];return YES;
}
- (void)toggleService:(NSDictionary *)service enabled:(BOOL)enabled {
    NSError *error=nil;
    if(enabled){if(![self startService:service error:&error])[self showServiceError:error.localizedDescription];return;}
    if(![PyHost stopWithError:&error]){[self showServiceError:error.localizedDescription];return;}
    [self.readyLocalOrigins removeAllObjects];
    for(LocalServiceReadiness *probe in self.subscriptionReadiness.allValues)[probe cancel];[self.subscriptionReadiness removeAllObjects];
    if([self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]]){
        self.playbackGeneration++;[self stopPlayback];[self.spinner stopAnimating];self.titleLabel.hidden=NO;self.titleLabel.text=@"本机服务已停止";
    }
    [self log:@"服务已请求停止，保留订阅供下次启动续播"];
}
- (void)showServiceError:(NSString *)message {UIAlertController *a=[UIAlertController alertControllerWithTitle:@"服务" message:message?:@"服务操作失败，请查看日志。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];UIViewController *top=self.navigationController.topViewController?:self;[top presentViewController:a animated:YES completion:nil];}
- (void)stopBuiltinPlugin {for(NSDictionary *service in [ServiceStore services])if([service[@"builtin"] boolValue]){[self toggleService:service enabled:NO];break;}}
- (void)startBuiltinPlugin {for(NSDictionary *service in [ServiceStore services])if([service[@"builtin"] boolValue]){[self toggleService:service enabled:YES];break;}}

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
    if(self.epgWriteScheduled)return;self.epgWriteScheduled=YES;__weak typeof(self) w=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        w.epgWriteScheduled=NO;NSDictionary *snapshot=w.epgCache.copy;NSString *path=[w epgCachePath];if(!snapshot||!path.length)return;
        dispatch_async(w.epgDiskQueue, ^{NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:NULL];[data writeToFile:path atomically:YES];});
    });
}

- (NSIndexPath *)indexPathForChannelID:(NSString *)cid {
    BOOL twoSections = [self numberOfSectionsInTableView:self.table] == 2;
    NSUInteger recentIndex = [[self visibleRecents] indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"id"] isEqualToString:cid ?: @""]; }];
    if (twoSections && recentIndex != NSNotFound) return [NSIndexPath indexPathForRow:(NSInteger)recentIndex inSection:0];
    NSUInteger row = [self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"id"] isEqualToString:cid ?: @""]; }];
    if (row == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:(NSInteger)row inSection:(twoSections ? 1 : 0)];
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
    if(self.channelID.length&&!self.firstRender)return;
    __weak UIImageView *weakIV = iv;
    NSURLSessionDataTask *logoTask=[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data.length) return;
        UIImage *img = [UIImage imageWithData:data];
        if (!img) return;
        [LogoCache() setObject:img forKey:url];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakIV && [weakIV.accessibilityIdentifier isEqualToString:url]) weakIV.image = img;
        });
    }];[self.logoTasks addObject:logoTask];[logoTask resume];
}

#pragma mark - 搜索 / 最近 / 节目单缓存

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    self.query = sc.searchBar.text;
    [self applyFilter];
}

- (void)applyFilter {
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSArray *base=[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *bindings){
        BOOL remote=[c[@"remoteURL"] length]>0;
        if(!self.favoritesOnly && remote!=self.subscriptionCatalog)return NO;
        if(!remote)return CCTVBoolPreference(@"nativeChannelsEnabled",YES) && (!self.activeSource || !self.activeSource.length);
        NSSet *owners=[NSSet setWithArray:c[@"subscriptionSources"]?:@[]];NSMutableSet *enabled=[owners mutableCopy];[enabled minusSet:disabled];
        return enabled.count && (!self.activeSource || [enabled containsObject:self.activeSource]);
    }]];
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
        if(fa&&fb)return [@([self.favorites indexOfObject:a[@"id"]]) compare:@([self.favorites indexOfObject:b[@"id"]])];
        return NSOrderedSame;
    }];
    self.shownChannels = sorted;
    [self.table reloadData];
    [self.channelGrid reloadData];
    NSString *empty=self.query.length?@"没有找到匹配频道":(self.favoritesOnly?@"还没有收藏频道，长按频道即可收藏":(self.subscriptionCatalog?@"暂无订阅频道\n点击右上角更多 → 添加订阅，或在配置中导入播放列表":@"暂无官方频道，请在配置中启用官方频道"));
    UILabel *hint=[UILabel new];hint.text=empty;hint.numberOfLines=0;hint.textAlignment=NSTextAlignmentCenter;hint.textColor=UIColor.secondaryLabelColor;hint.font=[UIFont systemFontOfSize:14];
    self.channelGrid.backgroundView=sorted.count?nil:hint;
    UILabel *listHint=[UILabel new];listHint.text=empty;listHint.numberOfLines=0;listHint.textAlignment=NSTextAlignmentCenter;listHint.textColor=UIColor.secondaryLabelColor;self.table.backgroundView=sorted.count?nil:listHint;
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
    if(self.subscriptionCatalog||self.activeTab==3){for(NSString *u in self.subscriptionURLs.allObjects)[self fetchSubscription:u silent:YES];}
    else{[self.epgCache removeAllObjects];[self saveEPGCache];if(self.firstRender)[self refreshNowNext];[self applyFilter];}
    [self.table.refreshControl endRefreshing];[self.channelGrid.refreshControl endRefreshing];
}

- (void)loadEPGForChannel:(NSString *)cid section:(NSIndexPath *)ip {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)) return;
    if(self.channelID.length&&!self.firstRender)return;
    if (!cid.length || self.epgCache[cid] || [self.epgInflight containsObject:cid]) return;
    NSDictionary *channel=[self channelWithID:cid];NSString *xmlSource=[ProfileStore epgSourceForChannel:channel];
    if(xmlSource.length){NSArray *rows=[[XMLTVStore shared] cachedRowsForSource:xmlSource channel:[ProfileStore epgIDForChannel:channel]];[self cacheXMLRows:rows channel:cid];if(self.epgCache[cid])return;}
    if (self.epgInflight.count >= 3) return;
    NSString *epgCID=[self epgIDForChannel:[self channelWithID:cid]];
    if(!epgCID.length)return;
    [self.epgInflight addObject:cid];
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox",
                     [epgCID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 8;
    NSUInteger listGeneration=self.epgListGeneration;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task=[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if(listGeneration!=weakSelf.epgListGeneration)return;
            [weakSelf.epgListTasks removeObjectForKey:cid];
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
                [weakSelf.channelGrid reloadData];
            }
        });
    }];self.epgListTasks[cid]=task;[task resume];
}

#pragma mark - 订阅（m3u 源 / 本地插件）

- (void)addSubscription {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"添加配置" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"订阅链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self addSubscriptionURL];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"导入 M3U 文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){self.importingPlaylist=YES;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)addSubscriptionURL {
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

- (NSString *)stableURLKey:(id)value {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *urlString = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!urlString.length || urlString.length > 8192) return nil;
    @try {
        NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
        if (!components) return nil;
        NSString *scheme = components.scheme.lowercaseString;
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;
        if (!components.host.length || !components.URL) return nil;
        components.scheme = scheme;
        components.host = components.host.lowercaseString;
        components.fragment = nil;
        if (([scheme isEqualToString:@"http"] && components.port.integerValue == 80) ||
            ([scheme isEqualToString:@"https"] && components.port.integerValue == 443)) components.port = nil;
        return components.URL.absoluteString;
    } @catch (NSException *exception) {
        // M3U is untrusted input. One malformed percent escape must never abort the UI process.
        return nil;
    }
}

- (void)removeSubscriptionSource:(NSString *)sourceKey {
    [self.subscriptionReadiness[sourceKey] cancel];[self.subscriptionReadiness removeObjectForKey:sourceKey];[self.deferredLocalSubscriptions removeObject:sourceKey];
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
    NSString *sourceKey=[ProfileStore isHTTP:urlString]?[self stableURLKey:urlString]:([ProfileStore isSource:urlString]?urlString:nil);
    if (!sourceKey.length) return;
    if(self.channelID.length&&!self.firstRender){[self.deferredLocalSubscriptions addObject:sourceKey];return;}
    [ProfileStore update:sourceKey values:@{@"status":@"刷新中…"}];
    if(![ProfileStore isHTTP:sourceKey]){NSString *text=[ProfileStore metadata:sourceKey][@"text"];[self applyPlaylistText:text source:sourceKey];return;}
    NSURL *sourceURL=[NSURL URLWithString:sourceKey];NSDictionary *localService=[self localServiceForURL:sourceURL];
    if(localService){
        if(!PyHost.running){
            if(![self.deferredLocalSubscriptions containsObject:sourceKey])[self log:@"本机订阅暂缓加载，等待服务启动 %@",sourceKey];
            [self.deferredLocalSubscriptions addObject:sourceKey];return;
        }
        NSString *origin=[self originForURL:sourceURL];NSNumber *readyAt=self.readyLocalOrigins[origin];
        if(!readyAt||CACurrentMediaTime()-readyAt.doubleValue>2){
            if(self.subscriptionReadiness[sourceKey])return;
            NSUInteger readinessVersion=[self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]+1;self.subscriptionRequestVersions[sourceKey]=@(readinessVersion);
            LocalServiceReadiness *probe=[self readinessForURL:sourceURL service:localService];self.subscriptionReadiness[sourceKey]=probe;__weak typeof(self) w=self;
            [probe start:^(NSError *error,NSTimeInterval elapsed){
                if(w.subscriptionReadiness[sourceKey]!=probe)return;[w.subscriptionReadiness removeObjectForKey:sourceKey];
                if([w.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]!=readinessVersion||![w.subscriptionURLs containsObject:sourceKey])return;
                if(error){[w log:@"本机订阅等待服务失败 %@",error.localizedDescription];return;}
                w.readyLocalOrigins[origin]=@(CACurrentMediaTime());[w.deferredLocalSubscriptions removeObject:sourceKey];[w fetchSubscription:sourceKey silent:silent];
            }];return;
        }
    }
    NSUInteger requestVersion = [self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] + 1;
    self.subscriptionRequestVersions[sourceKey] = @(requestVersion);
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 12;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    __weak typeof(self) weakSelf = self;
    [self.subscriptionTasks[sourceKey] cancel];
    NSURLSessionDataTask *subscriptionTask=[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status=[resp isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)resp statusCode]:0;
        if(status<200||status>=300||data.length>10*1024*1024)data=nil;
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSArray<M3UChannel *> *list = text.length ? [M3UParser parse:text baseURL:url] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([weakSelf.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] != requestVersion) return;
            [weakSelf.subscriptionTasks removeObjectForKey:sourceKey];
            if (!list.count) {
                [ProfileStore update:sourceKey values:@{@"status":err.localizedDescription?:@"刷新失败，保留上次频道"}];[weakSelf refreshConfigurationPage];
                [weakSelf log:@"订阅失败 %@ %@", urlString, err.localizedDescription ?: @"无有效条目"];
                return;
            }
            NSString *detected=[M3UParser epgURL:text baseURL:url];if(detected.length)[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];
            [weakSelf installPlaylist:list source:sourceKey];
        });
    }];self.subscriptionTasks[sourceKey]=subscriptionTask;[subscriptionTask resume];
}
- (void)installPlaylist:(NSArray<M3UChannel *> *)list source:(NSString *)sourceKey {
            NSMutableArray *merged = [NSMutableArray array];
            for (NSDictionary *existing in self.allChannels ?: @[]) {
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
                NSString *stable = [self stableURLKey:merged[i][@"remoteURL"]];
                if (stable.length) urlIndexes[stable] = @(i);
            }
            NSUInteger added = 0;
            NSUInteger skippedInvalidURLs = 0;
            for (M3UChannel *c in list) {
                if (!c.name.length || !c.url.length) { skippedInvalidURLs++; continue; }
                NSString *stable = [self stableURLKey:c.url];
                if (!stable.length) { skippedInvalidURLs++; continue; }
                NSMutableArray *alts = self.altSources[c.name];
                if (!alts) { alts = [NSMutableArray array]; self.altSources[c.name] = alts; }
                if (![alts containsObject:c.url]) [alts addObject:c.url];
                NSNumber *existingIndex = urlIndexes[stable];
                if (existingIndex) {
                    NSMutableDictionary *entry = [merged[existingIndex.unsignedIntegerValue] mutableCopy];
                    NSMutableSet *owners = [NSMutableSet setWithArray:entry[@"subscriptionSources"] ?: @[]];
                    [owners addObject:sourceKey];
                    entry[@"subscriptionSources"] = owners.allObjects;
                    entry[@"name"] = c.name;
                    entry[@"group"] = c.group ?: @"订阅";
                    if (c.epgID.length) entry[@"epgID"]=c.epgID;
                    if (c.logo.length) entry[@"logo"] = c.logo; else [entry removeObjectForKey:@"logo"];
                    entry[@"remoteURL"] = c.url;
                    if(c.epgID.length)entry[@"epgID"]=c.epgID;else[entry removeObjectForKey:@"epgID"];
                    merged[existingIndex.unsignedIntegerValue] = entry;
                } else {
                    NSMutableDictionary *entry = [@{@"id": stable,
                                                    @"name": c.name,
                                                    @"group": c.group ?: @"订阅",
                                                    @"verified": @NO,
                                                    @"remoteURL": c.url,
                                                    @"subscriptionSources": @[sourceKey]} mutableCopy];
                    if (c.epgID.length) entry[@"epgID"]=c.epgID;
                    if (c.logo.length) entry[@"logo"] = c.logo;
                    urlIndexes[stable] = @(merged.count);
                    [merged addObject:entry];
                    added++;
                }
            }
            self.allChannels = merged;
            NSArray *owned=[merged filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *b){return [c[@"subscriptionSources"] containsObject:sourceKey];}]];
            [ProfileStore update:sourceKey values:@{@"cachedChannels":owned,@"status":@"已更新",@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
            [self applyFilter];
            if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];
            if (skippedInvalidURLs) [self log:@"订阅跳过 %lu 条无效地址（仅允许有效 HTTP/HTTPS URL）", (unsigned long)skippedInvalidURLs];
            [self log:@"订阅 %@ 新增 %lu 个频道（共 %lu）", sourceKey, (unsigned long)added, (unsigned long)list.count];
}
- (void)applyPlaylistText:(NSString *)text source:(NSString *)sourceKey {
    NSArray *list=[M3UParser parse:text baseURL:nil];if(!list.count){[ProfileStore update:sourceKey values:@{@"status":@"无有效 HTTP/HTTPS 频道，保留上次频道"}];[self refreshConfigurationPage];return;}
    NSString *detected=[M3UParser epgURL:text baseURL:nil];if(detected.length)[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];[self installPlaylist:list source:sourceKey];
}

- (void)playRemote:(NSDictionary *)ch {
    [self beginPlaybackPriority];
    if(self.activeTab!=1)[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[1]];
    NSString *u=[self stableURLKey:ch[@"remoteURL"]];if(!u.length)return;
    self.playbackGeneration += 1;NSUInteger generation=self.playbackGeneration;
    NSTimeInterval requestedAt=CACurrentMediaTime();
    [self stopPlayback];self.playerExpanded=YES;[self.view setNeedsLayout];
    self.currentRemoteURL=u;self.channelID=ch[@"id"]?:u;self.channelName=ch[@"name"]?:u;self.routeName=@"订阅";
    self.firstRender=NO;self.retryCount=0;self.playStartedAt=requestedAt;self.firstFrameSeconds=0;
    self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    [self recordStartupStage:@"teardown"];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",self.channelName];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"";[self.spinner startAnimating];
    [self.table reloadData];[self.channelGrid reloadData];[self log:@"订阅起播 %@ [%lu]",u,(unsigned long)generation];
    NSDictionary *service=[self localServiceForURL:[NSURL URLWithString:u]];
    if(!service){[self startRemoteURL:u generation:generation];return;}
    NSError *error=nil;
    if(!PyHost.running){
        if([service[@"builtin"] boolValue]&&![PyHost startedOnce]){if(![self startService:service error:&error]){[self failRemoteReadiness:error generation:generation];return;}}
        else{error=[NSError errorWithDomain:@"CCTVHostService" code:2 userInfo:@{NSLocalizedDescriptionKey:PyHost.startedOnce?@"本机服务已停止，本次进程不能再次启动，请重新打开 App。":@"请先在服务页启动此自定义 Python 服务。"}];[self failRemoteReadiness:error generation:generation];return;}
    }
    if(![[ServiceStore activeIdentifier] isEqualToString:service[@"id"]]||PyHost.port!=[service[@"port"] integerValue]){
        [self failRemoteReadiness:[NSError errorWithDomain:@"CCTVHostService" code:3 userInfo:@{NSLocalizedDescriptionKey:@"当前运行的服务与频道端口不一致，请检查服务配置。"}] generation:generation];return;
    }
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待本机服务",self.channelName];
    LocalServiceReadiness *probe=[self readinessForURL:[NSURL URLWithString:u] service:service];self.playbackReadiness=probe;__weak typeof(self) w=self;
    [probe start:^(NSError *error,NSTimeInterval elapsed){
        if(generation!=w.playbackGeneration||w.playbackReadiness!=probe)return;
        w.playbackReadiness=nil;if(error){[w failRemoteReadiness:error generation:generation];return;}
        w.readyLocalOrigins[[w originForURL:[NSURL URLWithString:u]]]=@(CACurrentMediaTime());[w recordStartupStage:@"service"];
        [w log:@"本机服务 HTTP 就绪 %.2fs",elapsed];[w startRemoteURL:u generation:generation];
    }];
}
- (void)failRemoteReadiness:(NSError *)error generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;[self.spinner stopAnimating];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 服务未就绪",self.channelName];[self log:@"本机续播失败 %@",error.localizedDescription];
}
- (void)startRemoteURL:(NSString *)url generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;
    AVPlayerItem *item=[AVPlayerItem playerItemWithURL:[NSURL URLWithString:url]];item.preferredForwardBufferDuration=1;
    self.avPlayer=[AVPlayer playerWithPlayerItem:item];self.avPlayer.automaticallyWaitsToMinimizeStalling=NO;
    self.avLayer=[AVPlayerLayer playerLayerWithPlayer:self.avPlayer];self.avLayer.frame=self.playerBox.bounds;self.avLayer.videoGravity=AVLayerVideoGravityResizeAspect;[self.playerBox.layer insertSublayer:self.avLayer atIndex:0];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:kAVItemStatusContext];
    self.avLayerObserved=YES;
    [self.avLayer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:kAVLayerFrameContext];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [self recordStartupStage:@"prepareCall"];[self.avPlayer play];__weak typeof(self) w=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        if(generation!=w.playbackGeneration||item!=w.avPlayer.currentItem||w.firstRender)return;
        [w.spinner stopAnimating];w.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待视频首帧",w.channelName];[w log:@"订阅 12 秒未渲染首帧（并非播放器就绪时间）"];
    });
}

- (void)avItemFailed:(NSNotification *)n {
    if (n.object != self.avPlayer.currentItem) return;
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

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)change context:(void *)context {
    if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(), ^{[self observeValueForKeyPath:kp ofObject:obj change:change context:context];});return;}
    if(context==kAVLayerFrameContext){
        if(obj!=self.avLayer||!self.avLayer.readyForDisplay||self.firstRender)return;
        self.firstRender=YES;[self endPlaybackPriority];self.firstFrameSeconds=CACurrentMediaTime()-self.playStartedAt;[self recordStartupStage:@"frame"];
        [self.spinner stopAnimating];self.titleLabel.hidden=YES;self.infoLabel.hidden=YES;[self updateNowPlaying];
        [self log:@"订阅视频首帧 %.2fs · %@",self.firstFrameSeconds,self.startupTrace.summary];return;
    }
    if(context==kAVItemStatusContext){
        AVPlayerItem *item=obj;if(item!=self.avPlayer.currentItem)return;
        if(item.status==AVPlayerItemStatusReadyToPlay){[self recordStartupStage:@"itemReady"];[self log:@"订阅播放器就绪，继续等待视频渲染"];}else if(item.status==AVPlayerItemStatusFailed){[self.spinner stopAnimating];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 失败",self.channelName];[self log:@"订阅失败 %@",item.error.localizedDescription];}
        return;
    }
    [super observeValueForKeyPath:kp ofObject:obj change:change context:context];
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

- (NSString *)epgIDForChannel:(NSDictionary *)ch {
    if(!ch)return nil;if(![ch[@"remoteURL"] length])return ch[@"id"];
    NSString *key=[[ProfileStore epgIDForChannel:ch] lowercaseString];NSDictionary *matched=key.length?[self channelWithID:key]:nil;if(matched&&![matched[@"remoteURL"] length])return key;
    for(NSDictionary *native in self.allChannels){if([native[@"remoteURL"] length])continue;if([native[@"name"] isEqualToString:ch[@"name"]])return native[@"id"];}
    return nil;
}
- (void)openEPGforChannel:(NSString *)cid name:(NSString *)name {
    NSString *epgID=[self epgIDForChannel:[self channelWithID:cid]];
    [self.navigationController pushViewController:[[EPGViewController alloc] initWithChannel:[self channelWithID:cid]?:@{@"id":cid?:@"",@"name":name?:@"节目单"} officialID:epgID?:@""] animated:YES];
}

- (void)restartEPGTimer {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)) { [self.epgTimer invalidate]; self.epgTimer=nil; return; }
    [self.epgTimer invalidate];
    self.epgTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshNowNext) userInfo:nil repeats:YES];
}

- (void)refreshNowNext {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)) return;
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
    NSTimeInterval elapsed=CACurrentMediaTime()-self.playStartedAt;
    if(elapsed>=10&&!self.stallReported){
        self.stallReported=YES;BOOL vdnDone=self.startupTrace.stages[@"vdn"]!=nil;
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@",self.channelName,vdnDone?@"等待视频数据":@"调度等待中"];
        [self log:@"原生起播等待 %.2fs · %@，不重复重启请求 · %@",elapsed,vdnDone?@"VDN 已完成":@"VDN 尚未完成",self.startupTrace.summary];
    }
    if(elapsed>=25){[timer invalidate];[self.spinner stopAnimating];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待较久，可重新选台",self.channelName];[self log:@"25 秒未首帧 · %@",self.startupTrace.summary];}

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
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player loadStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    [self attachVideoView];
    if (state == 4) {                     // PrepareDone
        [self recordStartupStage:@"prepared"];
        if(!self.firstRender){[self log:@"PrepareDone → play"];[self call:self.currentPlayer sel:@"play"];}else [self log:@"PrepareDone：已自动出画面，不重复 play"];
    } else if (state == 13) {
        [self log:@"加载取消"];
    }
}

- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { NSTimeInterval received=CACurrentMediaTime();NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self log:@"SDK VDN callback %@ · raw +%.3fs · mainLag %.3fs",@(state),received-self.playStartedAt,CACurrentMediaTime()-received];[self player:player vdnRequestStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    if (state == 3) { [self recordStartupStage:@"vdn"]; [self log:@"VDN 成功"]; }
    else if (state == 2) [self log:@"VDN 失败"];
}

- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if (![NSThread isMainThread]) { NSTimeInterval received=CACurrentMediaTime();NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self log:@"SDK stat callback %@ · raw +%.3fs · mainLag %.3fs",@(event),received-self.playStartedAt,CACurrentMediaTime()-received];[self player:player statEvent:event value:value]; }); return; }
    if (player != self.currentPlayer) return;
    if(event==1)[self recordStartupStage:@"sdkStartup"];
    if(event==2)[self recordStartupStage:@"setup"];
    if (event == 3 && !self.firstRender) {
        self.firstFrameSeconds = CACurrentMediaTime() - self.playStartedAt;
        self.firstRender = YES;[self endPlaybackPriority];
        self.cicadaPending = NO;
        [self.cicadaFallbackTimer invalidate];
        [self.spinner stopAnimating];
        self.titleLabel.text = self.channelName;
        self.titleLabel.hidden = YES;
        self.infoLabel.hidden = YES;
        [self recordStartupStage:@"frame"];
        [self log:@"首帧渲染 %.2fs · %@", self.firstFrameSeconds,self.startupTrace.summary];
        [self updateNowPlaying];
        [self refreshNowNext];
        [self restartEPGTimer];
    }
}

- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player playBackStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer) return;
    if (state == 1) [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    if (state == 2) [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal];
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player playbackFailed:error]; }); return; }
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
                self.playbackGeneration+=1;self.stallReported=NO;
                self.playStartedAt=CACurrentMediaTime();self.firstRender=NO;self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
                [self playViaSDK:cid title:name];
            }
        });
    }
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player vdnRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"VDN 请求失败 %ld", (long)error.code];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player parameterError:error rate:rate]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"参数错误 %ld", (long)error.code];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player publicRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    [self log:@"版权请求失败 %ld", (long)error.code];
}

- (void)authFailed:(NSError *)error {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self authFailed:error]; }); return; }
    [self log:@"鉴权失败 %ld", (long)error.code];
    self.titleLabel.text = @"鉴权失败";
}

- (void)showPlaybackInfo {
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[self playbackInformationPage]];HostStyleNavigation(nav);nav.navigationBar.prefersLargeTitles=NO;nav.modalPresentationStyle=UIModalPresentationPageSheet;nav.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];nav.sheetPresentationController.prefersGrabberVisible=YES;[self presentViewController:nav animated:YES completion:nil];
}

- (void)showMorePlaybackActions {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:self.channelName ?: @"播放操作" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:self.fullscreen?@"退出全屏":@"全屏" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self toggleFullscreen]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"播放信息" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self showPlaybackInfo]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"画中画" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self togglePiP]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"诊断日志" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self toggleLog]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) { sheet.popoverPresentationController.sourceView=self.moreBtn; sheet.popoverPresentationController.sourceRect=self.moreBtn.bounds; }
    [self presentViewController:sheet animated:YES completion:nil];
}


- (void)beginPlaybackPriority {
    self.playbackIntentVersion++;[self stopPreview];[[XMLTVStore shared] setPaused:YES];self.subscriptionParseGeneration++;
    for(NSString *source in self.subscriptionTasks.allKeys){[self.subscriptionTasks[source] cancel];[self.deferredLocalSubscriptions addObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);}
    [self.subscriptionTasks removeAllObjects];for(NSURLSessionDataTask *t in self.logoTasks)[t cancel];[self.logoTasks removeAllObjects];
}
- (void)endPlaybackPriority {
    [[XMLTVStore shared] setPaused:NO];NSUInteger generation=self.playbackGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{if(generation==self.playbackGeneration&&self.firstRender){[self refreshSubscriptionsWhenIdle];[self.channelGrid reloadData];}});
}
- (void)refreshSubscriptionsWhenIdle {
    if(self.channelID.length&&!self.firstRender)return;
    NSArray *pending=self.deferredLocalSubscriptions.allObjects;[self.deferredLocalSubscriptions removeAllObjects];for(NSString *s in pending)[self fetchSubscription:s silent:YES];
}
- (void)refreshConfigurationPage {if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];}
- (void)importPlaylistData:(NSData *)data name:(NSString *)name {
    NSString *text=data.length<=10*1024*1024?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
    if(![M3UParser parse:text baseURL:nil].count){[self showServiceError:@"文件须为 UTF-8 M3U 播放列表，包含有效 HTTP/HTTPS 频道，且不超过 10MB。"];return;}
    NSString *source=[@"local-playlist:" stringByAppendingString:NSUUID.UUID.UUIDString];[ProfileStore update:source values:@{@"name":name?:@"本地播放列表",@"text":text}];[self.subscriptionURLs addObject:source];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];[self applyPlaylistText:text source:source];
}
- (void)editProfile:(NSString *)source {
    NSDictionary *p=[ProfileStore metadata:source];UIAlertController *a=[UIAlertController alertControllerWithTitle:@"编辑配置" message:@"XMLTV 地址留空时使用播放列表提供的 EPG。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"配置名称";t.text=p[@"name"]?:[NSURL URLWithString:source].host;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"订阅链接（本地文件不可修改）";t.text=[ProfileStore isHTTP:source]?source:@"本地文件";t.enabled=[ProfileStore isHTTP:source];t.autocapitalizationType=UITextAutocapitalizationTypeNone;t.keyboardType=UIKeyboardTypeURL;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"XMLTV / XMLTV.gz 地址";t.text=p[@"epgURL"]?:p[@"detectedEPGURL"];t.autocapitalizationType=UITextAutocapitalizationTypeNone;t.keyboardType=UIKeyboardTypeURL;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *u=[ProfileStore isHTTP:source]?[self stableURLKey:a.textFields[1].text]:source;NSString *epg=[a.textFields[2].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!u.length||(epg.length&&![ProfileStore isHTTP:epg])){[self showServiceError:@"订阅和 EPG 地址须为有效 HTTP/HTTPS 链接。"];return;}
        NSMutableDictionary *values=[p mutableCopy];values[@"name"]=a.textFields[0].text?:@"";values[@"epgURL"]=epg?:@"";
        if(![source isEqualToString:u]){[self deleteSubscription:source];[values removeObjectForKey:@"cachedChannels"];[self.subscriptionURLs addObject:u];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];}
        [ProfileStore update:u values:values];[self.epgCache removeAllObjects];[self fetchSubscription:u silent:NO];[self refreshConfigurationPage];
    }]];[self presentViewController:a animated:YES completion:nil];
}
- (void)editEPGMapping:(NSDictionary *)ch {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"EPG 手动匹配" message:@"输入 XMLTV channel ID 或央视官方频道 ID；留空恢复自动匹配。" preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *t){t.text=[ProfileStore epgIDForChannel:ch];t.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *m=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{} mutableCopy];NSString *key=ch[@"id"];NSString *value=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(value.length)m[key]=value;else[m removeObjectForKey:key];[NSUserDefaults.standardUserDefaults setObject:m forKey:@"epgMappings"];[self.epgCache removeObjectForKey:key];[self saveEPGCache];[self applyFilter];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)showRemoteTools:(NSDictionary *)ch {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:ch[@"name"] message:@"订阅频道 · AVPlayer" preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"重新播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self routePlayback:ch];}]];
    for(NSString *url in self.altSources[ch[@"name"]]){if([url isEqual:ch[@"remoteURL"]])continue;[a addAction:[UIAlertAction actionWithTitle:[NSURL URLWithString:url].host?:@"备用源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *other=[ch mutableCopy];other[@"remoteURL"]=url;[self routePlayback:other];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self openEPGforChannel:ch[@"id"] name:ch[@"name"]];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"EPG 手动匹配" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self editEPGMapping:ch];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"静音预览（30 秒）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self previewChannel:ch];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)previewChannel:(NSDictionary *)ch {
    if(self.currentPlayer||self.avPlayer||self.playbackReadiness){[self showServiceError:@"为保证正式播放，预览仅在没有频道播放时启动。"];return;}
    NSString *url=[self stableURLKey:ch[@"remoteURL"]];if(!url.length)return;
    if([self localServiceForURL:[NSURL URLWithString:url]]&&!PyHost.running){[self showServiceError:@"请先启动该频道的本机服务。"];return;}
    [self stopPreview];self.previewPlayer=[AVPlayer playerWithURL:[NSURL URLWithString:url]];self.previewPlayer.muted=YES;self.previewLayer=[AVPlayerLayer playerLayerWithPlayer:self.previewPlayer];
    UIView *box=[[UIView alloc] initWithFrame:CGRectMake(16,self.view.safeAreaInsets.top+12,MIN(280,self.view.bounds.size.width-32),158)];box.backgroundColor=UIColor.blackColor;box.layer.cornerRadius=14;box.clipsToBounds=YES;self.previewBox=box;[self.view addSubview:box];self.previewLayer.frame=box.bounds;self.previewLayer.videoGravity=AVLayerVideoGravityResizeAspect;[box.layer addSublayer:self.previewLayer];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];[close setTitle:@"关闭预览" forState:UIControlStateNormal];close.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];close.frame=CGRectMake(180,0,100,44);[close addTarget:self action:@selector(stopPreview) forControlEvents:UIControlEventTouchUpInside];[box addSubview:close];[self.previewPlayer play];__weak typeof(self) w=self;self.previewTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t){[w stopPreview];}];
}
- (void)stopPreview {[self.previewTimer invalidate];self.previewTimer=nil;[self.previewPlayer pause];[self.previewPlayer.currentItem.asset cancelLoading];[self.previewPlayer replaceCurrentItemWithPlayerItem:nil];self.previewPlayer=nil;self.previewLayer.player=nil;[self.previewLayer removeFromSuperlayer];self.previewLayer=nil;[self.previewBox removeFromSuperview];self.previewBox=nil;}
- (void)showHistory {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"最近观看" message:self.recents.count?nil:@"还没有观看记录" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *r in self.recents)[a addAction:[UIAlertAction actionWithTitle:r[@"name"]?:r[@"id"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSDictionary *ch=[self channelWithID:r[@"id"]];if(ch)[self selectChannel:ch];else[self showServiceError:@"该频道已不在配置中，请刷新或重新导入原配置。"];}]];
    if(self.recents.count)[a addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[self.recents removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"recents"];[self applyFilter];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)showFavoriteManager {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"整理收藏" message:@"点选频道可移到收藏首位；频道列表左滑可取消收藏。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSString *cid in self.favorites){NSDictionary *ch=[self channelWithID:cid];[a addAction:[UIAlertAction actionWithTitle:ch[@"name"]?:cid style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self.favorites removeObject:cid];[self.favorites insertObject:cid atIndex:0];[NSUserDefaults.standardUserDefaults setObject:self.favorites forKey:@"favorites"];[self applyFilter];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)cacheXMLRows:(NSArray *)rows channel:(NSString *)cid {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSString *current=nil,*next=nil;for(NSDictionary *r in rows){double start=[r[@"start"] doubleValue],end=[r[@"end"] doubleValue];if(now>=start&&now<end)current=r[@"title"];else if(start>now&&!next)next=r[@"title"];}
    if(current||next)self.epgCache[cid]=@{@"now":current?:@"",@"next":next?:@"",@"ts":@(now)};
}
@end
