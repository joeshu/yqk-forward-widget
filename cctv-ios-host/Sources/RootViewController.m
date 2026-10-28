#import "MediaRelayDiagnostics.h"
#import "RootViewController.h"
#import "CNPlayerSDK.h"
#import "CicadaSDK.h"
#import "EPGViewController.h"
#import "M3UParser.h"
#import "PyHost.h"
#import "NodePluginRuntime.h"
#import "JSPluginRuntime.h"
#import "PluginViewController.h"
#import "SettingsViewController.h"
#import "RuntimeDiagnosticsViewController.h"
#import <dispatch/dispatch.h>
#import "ServicesViewController.h"
#import "MediaBrowserViewController.h"
#import "MediaPackageImporter.h"
#import "HLSRouteProbe.h"
#import "MediaPackageDownloader.h"
#import "MediaWebViewController.h"
#import "ServiceEditorViewController.h"
#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostImageLoader.h"
#import "HostLogBuffer.h"
#import "HostLogRedactor.h"
#import "HostToolbar.h"
#import "ProfileStore.h"
#import "XMLTVStore.h"
#import "ServiceStore.h"
#import "HostBackup.h"
#import "LocalServiceReadiness.h"
#import "HostLocalPort.h"
#import "PlaybackStartupTrace.h"
#import "NativeStartupTuner.h"
#import "NativeCDNPreference.h"
#import "NativeChannelPreloader.h"
#import "NativeTimeshiftSession.h"
#import "PlaybackInfoViewController.h"
#import "LogCenterViewController.h"
#import "PluginRunHistoryViewController.h"
#import "RuntimeDiagnostics.h"
#import "PluginLogStore.h"
#import "CNPlayerCrashGuard.h"
#import "ResourceImportSheetViewController.h"
#import "PluginResourceDetailViewController.h"
#import "MediaPlaybackViewController.h"
#import "MediaPlaybackHeaders.h"
#import "TVBoxCatalogStore.h"
#import "TVBoxCatalogDownloader.h"
#import "TVBoxCatalogViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *CCTVBuildTag(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"未知";
}
static void *const kAVItemStatusContext = (void *)&kAVItemStatusContext;
static void *const kAVLayerFrameContext = (void *)&kAVLayerFrameContext;
// 这两个键名来自 CNPlayerSDK 导出常量（值即常量名本身），SDK 缺 Title 会直接拒播并报错误码 4012
static NSString *const kOptTitle = @"CNPlayerConfigOptionKey_Title";
static NSString *const kOptDefaultRate = @"CNPlayerConfigOptionKey_DefaultRate";
static NSString *const kOptUserID = @"CNPlayerConfigOptionKey_UserID";
static NSString *const kOptURLChannelIDForStats = @"CNPlayerConfigOptionKey_URLSource_VID_ChannelIDUsedStat";
static NSString *const kLicenseUrl = @"https://drm.live.cntv.cn:444/udrm/udmCNTVGetLicense";
static BOOL CCTVRemotePlaybackErrorCanRetrySameURL(NSError *error) {
    if(![error.domain isEqualToString:NSURLErrorDomain])return YES;
    switch(error.code){
        case NSURLErrorCancelled:
        case NSURLErrorBadURL:
        case NSURLErrorUnsupportedURL:
        case NSURLErrorFileDoesNotExist:
        case NSURLErrorFileIsDirectory:
        case NSURLErrorNoPermissionsToReadFile:
        case NSURLErrorCannotDecodeContentData:
        case NSURLErrorCannotParseResponse:
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return NO;
        default:
            return YES;
    }
}
static NSDictionary *CCTVDiagnosticURLFields(NSURL *url) {
    if(!RuntimeDiagnostics.shared.enabled||!url)return @{};
    NSString *scheme=url.scheme.lowercaseString?:@"";
    NSString *host=url.host.lowercaseString?:@"";
    NSNumber *port=url.port?:@0;
    NSString *path=url.path?:@"";
    NSString *identity=[NSString stringWithFormat:@"%@://%@:%@%@",scheme,host,port,path];
    NSData *data=[identity dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]={0};
    if(data.length)CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *fingerprint=[NSMutableString string];
    for(NSUInteger index=0;index<8;index++)[fingerprint appendFormat:@"%02x",digest[index]];
    BOOL loopback=[host isEqualToString:@"127.0.0.1"]||[host isEqualToString:@"localhost"]||[host isEqualToString:@"::1"];
    return @{@"source_scheme":scheme,
             @"source_host":host,
             @"source_port":port,
             @"source_extension":url.pathExtension.lowercaseString?:@"",
             @"source_is_loopback":@(loopback),
             @"source_route_fingerprint":fingerprint};
}
static void CCTVAddAVPlayerFailureFields(NSMutableDictionary *fields, AVPlayerItem *item, AVPlayer *player, NSError *error) {
    if (!fields || !item) return;
    NSArray<AVPlayerItemErrorLogEvent *> *networkEvents = item.errorLog.events ?: @[];
    fields[@"network_error_event_count"] = @(networkEvents.count);
    AVPlayerItemErrorLogEvent *network = networkEvents.lastObject;
    if (network) {
        fields[@"network_error_domain"] = network.errorDomain ?: @"";
        // CoreMedia uses negative status values for transport/parser failures;
        // keep the signed value so the diagnostic can distinguish these from
        // an HTTP response status.
        fields[@"network_error_status_code"] = @(network.errorStatusCode);
        NSURL *networkURL = [NSURL URLWithString:network.URI ?: @""];
        if (networkURL.host.length) {
            fields[@"network_error_host"] = networkURL.host.lowercaseString;
            fields[@"network_error_extension"] = networkURL.pathExtension.lowercaseString ?: @"";
        }
    }
    NSArray<AVPlayerItemAccessLogEvent *> *accessEvents = item.accessLog.events ?: @[];
    fields[@"access_log_event_count"] = @(accessEvents.count);
    AVPlayerItemAccessLogEvent *access = accessEvents.lastObject;
    if (access) {
        fields[@"media_requests"] = @(MAX(0, access.numberOfMediaRequests));
        fields[@"media_bytes_transferred"] = @(MAX(0, access.numberOfBytesTransferred));
        fields[@"media_stall_count"] = @(MAX(0, access.numberOfStalls));
        fields[@"media_dropped_video_frames"] = @(MAX(0, access.numberOfDroppedVideoFrames));
    }
    NSMutableArray *chain = [NSMutableArray array];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    for (NSUInteger depth = 0; underlying && depth < 4; depth++) {
        [chain addObject:@{@"domain":underlying.domain ?: @"", @"code":@(underlying.code)}];
        underlying = underlying.userInfo[NSUnderlyingErrorKey];
    }
    fields[@"underlying_error_count"] = @(chain.count);
    if (chain.count) fields[@"underlying_error_chain"] = chain;
    fields[@"player_item_status"] = @(item.status);
    fields[@"player_time_control_status"] = @(player.timeControlStatus);
    CGSize size = item.presentationSize;
    if (isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0) {
        fields[@"video_presentation_width"] = @((NSInteger)llround(size.width));
        fields[@"video_presentation_height"] = @((NSInteger)llround(size.height));
    }
}
static BOOL CCTVBoolPreference(NSString *key, BOOL fallback) {
    id value=[[NSUserDefaults standardUserDefaults] objectForKey:key];
    return value ? [value boolValue] : fallback;
}
static NSString *CCTVServiceLogAddress(NSString *raw) {
    NSURLComponents *components=[NSURLComponents componentsWithString:raw?:@""];
    if(!components.URL)return [HostLogRedactor redactText:raw?:@""];
    NSArray<NSURLQueryItem *> *items=components.queryItems;
    if(items.count){NSMutableArray *safe=[NSMutableArray arrayWithCapacity:items.count];for(NSURLQueryItem *item in items)[safe addObject:[NSURLQueryItem queryItemWithName:item.name value:item.value.length?@"[已脱敏]":item.value]];components.queryItems=safe;}
    return components.URL.absoluteString?:[HostLogRedactor redactText:raw?:@""];
}
static NSString *CCTVRouteGroupKey(NSDictionary *channel) {
    NSString *rawEPGID=[channel[@"epgID"] isKindOfClass:NSString.class]?channel[@"epgID"]:@"";
    NSString *epgID=[rawEPGID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(epgID.length)return [@"tvg-id:" stringByAppendingString:epgID.lowercaseString];
    // A shared display name is not enough evidence that two URLs carry the same channel.
    NSString *channelID=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    return [@"channel:" stringByAppendingString:channelID];
}

@interface CCTVPlaybackListPanelController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,copy) NSArray<NSDictionary *> *items;
@property(nonatomic,copy) NSString *emptyMessage;
@property(nonatomic,copy) void (^selectionHandler)(NSDictionary *item);
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UILabel *emptyLabel;
@end

@implementation CCTVPlaybackListPanelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=HostBackground();
    self.tableView=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor=HostBackground();
    self.tableView.dataSource=self;self.tableView.delegate=self;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=66;
    self.tableView.separatorColor=HostSeparator();
    self.emptyLabel=[UILabel new];self.emptyLabel.text=self.emptyMessage?:@"暂无可显示内容";self.emptyLabel.textColor=UIColor.secondaryLabelColor;self.emptyLabel.numberOfLines=0;self.emptyLabel.textAlignment=NSTextAlignmentCenter;
    self.tableView.backgroundView=self.emptyLabel;
    [self.view addSubview:self.tableView];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection])
        HostRefreshAppearanceLayers(self.view.window);
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse=@"cctv.playback.panel";
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuse];
    if(!cell){cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];cell.backgroundColor=HostCard();cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=3;cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;}
    NSDictionary *item=self.items[indexPath.row];cell.textLabel.text=item[@"title"]?:@"";cell.detailTextLabel.text=item[@"detail"]?:@"";
    cell.accessoryType=[item[@"selected"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;
    cell.tintColor=HostAccent();cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    NSString *symbol=item[@"symbol"];cell.imageView.image=symbol.length?[UIImage systemImageNamed:symbol]:nil;cell.imageView.tintColor=HostAccent();
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];if(indexPath.row>=self.items.count)return;
    if(self.selectionHandler)self.selectionHandler(self.items[indexPath.row]);
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.emptyLabel.frame=CGRectInset(self.tableView.bounds,32,32);self.emptyLabel.hidden=self.items.count>0;
}
@end

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate, AVPlayerViewControllerDelegate>
// 播放
@property (nonatomic, strong) UIView *playerBox;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImageView *playerChannelLogo;
@property (nonatomic, strong) UIStackView *controlBar;
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) UIButton *muteBtn;
@property (nonatomic, strong) UIButton *routeBtn;
@property (nonatomic, strong) UIButton *epgBtn;
@property (nonatomic, strong) UIButton *fullBtn;
@property (nonatomic, strong) id currentPlayer;
@property (nonatomic, strong) id sdkPlayer;
@property (nonatomic, assign) BOOL sdkPlayerUsed;
@property (nonatomic, strong) dispatch_queue_t epgDiskQueue;
@property (nonatomic, assign) BOOL epgWriteScheduled;
@property (nonatomic, strong) NSMutableDictionary<NSString *,NSURLSessionDataTask *> *epgListTasks;
@property (nonatomic, assign) NSUInteger epgListGeneration;
@property (nonatomic, strong) PlaybackStartupTrace *startupTrace;
@property (nonatomic, strong) NativeStartupTuner *nativeStartupTuner;
@property (nonatomic, strong) NativeChannelPreloader *nativePreloader;
@property(nonatomic,strong) NativeTimeshiftSession *nativeTimeshift;
@property(nonatomic,copy) NSString *nativeTransitionKind;
@property(nonatomic) BOOL nativeTimeShiftActive;
@property (nonatomic) BOOL nativePlaybackFailed;
@property (nonatomic, strong) LocalServiceReadiness *playbackReadiness;
@property (nonatomic, strong) NSMutableDictionary<NSString *,LocalServiceReadiness *> *subscriptionReadiness;
@property (nonatomic, strong) NSMutableDictionary<NSString *,NSNumber *> *readyLocalOrigins;
@property (nonatomic, strong) NSMutableSet<NSString *> *deferredLocalSubscriptions;
@property (nonatomic, strong) NativeCDNPreference *nativeCDNPreference;
@property (nonatomic, strong) NSMutableDictionary<NSString *,NSDictionary *> *plainRouteCache;
@property(nonatomic,strong) HLSRouteProbe *nativeRouteProbe;
@property(nonatomic) BOOL nativePlainRouteActive;
@property (nonatomic, copy) NSDictionary *requestedNativeRoute;
@property (nonatomic, assign) BOOL directNativeRouteActive;
@property (nonatomic, assign) BOOL avLayerObserved;
@property (nonatomic) BOOL avKeepUpObserved;
@property (nonatomic) BOOL remotePlaybackWanted;
@property (nonatomic) NSTimeInterval playbackPriorityUntil;
@property (nonatomic, strong) AVPlayer *avPlayer;
@property (nonatomic, strong) AVPlayerLayer *avLayer;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *subscriptions;
@property (nonatomic, strong) NSMutableSet<NSString *> *subscriptionURLs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *subscriptionRequestVersions;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *subscriptionTraceIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *epgCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *epgInflight;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *recents;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) CicadaPlayer *cicadaPlayer;
@property (nonatomic, copy) NSString *channelID;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, copy) NSString *currentRemoteURL;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *currentRemoteHeaders;
@property (nonatomic, copy) NSString *currentRemotePlaybackAttemptID;
@property (nonatomic, copy) NSString *routeName;
@property (nonatomic, assign) BOOL firstRender;
@property (nonatomic, assign) BOOL fullscreen;
@property (nonatomic, assign) BOOL stallReported;
@property (nonatomic, assign) BOOL nativeStartupRecoveryUsed;
@property (nonatomic, strong) NSMutableSet<NSString *> *serviceOperations;
// 频道
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UICollectionView *channelGrid;
@property (nonatomic, strong) UISegmentedControl *playerTabs;
@property (nonatomic, strong) UIViewController *playbackPanel;
@property (nonatomic, strong) UIViewController *tabPage;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIViewController *> *tabPages;
@property (nonatomic, assign) BOOL gridMode;
@property (nonatomic, assign) BOOL playerExpanded;
@property (nonatomic, copy) NSString *activeSource;
@property (nonatomic, strong) UISegmentedControl *groupControl;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *allChannels;
@property (nonatomic, strong) NSArray<NSDictionary *> *shownChannels;
@property (nonatomic, assign) NSInteger retryCount;
// 日志
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, copy) NSString *diagnosticLogPath;
@property (nonatomic, strong) dispatch_queue_t diagnosticLogQueue;
@property (nonatomic, strong) HostLogBuffer *pendingLogWrites;
@property (nonatomic, strong) HostLogBuffer *pendingLogDisplay;
@property (nonatomic) BOOL diagnosticWriteInProgress;
@property (nonatomic, assign) BOOL diagnosticFlushScheduled;
@property (nonatomic, assign) NSUInteger diagnosticLogGeneration;
@property (nonatomic, assign) NSUInteger playbackGeneration;
@property (nonatomic, copy) NSString *currentPlaybackTraceID;
// 计时
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) NSInteger watchdogTicks;
@property (nonatomic, strong) NSTimer *epgTimer;
@property(nonatomic,assign) BOOL epgRefreshDesired;
@property (nonatomic, strong) NSURLSessionDataTask *epgTask;
@property(nonatomic,assign) NSUInteger officialEPGRequestGeneration;
@property (nonatomic, strong) MPVolumeView *volumeView;
@property (nonatomic, assign) NSTimeInterval playStartedAt;
@property (nonatomic, assign) NSTimeInterval firstFrameSeconds;
@property (nonatomic, strong) NSMutableArray<NSString *> *favorites;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *altSources;
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, strong) PluginViewController *pluginPage;
@property (nonatomic, strong) UIStackView *bottomBar;
@property (nonatomic, strong) UIVisualEffectView *bottomBarBackdrop;
@property (nonatomic, assign) NSInteger activeTab;
@property (nonatomic, assign) BOOL initialTabRestorePending;
@property (nonatomic, assign) BOOL restoringLastTab;
@property (nonatomic, assign) BOOL userInitiatedTabSelection;
@property (nonatomic, assign) BOOL subscriptionCatalog;
@property (nonatomic, assign) BOOL favoritesOnly;
@property (nonatomic, strong) UIButton *pipBtn;
@property (nonatomic, strong) UIButton *moreBtn;
@property (nonatomic, copy) NSString *epgChannel;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSURLSessionDataTask *> *subscriptionTasks;
@property(nonatomic,strong) NSMutableSet<NSString *> *remoteAttemptedURLs;
@property(nonatomic) NSUInteger catalogSearchGeneration;
@property(nonatomic,strong) AVPlayer *moviePlayer;
@property(nonatomic,strong) AVPlayerViewController *movieController;
@property(nonatomic) BOOL importingMediaPackage;
@property(nonatomic) BOOL moviePiPActive;
@property(nonatomic,strong) MediaPackageDownloader *packageDownloader;
@property(nonatomic,strong) TVBoxCatalogDownloader *tvboxCatalogDownloader;
@property(nonatomic) BOOL importingTVBoxCatalog;
@property(nonatomic,copy) NSString *pendingTVBoxExt;
@property(nonatomic,copy) NSString *pendingTVBoxSiteName;
@property(nonatomic,strong) NSMutableDictionary *catalogStates;
@property(nonatomic) NSUInteger remoteRetryCount;
@property(nonatomic) BOOL remoteFailureRecoveryPending;
@property(nonatomic) BOOL remotePlaybackFailed;
@property(nonatomic) BOOL nativeRetryPending;
@property(nonatomic,strong) AVPlayer *previewPlayer;
@property(nonatomic,strong) AVPlayerLayer *previewLayer;
@property(nonatomic,strong) UIView *previewBox;
@property(nonatomic,strong) NSTimer *previewTimer;
@property(nonatomic,assign) BOOL importingPlaylist;
@property(nonatomic,assign) NSUInteger selectionVersion;
@property(nonatomic,assign) NSTimeInterval selectionRequestedAt;
@property(nonatomic,assign) NSUInteger playbackIntentVersion;
@property(nonatomic,assign) NSUInteger subscriptionParseGeneration;
- (void)displayNativePlaybackFailure:(NSString *)stage error:(nullable NSError *)error;
- (void)toggleCurrentFavorite;
- (void)openDiagnosticLog;
- (void)openDiagnosticLogForIdentifier:(nullable NSString *)identifier name:(nullable NSString *)name;
- (void)openPluginRunLogForIdentifier:(NSString *)identifier name:(NSString *)name run:(NSDictionary *)run;
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name;
- (void)openPluginResource:(NSString *)source;
- (void)openTVBoxCatalog:(NSString *)identifier;
- (void)acceptTVBoxCatalog:(NSDictionary *)catalog;
- (void)importTVBoxCatalog;
- (void)importMacCMSAPI;
- (void)importTVBoxSite:(NSDictionary *)site;
- (void)importTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport;
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error autoBrowse:(BOOL)autoBrowse;
- (void)saveImportedMedia:(NSDictionary *)service autoBrowse:(BOOL)autoBrowse;
- (void)usePluginService:(NSDictionary *)service kind:(NSString *)kind;
- (void)continueRemotePlaybackForURL:(NSString *)url service:(NSDictionary *)service generation:(NSUInteger)generation;
- (NSDictionary *)localServiceForChannel:(NSDictionary *)channel URL:(NSURL *)url;
- (NSArray<NSString *> *)managedSubscriptionSourcesForService:(NSDictionary *)service excludingURL:(NSString *)url;
- (void)openServiceEditorForService:(NSDictionary *)service;
- (void)applyServiceConfigurationFrom:(NSDictionary *)previous to:(NSDictionary *)updated completion:(void (^)(NSError * _Nullable error))completion;
- (void)saveImportedMedia:(NSDictionary *)service;
- (void)shareDiagnosticLogAtURL:(NSURL *)source;
- (void)restartMediaService:(NSDictionary *)source completion:(void (^)(NSError *))completion;
@end

@implementation RootViewController

- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    [MediaPackageImporter migrateLegacyRuntimeMetadata];
    self.view.backgroundColor = HostBackground();
    self.title = @"CCTV";
    HostStyleNavigation(self.navigationController);
    self.view.tintColor=HostAccent();
    NSUserDefaults *preferences=NSUserDefaults.standardUserDefaults;
    if(![preferences boolForKey:@"cctv.manualStartupLoadingMigration.v1"]){[preferences setBool:NO forKey:@"resumeLastChannel"];[preferences setBool:YES forKey:@"cctv.manualStartupLoadingMigration.v1"];}
    id savedTab=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.lastBottomTab.v1"];
    if([savedTab respondsToSelector:@selector(integerValue)]&&[savedTab integerValue]>=0&&[savedTab integerValue]<=4){self.activeTab=[savedTab integerValue];self.initialTabRestorePending=self.activeTab!=0;}
    self.gridMode = [[NSUserDefaults standardUserDefaults] objectForKey:@"channelGridMode"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"channelGridMode"] : YES;
    self.logBuffer = [NSMutableString string];
    self.diagnosticLogQueue = dispatch_queue_create("com.cctvhost.diagnostic-log", DISPATCH_QUEUE_SERIAL);
    self.pendingLogWrites = [[HostLogBuffer alloc] initWithMaximumCharacters:65536];
    self.pendingLogDisplay = [[HostLogBuffer alloc] initWithMaximumCharacters:16000];
    NSString *supportDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    self.diagnosticLogPath = [[supportDir stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"cctvhost.log"];
    [self restoreDiagnosticLog];
    self.retryCount = 0;

    self.epgDiskQueue=dispatch_queue_create("com.cctvhost.epg-disk",DISPATCH_QUEUE_SERIAL);
    self.epgListTasks=[NSMutableDictionary dictionary];
    self.subscriptionReadiness=[NSMutableDictionary dictionary];
    self.readyLocalOrigins=[NSMutableDictionary dictionary];
    self.deferredLocalSubscriptions=[NSMutableSet set];
    self.subscriptionTasks=[NSMutableDictionary dictionary];self.subscriptionTraceIDs=[NSMutableDictionary dictionary];self.remoteAttemptedURLs=[NSMutableSet set];self.catalogStates=[NSMutableDictionary dictionary];for(NSInteger tab=0;tab<2;tab++){NSDictionary *savedState=[[NSUserDefaults standardUserDefaults] dictionaryForKey:[NSString stringWithFormat:@"cctv.catalogState.%ld",(long)tab]];if(savedState)self.catalogStates[@(tab)]=savedState;}self.tabPages=[NSMutableDictionary dictionary];
    [self loadChannels];
    [self buildPlayer];
    [self buildList];
    [self configureCatalogNavigation];
    [self activateAudioSession];
    [self setupRemoteCommands];
    [self registerCallbackProtocol];
    [self setupSDK];
    [self log:@"日志持久化已启用（按需批量保存）"];
    [PyHost recoverInterruptedPythonSessions];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(checkVisibleMediaAfterActivation) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(!self.initialTabRestorePending)return;
    self.initialTabRestorePending=NO;
    NSInteger savedTab=self.activeTab;
    if(savedTab<0||savedTab>=self.bottomBar.arrangedSubviews.count)return;
    self.restoringLastTab=YES;
    [self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews[savedTab]];
    self.restoringLastTab=NO;
}

- (void)dealloc {
    [self.packageDownloader cancel];
    [self.tvboxCatalogDownloader cancel];
    [self.nativePreloader cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.playbackReadiness cancel];
    for(LocalServiceReadiness *probe in self.subscriptionReadiness.allValues)[probe cancel];
    [self.watchdog invalidate];
    [self.epgTimer invalidate];
    [self.epgTask cancel];
    [self flushDiagnosticLog];
}

- (void)onBackground {
    [(MediaBrowserViewController *)self.tabPages[@2] pauseForBackground];
    [self.nativePreloader cancel];
    [[HostImageLoader shared] cancelPending];
    [self stopPreview];
    [self.epgTimer invalidate];self.epgTimer=nil;
    self.officialEPGRequestGeneration++;[self.epgTask cancel];self.epgTask=nil;
    [[XMLTVStore shared] setPaused:YES];
    [self call:self.currentPlayer sel:@"resignActive"];
    if (CCTVBoolPreference(@"autoPiP",NO) && self.avLayer && AVPictureInPictureController.isPictureInPictureSupported && !self.pip.isPictureInPictureActive) {
        self.pip=[[AVPictureInPictureController alloc] initWithPlayerLayer:self.avLayer];
        [self.pip startPictureInPicture];
        [self log:@"后台自动进入画中画"];
    }
    [self log:@"进入后台"];
    [self flushDiagnosticLog];
}

- (void)onForeground {
    BOOL playbackPriority=CACurrentMediaTime()<self.playbackPriorityUntil;
    [[XMLTVStore shared] setPaused:playbackPriority];
    [self call:self.currentPlayer sel:@"becomeActive"];
    if(self.epgRefreshDesired&&!playbackPriority){[self restartEPGTimer];[self refreshNowNext];}
    if(self.activeTab<2 && CACurrentMediaTime()>=self.playbackPriorityUntil){[self.channelGrid reloadData];[self.table reloadData];}
    [self log:@"回到前台"];
}
- (void)checkVisibleMediaAfterActivation {
    if(self.activeTab==2&&self.navigationController.topViewController==self)[(MediaBrowserViewController *)self.tabPages[@2] resumeAfterForeground];
}

#pragma mark - 日志

- (void)restoreDiagnosticLog {
    NSError *error=nil;
    NSString *text=[NSString stringWithContentsOfFile:self.diagnosticLogPath encoding:NSUTF8StringEncoding error:&error];
    text=[HostLogRedactor redactText:text?:@""];
    if (text.length) {
        [self.logBuffer appendString:@"—— 上次运行日志（崩溃/强制退出前）——\n"];
        [self.logBuffer appendString:text];
        if (![text hasSuffix:@"\n"]) [self.logBuffer appendString:@"\n"];
        [self.logBuffer appendString:@"—— 本次启动 ——\n"];
        NSLog(@"[CCTVHost] 已恢复上次运行日志，%lu 字符",(unsigned long)text.length);
    }
}
- (void)persistDiagnosticLine:(NSString *)line {
    [self.pendingLogWrites append:line];
    [self scheduleDiagnosticLogFlush];
}
- (void)scheduleDiagnosticLogFlush {
    if(!self.pendingLogWrites||!self.diagnosticLogPath.length)return;
    @synchronized(self.pendingLogWrites){if(self.diagnosticFlushScheduled)return;self.diagnosticFlushScheduled=YES;}
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{RootViewController *owner=weakSelf;if(owner)[owner flushDiagnosticLog];});
}
- (void)flushDiagnosticLog {
    NSString *batch;NSUInteger generation;
    @synchronized(self.pendingLogWrites) {
        self.diagnosticFlushScheduled=NO;
        if(self.diagnosticWriteInProgress || !self.pendingLogWrites.length || !self.diagnosticLogPath.length)return;
        self.diagnosticWriteInProgress=YES;generation=self.diagnosticLogGeneration;batch=[self.pendingLogWrites drain];
    }
    dispatch_async(self.diagnosticLogQueue, ^{@autoreleasepool {
        NSFileHandle *file=nil;
        @try {
            @synchronized(self.pendingLogWrites){if(generation!=self.diagnosticLogGeneration)return;}
            NSFileManager *fm=NSFileManager.defaultManager;
            [fm createDirectoryAtPath:self.diagnosticLogPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            if(![fm fileExistsAtPath:self.diagnosticLogPath])[fm createFileAtPath:self.diagnosticLogPath contents:nil attributes:nil];
            file=[NSFileHandle fileHandleForWritingAtPath:self.diagnosticLogPath];
            [file seekToEndOfFile];[file writeData:[batch dataUsingEncoding:NSUTF8StringEncoding]];[file closeFile];file=nil;
            unsigned long long size=[[fm attributesOfItemAtPath:self.diagnosticLogPath error:NULL] fileSize];
            if(size>512*1024){
                file=[NSFileHandle fileHandleForReadingAtPath:self.diagnosticLogPath];[file seekToFileOffset:size-256*1024];
                NSData *tail=[file readDataOfLength:256*1024];[file closeFile];file=nil;
                NSData *newline=[@"\n" dataUsingEncoding:NSUTF8StringEncoding];
                NSRange boundary=[tail rangeOfData:newline options:0 range:NSMakeRange(0,tail.length)];
                if(boundary.location!=NSNotFound){NSUInteger start=NSMaxRange(boundary);[[tail subdataWithRange:NSMakeRange(start,tail.length-start)] writeToFile:self.diagnosticLogPath atomically:YES];}
            }
        } @catch(NSException *exception){NSLog(@"[CCTVHost] diagnostic log write failed: %@",exception.name);}
        @finally {
            @try{[file closeFile];}@catch(NSException *exception){}
            BOOL hasPending=NO;
            @synchronized(self.pendingLogWrites){self.diagnosticWriteInProgress=NO;hasPending=self.pendingLogWrites.length>0;}
            if(hasPending)[self scheduleDiagnosticLogFlush];
        }
    }});
}
- (void)log:(NSString *)format, ... {
    va_list ap;va_start(ap,format);NSString *msg=[[NSString alloc] initWithFormat:format arguments:ap];va_end(ap);
    msg=[HostLogRedactor redactText:msg];
    if(msg.length>4096){NSUInteger end=4096;unichar last=[msg characterAtIndex:end-1];if(last>=0xd800 && last<=0xdbff)end--;msg=[[msg substringToIndex:end] stringByAppendingString:@"… [日志已截断]"];}
    [self persistDiagnosticLine:[NSString stringWithFormat:@"[%@] %@\n",NSDate.date.description,msg]];
    // One pending UI delivery for all producers, rather than one main-queue
    // block per Python print(). The bounded tail survives a blocked UI thread.
    if(![self.pendingLogDisplay append:[msg stringByAppendingString:@"\n"]])return;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        RootViewController *owner=weakSelf;if(!owner)return;
        NSString *batch=[owner.pendingLogDisplay drain];if(!batch.length)return;
        [owner.logBuffer appendString:batch];
        if(owner.logBuffer.length>20000){NSUInteger remove=owner.logBuffer.length-16000;unichar next=[owner.logBuffer characterAtIndex:remove];if(next>=0xdc00 && next<=0xdfff)remove++;[owner.logBuffer deleteCharactersInRange:NSMakeRange(0,remove)];}
        NSString *summary=[[batch stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"].lastObject?:@"";
        NSLog(@"[CCTVHost] %@",summary);
        [[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
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
    self.infoLabel.text = [NSString stringWithFormat:@"版本 %@", CCTVBuildTag()];
    [self.playerBox addSubview:self.infoLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.center = CGPointMake(w / 2, h / 2);
    self.spinner.hidesWhenStopped = YES;
    [self.playerBox addSubview:self.spinner];

    self.playerChannelLogo=[UIImageView new];
    self.playerChannelLogo.contentMode=UIViewContentModeScaleAspectFit;
    self.playerChannelLogo.hidden=YES;
    self.playerChannelLogo.accessibilityLabel=@"当前频道台标";
    [self.playerBox addSubview:self.playerChannelLogo];

    self.controlBar = [[UIStackView alloc] initWithFrame:CGRectMake(8, h - 36, w - 16, 28)];
    self.controlBar.axis = UILayoutConstraintAxisHorizontal;
    self.controlBar.distribution = UIStackViewDistributionFillEqually;
    self.controlBar.spacing = 5;
    self.playPauseBtn = [self barButton:@"暂停" action:@selector(togglePlayPause)];
    self.muteBtn = [self barButton:@"静音" action:@selector(toggleMute)];
    self.routeBtn = [self barButton:@"线路" action:@selector(showRoutes)];
    self.epgBtn = [self barButton:@"节目单" action:@selector(openEPG)];
    self.fullBtn = [self barButton:@"全屏" action:@selector(toggleFullscreen)];
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
    self.groupControl.tintColor = HostAccent();
    [self.groupControl addTarget:self action:@selector(onGroupChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.groupControl];
    self.playerTabs=[[UISegmentedControl alloc] initWithItems:@[@"分类",@"频道",@"节目",@"线路"]];self.playerTabs.selectedSegmentIndex=1;self.playerTabs.selectedSegmentTintColor=HostAccent();[self.playerTabs addTarget:self action:@selector(selectPlayerPanel) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.playerTabs];

    self.versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, y + 38, self.view.bounds.size.width - 16, 14)];
    self.versionLabel.textColor = HostSecondaryText();
    self.versionLabel.font = [UIFont systemFontOfSize:9];
    self.versionLabel.text = [NSString stringWithFormat:@"%@ · 点击自动播放 · 长按选线路", CCTVBuildTag()];
    [self.view addSubview:self.versionLabel];

    CGFloat ty = y + 54;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, ty, self.view.bounds.size.width, self.view.bounds.size.height - ty) style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 58;
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
    [self.view addSubview:self.table];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;
    UILongPressGestureRecognizer *routePress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.table addGestureRecognizer:routePress];
    UICollectionViewFlowLayout *flow=[UICollectionViewFlowLayout new]; flow.minimumInteritemSpacing=8; flow.minimumLineSpacing=10; flow.sectionInset=UIEdgeInsetsMake(8,12,16,12);
    self.channelGrid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:flow]; self.channelGrid.backgroundColor=HostBackground(); self.channelGrid.dataSource=self; self.channelGrid.delegate=self; self.channelGrid.accessibilityIdentifier=@"channel.grid";
    [self.channelGrid registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"channel.card"]; [self.view addSubview:self.channelGrid];
    UIRefreshControl *gridRefresh=[UIRefreshControl new];[gridRefresh addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];self.channelGrid.refreshControl=gridRefresh;
    [self buildBottomBar];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索频道";
    self.navigationItem.searchController = self.searchController;
    self.definesPresentationContext = YES;

}

- (void)openDiagnosticLog {
    [self openDiagnosticLogForIdentifier:nil name:nil];
}
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name {
    if(!line.length||!identifier.length)return;
    [PluginLogStore.shared appendLine:line forIdentifier:identifier];
    NSDictionary *relayRecord=MediaRelayDiagnosticRecord(line);
    if(relayRecord){NSMutableDictionary *fields=[relayRecord mutableCopy];NSString *event=fields[@"event"];[fields removeObjectForKey:@"event"];fields[@"service_id"]=identifier;if(fields[@"request_id"])fields[@"correlation_id"]=fields[@"request_id"];[RuntimeDiagnostics.shared recordEvent:event category:[event hasPrefix:@"media_play_"]?@"media_api":@"media_relay" fields:fields];}

    dispatch_async(dispatch_get_main_queue(),^{[[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:identifier];});
    [self log:@"[%@] %@",name.length?name:@"插件",line];
}
- (void)clearServiceLogHandlers:(NSString *)identifier {
    if(!identifier.length)return;
    [PyHost setLogHandler:nil forServiceIdentifier:identifier];
    [NodePluginRuntime.shared setLogHandler:nil forServiceIdentifier:identifier];
    [JSPluginRuntime.shared setLogHandler:nil forServiceIdentifier:identifier];
}
- (void)openDiagnosticLogForIdentifier:(NSString *)identifier name:(NSString *)name {
    if(identifier.length){
        PluginRunHistoryViewController *history=[PluginRunHistoryViewController new];history.serviceName=name;__weak typeof(self) weakSelf=self;NSString *scope=[identifier copy];NSString *scopeName=[name copy];
        history.runRecordsProvider=^NSArray<NSDictionary *> *{if(![weakSelf.serviceOperations containsObject:scope]&&![PyHost isManagedServiceIdentifier:scope])[PluginLogStore.shared markUnmanagedRunsInterruptedForIdentifier:scope];return [PluginLogStore.shared runsForIdentifier:scope];};
        history.onSelectRun=^(NSDictionary *run){[weakSelf openPluginRunLogForIdentifier:scope name:scopeName?:@"服务" run:run];};
        history.onExportAll=^{[PluginLogStore.shared prepareExportForIdentifier:scope displayName:scopeName?:@"插件" completion:^(NSURL *url,NSError *error){if(!url){[weakSelf showServiceError:error.localizedDescription?:@"该脚本还没有可导出的日志。"];return;}[weakSelf shareDiagnosticLogAtURL:url];}];};
        history.onClearAll=^{[PluginLogStore.shared clearLogForIdentifier:scope completion:^{[[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:scope];}];};
        UIViewController *presented=self.presentedViewController;if(presented)[presented dismissViewControllerAnimated:YES completion:^{[weakSelf.navigationController pushViewController:history animated:YES];}];else[self.navigationController pushViewController:history animated:YES];return;
    }
    LogCenterViewController *page=[LogCenterViewController new];page.scopeName=name;
    __weak typeof(self) weakSelf=self;
    page.logSnapshotProvider=^{return weakSelf.logBuffer.copy?:@"";};
    page.onExportLog=^{[weakSelf exportDiagnosticLog];};
    page.onClearLog=^{[weakSelf clearDiagnosticLog];};
    UIViewController *presented=self.presentedViewController;
    if(presented){[presented dismissViewControllerAnimated:YES completion:^{[weakSelf.navigationController pushViewController:page animated:YES];}];}
    else [self.navigationController pushViewController:page animated:YES];
}
- (void)openPluginRunLogForIdentifier:(NSString *)identifier name:(NSString *)name run:(NSDictionary *)run {
    NSString *runID=[run[@"runID"] isKindOfClass:NSString.class]?run[@"runID"]:@"";if(!identifier.length||!runID.length)return;LogCenterViewController *page=[LogCenterViewController new];page.scopeName=name;NSString *runTitle=[run[@"legacy"] boolValue]?@"历史日志":[NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[run[@"startedAt"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];page.titleOverride=[NSString stringWithFormat:@"%@ · %@",name.length?name:@"服务",runTitle];page.clearActionTitle=@"清空本次日志";page.clearConfirmationMessage=@"只清理这一次运行的日志，不影响其他运行记录、服务代码或配置。服务仍在运行时，后续日志会继续写入本次记录。";
    __weak typeof(self) weakSelf=self;NSString *scope=[identifier copy];NSString *selectedRun=[runID copy];NSString *scopeName=[name copy];page.logSnapshotProvider=^NSString *{return [PluginLogStore.shared logForIdentifier:scope runID:selectedRun];};page.onExportLog=^{[PluginLogStore.shared prepareExportForIdentifier:scope runID:selectedRun displayName:scopeName?:@"插件" completion:^(NSURL *url,NSError *error){if(!url){[weakSelf showServiceError:error.localizedDescription?:@"该次运行还没有可导出的日志。"];return;}[weakSelf shareDiagnosticLogAtURL:url];}];};page.onClearLog=^{[PluginLogStore.shared clearRunForIdentifier:scope runID:selectedRun completion:^{[[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:scope];}];};[self.navigationController pushViewController:page animated:YES];
}

- (void)shareDiagnosticLogAtURL:(NSURL *)source {
    UIViewController *top=self.navigationController.topViewController?:self;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[source] applicationActivities:nil];
    UIPopoverPresentationController *pop=share.popoverPresentationController;
    if(pop){pop.barButtonItem=top.navigationItem.rightBarButtonItem;if(!pop.barButtonItem){pop.sourceView=top.view;pop.sourceRect=CGRectMake(CGRectGetMidX(top.view.bounds),CGRectGetMidY(top.view.bounds),1,1);}}
    [top presentViewController:share animated:YES completion:nil];
}
- (void)exportDiagnosticLog {
    [self flushDiagnosticLog];
    dispatch_async(self.diagnosticLogQueue, ^{
        NSString *stored=[NSString stringWithContentsOfFile:self.diagnosticLogPath encoding:NSUTF8StringEncoding error:NULL]?:@"";
        NSString *safe=[HostLogRedactor redactText:stored];
        NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"CCTVHost-总日志-脱敏.txt"];
        [safe writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSURL *source=[NSURL fileURLWithPath:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![NSFileManager.defaultManager fileExistsAtPath:source.path]) { [self log:@"日志文件尚未生成"]; return; }
            [self shareDiagnosticLogAtURL:source];
        });
    });
}
- (void)clearDiagnosticLog {
    [self.pendingLogDisplay clear];
    [self.logBuffer setString:@""];
    @synchronized (self.pendingLogWrites) { self.diagnosticLogGeneration++; [self.pendingLogWrites clear]; }
    dispatch_async(self.diagnosticLogQueue, ^{ [@"" writeToFile:self.diagnosticLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; });
    [[NSNotificationCenter defaultCenter] postNotificationName:CCTVHostDiagnosticLogDidUpdateNotification object:nil];
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
    NSMutableDictionary *unique=[NSMutableDictionary dictionary];NSMutableArray *dedup=[NSMutableArray array];for(NSDictionary *c in self.allChannels){NSString *cid=c[@"id"];NSNumber *index=unique[cid];if(index){NSMutableDictionary *existing=[dedup[index.unsignedIntegerValue] mutableCopy];NSMutableSet *owners=[NSMutableSet setWithArray:existing[@"subscriptionSources"]?:@[]];[owners addObjectsFromArray:c[@"subscriptionSources"]?:@[]];if(owners.count)existing[@"subscriptionSources"]=owners.allObjects;dedup[index.unsignedIntegerValue]=existing;}else{unique[cid]=@(dedup.count);[dedup addObject:c];}}self.allChannels=dedup;
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
    action.backgroundColor = fav ? HostRaisedSurface() : [UIColor systemOrangeColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

- (void)onGroupChanged {
    self.favoritesOnly=NO;
    [self updateBottomBarSelection];
    [self configureCatalogNavigation];[self applyFilter];
}

- (void)buildBottomBar {
    self.bottomBarBackdrop=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];self.bottomBarBackdrop.userInteractionEnabled=NO;self.bottomBarBackdrop.layer.cornerRadius=29;self.bottomBarBackdrop.layer.cornerCurve=kCACornerCurveContinuous;self.bottomBarBackdrop.clipsToBounds=YES;self.bottomBarBackdrop.layer.borderWidth=0.7;HostSetLayerBorderColor(self.bottomBarBackdrop,HostBorder());
    UIView *glassTint=[[UIView alloc] initWithFrame:self.bottomBarBackdrop.contentView.bounds];glassTint.backgroundColor=HostGlassTint();glassTint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.bottomBarBackdrop.contentView addSubview:glassTint];
    [self.view addSubview:self.bottomBarBackdrop];
    self.bottomBar=[[UIStackView alloc] init]; self.bottomBar.axis=UILayoutConstraintAxisHorizontal; self.bottomBar.distribution=UIStackViewDistributionFillEqually; self.bottomBar.spacing=3; self.bottomBar.backgroundColor=UIColor.clearColor; self.bottomBar.layer.cornerRadius=29; self.bottomBar.layer.cornerCurve=kCACornerCurveContinuous; self.bottomBar.clipsToBounds=YES;
    NSArray *titles=@[@"CCTV",@"频道",@"首页",@"资源",@"设置"];
    NSArray *icons=@[@"tv.fill",@"play.rectangle.on.rectangle",@"house.fill",@"externaldrive.fill",@"gearshape"];
    for (NSInteger i=0;i<titles.count;i++) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=i;HostInstallPressFeedback(b);
        UIButtonConfiguration *cfg=[UIButtonConfiguration plainButtonConfiguration]; cfg.title=titles[i]; cfg.image=[UIImage systemImageNamed:icons[i]]; cfg.imagePlacement=NSDirectionalRectEdgeTop; cfg.imagePadding=3; cfg.cornerStyle=UIButtonConfigurationCornerStyleCapsule; cfg.contentInsets=NSDirectionalEdgeInsetsMake(6,3,6,3); cfg.baseForegroundColor=(i==0?HostAccent():HostMutedText()); cfg.background.backgroundColor=i==0?[HostAccent() colorWithAlphaComponent:0.20]:UIColor.clearColor; cfg.titleTextAttributesTransformer=^(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];return result;}; b.configuration=cfg;
        b.accessibilityLabel=titles[i]; b.accessibilityIdentifier=[NSString stringWithFormat:@"tab.%@",titles[i]];
        b.accessibilityHint=[NSString stringWithFormat:@"切换到%@页面",titles[i]];
        [b addTarget:self action:@selector(bottomTabTapped:) forControlEvents:UIControlEventTouchUpInside]; [self.bottomBar addArrangedSubview:b];
    }
    [self.view addSubview:self.bottomBar];
    [self updateBottomBarSelection];
}

- (void)bottomTabTapped:(UIButton *)sender {
    self.userInitiatedTabSelection=YES;
    [self selectBottomTab:sender];
    self.userInitiatedTabSelection=NO;
}

- (void)updateBottomBarSelection {
    for (UIButton *button in self.bottomBar.arrangedSubviews) {
        UIButtonConfiguration *configuration=button.configuration;
        BOOL selected=button.tag==self.activeTab;
        configuration.baseForegroundColor=selected?HostAccent():HostMutedText();
        configuration.background.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.20]:UIColor.clearColor;
        configuration.background.strokeColor=selected?[HostAccent() colorWithAlphaComponent:0.30]:UIColor.clearColor;
        configuration.background.strokeWidth=selected?0.6:0;
        button.configuration=configuration;
    }
}

- (void)selectBottomTab:(UIButton *)sender {
    self.catalogSearchGeneration++;
    [self stopPreview];
    if(!self.restoringLastTab&&self.activeTab<2){NSDictionary *state=@{@"query":self.query?:@"",@"group":@(self.groupControl.selectedSegmentIndex),@"gridY":@(self.channelGrid.contentOffset.y),@"listY":@(self.table.contentOffset.y)};self.catalogStates[@(self.activeTab)]=state;[[NSUserDefaults standardUserDefaults] setObject:state forKey:[NSString stringWithFormat:@"cctv.catalogState.%ld",(long)self.activeTab]];}
    if(self.restoringLastTab)[RuntimeDiagnostics.shared recordEvent:@"ui_session_tab_restored" category:@"lifecycle" fields:@{@"tab_index":@(sender.tag),@"automatic_content_load":@NO}];
    self.activeTab=sender.tag;
    [[NSUserDefaults standardUserDefaults] setInteger:self.activeTab forKey:@"cctv.lastBottomTab.v1"];
    [self updateBottomBarSelection];
    if([self.tabPage isKindOfClass:MediaBrowserViewController.class])[(MediaBrowserViewController *)self.tabPage saveSessionState];
    if(self.tabPage){[self.tabPage willMoveToParentViewController:nil];[self.tabPage.view removeFromSuperview];[self.tabPage removeFromParentViewController];self.tabPage=nil;}
    if(sender.tag==2){ [self openMediaTab]; }
    else if(sender.tag==3){ [self openConfigurationTab]; }
    else if(sender.tag==4){ SettingsViewController *page=(SettingsViewController *)self.tabPages[@4];if(!page){page=[self makeSettingsPage];self.tabPages[@4]=page;}[self showTabPage:page title:@"设置"]; }
    else {self.favoritesOnly=NO;if(sender.tag<2)self.subscriptionCatalog=sender.tag==1;self.activeSource=nil;self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];NSDictionary *state=self.catalogStates[@(sender.tag)];self.query=state[@"query"]?:@"";self.searchController.searchBar.text=self.query;self.groupControl.selectedSegmentIndex=[state[@"group"] integerValue];[self configureCatalogNavigation];[self applyFilter];[self.view layoutIfNeeded];self.channelGrid.contentOffset=CGPointMake(0,[state[@"gridY"] doubleValue]);self.table.contentOffset=CGPointMake(0,[state[@"listY"] doubleValue]);
        if(sender.tag==1&&!self.channelID.length&&self.userInitiatedTabSelection&&!self.restoringLastTab)[self refreshSubscriptionsWhenIdle];}
    [self.view setNeedsLayout];
}

- (void)configureCatalogNavigation {
    BOOL expandedLive=self.playerExpanded&&self.activeTab<2&&!self.favoritesOnly&&self.channelID.length&&((self.activeTab==0&&!self.currentRemoteURL.length)||(self.activeTab==1&&self.currentRemoteURL.length));
    self.title=expandedLive?(self.channelName?:@"直播"):(self.favoritesOnly?@"收藏频道":(self.subscriptionCatalog?@"频道":@"CCTV"));
    self.navigationItem.largeTitleDisplayMode=expandedLive?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.searchController=self.searchController; self.navigationItem.hidesSearchBarWhenScrolling=NO;
    __weak typeof(self) w=self;
    if(expandedLive){
        BOOL favorite=[self.favorites containsObject:self.channelID];
        AVRoutePickerView *airPlayPicker=[AVRoutePickerView new];airPlayPicker.tintColor=HostText();airPlayPicker.activeTintColor=HostAccent();airPlayPicker.prioritizesVideoDevices=YES;
        self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
            @{@"icon":favorite?@"heart.fill":@"heart",@"title":favorite?@"取消收藏当前频道":@"收藏当前频道",@"action":[UIAction actionWithHandler:^(UIAction *a){[w toggleCurrentFavorite];}]},
            @{@"customView":airPlayPicker,@"title":@"投屏到 AirPlay 设备",@"identifier":@"playback.airplay"},
            @{@"icon":@"info.circle",@"title":@"播放信息",@"action":[UIAction actionWithHandler:^(UIAction *a){[w showPlaybackInfo];}]}
        ])];
    }else{
        self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
            @{@"icon":@"square.grid.2x2",@"title":@"列表与网格",@"action":[UIAction actionWithHandler:^(UIAction *a){w.gridMode=!w.gridMode;[NSUserDefaults.standardUserDefaults setBool:w.gridMode forKey:@"channelGridMode"];[w.view setNeedsLayout];}]},
            @{@"icon":@"arrow.clockwise",@"title":@"刷新当前页面",@"action":[UIAction actionWithHandler:^(UIAction *a){[w onPullRefresh];}]},
            @{@"icon":@"ellipsis",@"title":@"更多",@"menu":[self catalogMenu]}
        ])];
    }
    NSInteger groupIndex=self.groupControl.selectedSegmentIndex;
    NSString *groupTitle=groupIndex>=0&&groupIndex<self.groupControl.numberOfSegments?[self.groupControl titleForSegmentAtIndex:groupIndex]:@"全部";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ ▾",groupTitle] style:UIBarButtonItemStylePlain target:self action:@selector(showGroupMenu)];
}
- (void)toggleCurrentFavorite {
    if(!self.channelID.length)return;
    if([self.favorites containsObject:self.channelID])[self.favorites removeObject:self.channelID];
    else [self.favorites addObject:self.channelID];
    [NSUserDefaults.standardUserDefaults setObject:self.favorites forKey:@"favorites"];
    [self configureCatalogNavigation];[self applyFilter];
}
- (UIMenu *)catalogMenu {
    __weak typeof(self) w=self;
    UIAction *grid=[UIAction actionWithTitle:self.gridMode?@"切换列表样式":@"切换网格样式" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction *a){w.gridMode=!w.gridMode;[NSUserDefaults.standardUserDefaults setBool:w.gridMode forKey:@"channelGridMode"];[w configureCatalogNavigation];[w.view setNeedsLayout];}];
    UIAction *refresh=[UIAction actionWithTitle:@"刷新播放列表" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){[w onPullRefresh];}];
    UIAction *add=[UIAction actionWithTitle:@"添加订阅" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *a){[w addSubscription];}];
    UIAction *hide=[UIAction actionWithTitle:self.playerExpanded?@"收起播放器":@"展开播放器" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){w.playerExpanded=!w.playerExpanded;[w configureCatalogNavigation];[w.view setNeedsLayout];}];
    UIAction *history=[UIAction actionWithTitle:@"最近观看" image:[UIImage systemImageNamed:@"clock"] identifier:nil handler:^(UIAction *a){[w showHistory];}];
    UIAction *playing=[UIAction actionWithTitle:@"返回正在播放" image:[UIImage systemImageNamed:@"play.circle"] identifier:nil handler:^(UIAction *a){if(!w.channelID.length)return;[w selectBottomTab:(id)w.bottomBar.arrangedSubviews[w.currentRemoteURL.length?1:0]];w.playerExpanded=YES;[w.view setNeedsLayout];}];
    UIAction *manage=[UIAction actionWithTitle:@"整理收藏" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){[w showFavoriteManager];}];
    UIAction *favorites=[UIAction actionWithTitle:self.favoritesOnly?@"显示全部频道":@"查看收藏频道" image:[UIImage systemImageNamed:@"heart.fill"] identifier:nil handler:^(UIAction *a){w.favoritesOnly=!w.favoritesOnly;[w configureCatalogNavigation];[w applyFilter];}];
    return [UIMenu menuWithTitle:@"" children:self.subscriptionCatalog?@[grid,refresh,add,hide,playing,history,favorites,manage]:@[grid,hide,playing,history,favorites,manage]];
}
- (void)showGroupMenu {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"频道分组" message:@"按频道类型筛选当前列表" preferredStyle:UIAlertControllerStyleActionSheet];NSInteger selected=self.groupControl.selectedSegmentIndex;
    for(NSUInteger i=0;i<self.groupControl.numberOfSegments;i++){NSString *group=[self.groupControl titleForSegmentAtIndex:i]?:@"全部";NSString *title=(NSInteger)i==selected?[NSString stringWithFormat:@"✓  %@",group]:group;[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.groupControl.selectedSegmentIndex=i;[self onGroupChanged];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.barButtonItem=self.navigationItem.leftBarButtonItem;[self presentViewController:a animated:YES completion:nil];
}
- (void)showTabPage:(UIViewController *)page title:(NSString *)title {
    BOOL media=[page isKindOfClass:MediaBrowserViewController.class];self.navigationItem.largeTitleDisplayMode=media?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    self.tabPage=page;if(page.parentViewController!=self){[self addChildViewController:page];[self.view addSubview:page.view];[page didMoveToParentViewController:self];}else if(page.view.superview!=self.view)[self.view addSubview:page.view];self.title=media?(((MediaBrowserViewController *)page).isHomeMode?@"":@"影视库"):title;self.navigationItem.searchController=page.navigationItem.searchController;self.navigationItem.leftBarButtonItem=nil;
    self.navigationItem.rightBarButtonItems=page.navigationItem.rightBarButtonItems;[self.view bringSubviewToFront:self.bottomBarBackdrop];[self.view bringSubviewToFront:self.bottomBar];
}
- (void)openMediaTab {
    MediaBrowserViewController *page=(MediaBrowserViewController *)self.tabPages[@2];
    BOOL created=page==nil;
    if(!page){page=[MediaBrowserViewController new];page.deferAutomaticLoading=YES;__weak typeof(self) weakSelf=self;
        page.sourcesProvider=^{
            NSMutableArray *sources=[NSMutableArray array];
            for(NSDictionary *service in [ServiceStore services])if([ServiceStore isVODMediaService:service])[sources addObject:service];
            for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){
                NSString *catalogID=catalog[@"id"]?:@"";
                NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];
                for(NSDictionary *site in sites){
                    NSString *apiKind=[site[@"apiKind"] isKindOfClass:NSString.class]?site[@"apiKind"]:@"";
                    if(!([apiKind isEqual:@"tvbox-api"]||[apiKind isEqual:@"maccms-api"])||![site[@"supported"] boolValue])continue;
                    NSString *protocol=apiKind,*siteID=[NSString stringWithFormat:@"%@:%@:%@",protocol,catalogID,site[@"key"]?:@""];
                    NSString *type=site[@"type"]?:@"1";
                    NSString *engine=[apiKind isEqual:@"maccms-api"]?@"MacCMS JSON/XML API":[NSString stringWithFormat:@"TVBox type %@ JSON API",type];
                    NSMutableDictionary *source=[@{@"id":siteID,@"name":site[@"name"]?:@"影视来源",@"engine":engine,@"protocol":protocol,@"tvboxType":@([type integerValue]),@"api":site[@"api"]?:@"",@"url":site[@"api"]?:@"",@"options":site[@"ext"]?:@"",@"header":site[@"header"]?:@{},@"playUrl":site[@"playUrl"]?:@"",@"status":site[@"status"]?:@"可直接访问",@"catalogID":catalogID,@"catalogName":catalog[@"name"]?:@"资源合集",@"capabilities":@[@"home",@"category",@"search",@"detail",@"play"]} mutableCopy];
                    [sources addObject:source];
                }
            }
            return sources;
        };
        __weak MediaBrowserViewController *weakPage=page;page.onDisplayModeChanged=^(BOOL homeMode){RootViewController *owner=weakSelf;MediaBrowserViewController *mediaPage=weakPage;if(!owner||!mediaPage)return;owner.title=homeMode?@"":@"影视库";owner.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;owner.navigationItem.searchController=mediaPage.navigationItem.searchController;owner.navigationItem.leftBarButtonItem=mediaPage.navigationItem.leftBarButtonItem;owner.navigationItem.rightBarButtonItems=mediaPage.navigationItem.rightBarButtonItems;};
        page.onActivateService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf changeService:service enabled:YES completion:completion];};
        page.onRestartService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf restartMediaService:service completion:completion];};
        page.startupErrorProvider=^NSError *{return PyHost.startupError;};
        page.startupErrorForService=^NSError *(NSDictionary *service){return [PyHost startupErrorForServiceIdentifier:service[@"id"]];};
        page.onResources=^{RootViewController *owner=weakSelf;if(owner)[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[3]];};
        page.onPlay=^(NSDictionary *result,NSDictionary *context){RootViewController *owner=weakSelf;if(!owner)return;MediaPlaybackViewController *player=[MediaPlaybackViewController new];player.result=result;player.context=context;[owner.navigationController pushViewController:player animated:YES];};
        page.onSubscribeLive=^(NSDictionary *service){RootViewController *owner=weakSelf;if(!owner)return;NSString *url=[ServiceStore subscriptionURLForService:service];if(!url.length)for(NSString *candidate in owner.subscriptionURLs){NSDictionary *provider=[owner localServiceForURL:[NSURL URLWithString:candidate]];if([provider[@"id"] isEqual:service[@"id"]]){url=candidate;break;}}if(!url.length){[owner openServiceEditorForService:service];return;}NSMutableDictionary *metadata=[@{@"managedServiceID":service[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:url][@"name"])[metadata addEntriesFromDictionary:@{@"name":service[@"name"]?:@"本机直播服务"}];[ProfileStore update:url values:metadata];if(![owner.subscriptionURLs containsObject:url]){[owner.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:owner.subscriptionURLs.allObjects forKey:@"subscriptions"];}[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[1]];owner.activeSource=url;owner.title=@"订阅直播";[owner fetchSubscription:url silent:NO];};
        self.tabPages[@2]=page;
    }
    [self showTabPage:page title:page.isHomeMode?@"":@"影视库"];
    if(page.onDisplayModeChanged)page.onDisplayModeChanged(page.isHomeMode);
    if(!created){if(self.userInitiatedTabSelection)[page returnToHomeFromNavigation];[page refreshSources];}
}
- (void)playMediaResult:(NSDictionary *)result name:(NSString *)name {
    NSString *url=[self stableURLKey:result[@"url"]];if(!url.length){[self showServiceError:@"资源没有返回可播放媒体地址"];return;}
    self.playbackGeneration++;[self stopPlayback];[self.nativePreloader cancel];[self endPlaybackPriority];
    self.currentRemoteURL=url;self.channelName=name;self.channelID=nil;
    NSString *sourceURL=[self stableURLKey:result[@"originalURL"]?:result[@"url"]];
    BOOL directMedia=MediaPlaybackResultSupportsAVPlayer(result)||MediaPlaybackResultSupportsAVPlayer(@{@"url":sourceURL?:@""});
    [RuntimeDiagnostics.shared recordEvent:@"media_playback_handoff" category:@"playback" fields:@{@"player":([result[@"parse"] integerValue]>0&&!directMedia)?@"webview":@"avplayer", @"parsed":@([result[@"parse"] integerValue]>0)}];
    BOOL requiresWebPlayback=[result[@"requiresWebPlayback"] boolValue]||[result[@"parse"] integerValue]>0||[result[@"jx"] integerValue]>0;if(requiresWebPlayback&&!directMedia){MediaWebViewController *page=[[MediaWebViewController alloc] initWithResult:result title:name];UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];UIViewController *presenter=self.navigationController.topViewController?:self;[presenter presentViewController:navigation animated:YES completion:nil];return;}
    NSDictionary *headers=MediaPlaybackHeadersFromResult(result);NSURL *resolvedURL=[NSURL URLWithString:url];NSString *resolvedHost=resolvedURL.host.lowercaseString?:@"";BOOL localRelay=![sourceURL isEqualToString:url]&&[@[@"127.0.0.1",@"localhost",@"::1"] containsObject:resolvedHost];if(localRelay)headers=@{};
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:resolvedURL options:headers.count?@{@"AVURLAssetHTTPHeaderFieldsKey":headers}:nil];AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];
    AVMutableMetadataItem *title=[AVMutableMetadataItem metadataItem];title.identifier=AVMetadataCommonIdentifierTitle;title.value=name?:@"影视";title.extendedLanguageTag=@"und";item.externalMetadata=@[title];
    self.moviePlayer=[AVPlayer playerWithPlayerItem:item];self.moviePlayer.automaticallyWaitsToMinimizeStalling=YES;
    self.movieController=[AVPlayerViewController new];self.movieController.player=self.moviePlayer;self.movieController.delegate=self;self.movieController.allowsPictureInPicturePlayback=YES;
    UIViewController *presenter=self.navigationController.topViewController?:self;[presenter presentViewController:self.movieController animated:YES completion:^{[self.moviePlayer play];}];
}
- (void)playerViewController:(AVPlayerViewController *)controller willEndFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(controller==self.movieController && !self.moviePiPActive)[self.moviePlayer pause];}];
}
- (void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController *)controller {if(controller==self.movieController)self.moviePiPActive=YES;}
- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController *)controller {if(controller==self.movieController){self.moviePiPActive=NO;if(!controller.presentingViewController)[self.moviePlayer pause];}}
- (void)openConfigurationTab {
    ConfigCenterViewController *page=(ConfigCenterViewController *)self.tabPages[@3];
    if(!page){page=[ConfigCenterViewController new];__weak typeof(self) w=self;
        page.profilesProvider=^{return [(id)w configurationProfiles];};page.onServices=^{[w openServicesPage];};page.onAdd=^{[w addSubscription];};page.onRefresh=^{[w onPullRefresh];};page.onRefreshProfile=^(NSString *source){[w fetchSubscription:source silent:NO];};
        page.onRefreshMediaHome=^{RootViewController *owner=w;if(!owner)return;[owner selectBottomTab:(UIButton *)owner.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser returnToHomeFromNavigation];dispatch_async(dispatch_get_main_queue(),^{if(![browser refreshHomeContentFromResourcePage])[owner showServiceError:@"没有可加载的影视资源。请先导入并启用一个影视来源。"] ;});};
        page.onToggleProfile=^(NSString *source,BOOL enabled){NSDictionary *service=[w resourceServiceForSource:source];if(service){[w toggleService:service enabled:enabled];return;}if(!source.length)[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"nativeChannelsEnabled"];else{NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabled removeObject:source];if(!enabled)[disabled addObject:source];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}[w applyFilter];};
        page.onOpenResource=^(NSString *source){[w openPluginResource:source];};
        page.onUseResource=^(NSString *source,NSString *kind){NSDictionary *service=[w resourceServiceForSource:source];if(!service)return;if([kind isEqual:@"choose"]){UIAlertController *choice=[UIAlertController alertControllerWithTitle:service[@"name"]?:@"选择资源用途" message:@"这个资源同时提供影视与直播能力。" preferredStyle:UIAlertControllerStyleActionSheet];[choice addAction:[UIAlertAction actionWithTitle:@"进入影视" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[w usePluginService:service kind:@"vod"];}]];[choice addAction:[UIAlertAction actionWithTitle:@"添加直播频道" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[w usePluginService:service kind:@"live"];}]];[choice addAction:[UIAlertAction actionWithTitle:@"资源详情与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[w openPluginResource:source];}]];[choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];choice.popoverPresentationController.sourceView=w.view;choice.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(w.view.bounds),CGRectGetMidY(w.view.bounds),1,1);[w presentViewController:choice animated:YES completion:nil];return;}[w usePluginService:service kind:kind];};
        page.onOpenTVBoxCatalog=^(NSString *identifier){[w openTVBoxCatalog:identifier];};
        page.onSelectProfile=^(NSString *source){UIButton *b=(UIButton *)w.bottomBar.arrangedSubviews[source.length?1:0];[w selectBottomTab:b];w.activeSource=source;w.title=source.length?@"订阅直播":@"央视直播";[w applyFilter];};
        page.onEditProfile=^(NSString *source){NSDictionary *service=[w resourceServiceForSource:source];if(service)[w openServiceEditorForService:service];else[w editProfile:source];};
        page.onDeleteProfile=^(NSString *source){if([source hasPrefix:@"tvbox:"]){[TVBoxCatalogStore removeCatalog:[source substringFromIndex:6]];[w refreshConfigurationPage];return;}NSDictionary *service=[w resourceServiceForSource:source];if(service){if([PyHost isManagedServiceIdentifier:service[@"id"]]){[w showServiceError:@"该资源仍有运行或待清理会话，请先停止"];return;}[ServiceStore remove:service[@"id"]];}else[w deleteSubscription:source];};
        self.tabPages[@3]=page;
    }
    [self showTabPage:page title:@"资源"];
}
- (NSDictionary *)resourceServiceForSource:(NSString *)source {if(![source hasPrefix:@"plugin:"])return nil;NSString *identifier=[source substringFromIndex:7];for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:identifier])return service;return nil;}
- (NSArray *)configurationProfiles {
    NSMutableArray *rows=[NSMutableArray array];NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary dictionary];NSUInteger native=0;
    for(NSDictionary *channel in self.allChannels){if(![channel[@"remoteURL"] length])native++;for(NSString *source in [NSSet setWithArray:channel[@"subscriptionSources"]?:@[]])counts[source]=@([counts[source] unsignedIntegerValue]+1);}
    [rows addObject:@{@"name":@"央视直播 · 官方频道",@"source":@"",@"resourceKind":@"live",@"native":@YES,@"current":@(!self.activeSource.length),@"epgStatus":@"官方",@"count":@(native),@"enabled":@(CCTVBoolPreference(@"nativeChannelsEnabled",YES))}];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    for(NSString *u in [ProfileStore orderedSources:self.subscriptionURLs.allObjects]){NSDictionary *metadata=[ProfileStore metadata:u];NSMutableDictionary *row=[@{@"name":metadata[@"name"]?:[NSURL URLWithString:u].host?:@"本地播放列表",@"status":metadata[@"status"]?:@"等待刷新",@"resourceKind":@"live",@"current":@([self.activeSource isEqual:u]),@"epgStatus":(metadata[@"epgURL"]?:metadata[@"detectedEPGURL"])?@"已配置":@"自动匹配",@"source":u,@"count":counts[u]?:@0,@"enabled":@(![disabled containsObject:u])} mutableCopy];if(metadata[@"updatedAt"])row[@"updatedAt"]=metadata[@"updatedAt"];[rows addObject:row];}
    NSString *selectedMedia=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"]?:@"";
    for(NSDictionary *service in [ServiceStore services])if(![service[@"builtin"] boolValue]){
        BOOL enabled=[PyHost isRunningServiceIdentifier:service[@"id"]];NSArray *caps=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:@[];
        NSString *subscriptionURL=[ServiceStore subscriptionURLForService:service]?:@"",*epgURL=[ServiceStore epgURLForService:service]?:@"";
        NSDictionary *playlistMetadata=subscriptionURL.length?[ProfileStore metadata:subscriptionURL]:@{};NSArray *cachedChannels=[playlistMetadata[@"cachedChannels"] isKindOfClass:NSArray.class]?playlistMetadata[@"cachedChannels"]:@[];
        BOOL live=subscriptionURL.length>0||[caps containsObject:@"live"];BOOL vod=[ServiceStore isVODMediaService:service];NSString *kind=live&&vod?@"both":(live?@"live":(vod?@"vod":@"unknown"));
        NSString *playlistStatus=[playlistMetadata[@"status"] isKindOfClass:NSString.class]?playlistMetadata[@"status"]:(subscriptionURL.length?(enabled?@"等待读取订阅清单":@"服务已停止 · 保留最近频道"):@"未配置播放列表");
        [rows addObject:@{@"name":service[@"name"]?:@"本机脚本",@"type":@"plugin",@"resourceKind":kind,@"capabilities":caps,@"engine":service[@"engine"]?:@"python",@"runtime":service[@"engine"]?:@"python",@"protocol":service[@"protocol"]?:@"未知协议",@"playlistPath":[ServiceStore playlistPathForService:service]?:@"",@"subscriptionURL":subscriptionURL,@"epgURL":epgURL,@"subscriptionStatus":playlistStatus,@"channelCount":@(cachedChannels.count),@"playlistUpdatedAt":playlistMetadata[@"updatedAt"]?:@0,@"port":service[@"port"]?:@0,@"url":service[@"url"]?:@"",@"current":@([service[@"id"] isEqual:selectedMedia]),@"source":[@"plugin:" stringByAppendingString:service[@"id"]],@"status":[PyHost runtimeStatusDescriptionForServiceIdentifier:service[@"id"]],@"enabled":@(enabled)}];
    }
    for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){
        NSString *identifier=catalog[@"id"]?:@"";NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"";if(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])catalogName=@"资源合集";NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSUInteger supported=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])supported++;
        NSUInteger liveCount=[catalog[@"lives"] count];NSString *kind=supported&&liveCount?@"both":(supported?@"vod":(liveCount?@"live":@"unknown"));NSString *catalogKind=[catalog[@"catalogKind"] isKindOfClass:NSString.class]?catalog[@"catalogKind"]:@"tvbox";
        [rows addObject:@{@"name":catalogName,@"type":@"tvbox",@"catalogKind":catalogKind,@"resourceKind":kind,@"source":[@"tvbox:" stringByAppendingString:identifier],@"url":catalog[@"url"]?:@"",@"siteCount":@(sites.count),@"supportedCount":@(supported),@"liveCount":@(liveCount),@"current":@NO}];
    }
    return rows;
}
- (void)openPluginResource:(NSString *)source {
    if([source hasPrefix:@"tvbox:"]){[self openTVBoxCatalog:[source substringFromIndex:6]];return;}
    NSDictionary *service=[self resourceServiceForSource:source];if(!service)return;PluginResourceDetailViewController *page=[PluginResourceDetailViewController new];page.service=service;__weak typeof(self) weakSelf=self;
    page.onToggle=^(NSDictionary *item,BOOL enabled,void(^completion)(NSError *)){[weakSelf changeService:item enabled:enabled completion:completion];};
    page.onUse=^(NSDictionary *item,NSString *kind){[weakSelf usePluginService:item kind:kind];};
    page.onLog=^(NSDictionary *item){[weakSelf openDiagnosticLogForIdentifier:item[@"id"] name:item[@"name"]];};page.onEdit=^(NSDictionary *item){[weakSelf openServiceEditorForService:item];};page.onRemove=^(NSDictionary *item){RootViewController *owner=weakSelf;if([PyHost isManagedServiceIdentifier:item[@"id"]]){[owner showServiceError:@"请先停止此资源服务，再移除代码和配置。"];return;}[ServiceStore remove:item[@"id"]];[owner.navigationController popViewControllerAnimated:YES];[owner refreshConfigurationPage];};
    page.onUpdate=^(NSDictionary *item){RootViewController *owner=weakSelf;[owner downloadPackageURL:[NSURL URLWithString:item[@"url"]] completion:^(NSDictionary *value,NSError *error){[weakSelf acceptImportedMedia:value error:error];}];};
    __weak PluginResourceDetailViewController *weakPage=page;
    page.onRollback=^(NSDictionary *item){RootViewController *owner=weakSelf;dispatch_block_t rollback=^{NSError *error=nil;NSDictionary *restored=[ServiceStore rollbackImportedService:item error:&error];if(!restored){[owner showServiceError:error.localizedDescription];return;}weakPage.service=restored;[weakPage.tableView reloadData];[owner refreshConfigurationPage];};if([PyHost isManagedServiceIdentifier:item[@"id"]])[owner changeService:item enabled:NO completion:^(NSError *error){if(error)[owner showServiceError:error.localizedDescription];else rollback();}];else rollback();};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)openServiceEditorForService:(NSDictionary *)service {
    ServiceEditorViewController *editor=[ServiceEditorViewController new];editor.service=service;__weak typeof(self) weakSelf=self;
    editor.onApplyService=^(NSDictionary *previous,NSDictionary *updated,void(^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner applyServiceConfigurationFrom:previous to:updated completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);};
    editor.onSave=^{[weakSelf refreshConfigurationPage];};
    [self.navigationController pushViewController:editor animated:YES];
}
- (void)applyServiceConfigurationFrom:(NSDictionary *)previous to:(NSDictionary *)updated completion:(void (^)(NSError * _Nullable))completion {
    NSInteger requestedPort=[updated[@"port"] integerValue];
    for(NSDictionary *other in [ServiceStore services])if(![other[@"id"] isEqual:updated[@"id"]]&&[other[@"port"] integerValue]==requestedPort&&[PyHost isManagedServiceIdentifier:other[@"id"]]){
        NSString *message=[NSString stringWithFormat:@"端口 %ld 正由“%@”使用。已保留当前服务运行状态；请选择其他端口。",(long)requestedPort,other[@"name"]?:other[@"id"]];
        if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:6 userInfo:@{@"NSLocalizedDescriptionKey":message}]);return;
    }
    [ServiceStore associateLegacyLoopbackSubscriptionsForService:previous];
    __weak typeof(self) weakSelf=self;
    [self changeService:previous enabled:NO completion:^(NSError *stopError){
        RootViewController *owner=weakSelf;if(!owner){if(completion)completion(stopError?:[NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);return;}
        if(stopError){if(completion)completion(stopError);return;}
        [ServiceStore save:updated];[owner refreshConfigurationPage];
        [owner changeService:updated enabled:YES completion:^(NSError *startError){
            NSError *reportedError=startError;
            if(startError){NSMutableDictionary *info=[startError.userInfo mutableCopy]?:[NSMutableDictionary dictionary];info[@"CCTVHostServiceConfigurationSaved"]=@YES;reportedError=[NSError errorWithDomain:startError.domain code:startError.code userInfo:info];}
            if(completion)completion(reportedError);
        }];
    }];
}
- (void)usePluginService:(NSDictionary *)item kind:(NSString *)kind {
    if(!item||!kind.length)return;
    NSString *liveURL=[ServiceStore subscriptionURLForService:item];
    if([kind isEqual:@"live"]&&!liveURL.length){for(NSString *candidate in self.subscriptionURLs){NSDictionary *provider=[self localServiceForURL:[NSURL URLWithString:candidate]];if([provider[@"id"] isEqual:item[@"id"]]){liveURL=candidate;break;}}if(!liveURL.length){[self openServiceEditorForService:item];return;}}
    [self changeService:item enabled:YES completion:^(NSError *error){if(error){[self showServiceError:error.localizedDescription];return;}if([kind isEqual:@"vod"]||[kind isEqual:@"configuration"]){[NSUserDefaults.standardUserDefaults setObject:item[@"id"] forKey:@"selectedMediaSource"];[self.navigationController popToViewController:self animated:NO];[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)self.tabPages[@2];if([kind isEqual:@"configuration"])[browser showConfigurationForSource:item];else [browser openSourceIdentifier:item[@"id"]?:@""];return;}NSString *url=[ServiceStore subscriptionURLForService:item]?:liveURL;if(!url.length){[self showServiceError:@"服务已启动，但尚未发现可读取的直播列表路径。请编辑此资源的直播列表路径后重试。"];return;}NSMutableDictionary *metadata=[@{@"managedServiceID":item[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:url][@"name"])[metadata addEntriesFromDictionary:@{@"name":item[@"name"]?:@"本机直播服务"}];[ProfileStore update:url values:metadata];if(![self.subscriptionURLs containsObject:url]){[self.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];}[self.navigationController popToViewController:self animated:NO];[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[1]];self.activeSource=url;self.title=@"订阅直播";[self fetchSubscription:url silent:NO];}];
}
- (void)openTVBoxCatalog:(NSString *)identifier {
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    TVBoxCatalogViewController *page=[TVBoxCatalogViewController new];page.catalog=catalog;__weak typeof(self) weakSelf=self;
    page.serviceForSite=^NSDictionary *(NSDictionary *site){NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";for(NSDictionary *service in [ServiceStore services])if(api.length&&[service[@"url"] isEqual:api])return service;return nil;};
    page.onUseImportedService=^(NSDictionary *service){RootViewController *owner=weakSelf;if(!owner)return;NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[owner usePluginService:service kind:kind];};
    page.onOpenImportedService=^(NSDictionary *service){RootViewController *owner=weakSelf;if(owner)[owner openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]?:@""]];};
    page.onImportSite=^(NSDictionary *site,BOOL browseAfterImport){[weakSelf importTVBoxSite:site browseAfterImport:browseAfterImport];};
    page.onUseNativeSite=^(NSDictionary *site){RootViewController *owner=weakSelf;if(!owner)return;NSString *protocol=[site[@"apiKind"] isEqual:@"maccms-api"]?@"maccms-api":@"tvbox-api";NSString *sourceID=[NSString stringWithFormat:@"%@:%@:%@",protocol,catalog[@"id"]?:@"",site[@"key"]?:@""];[NSUserDefaults.standardUserDefaults setObject:sourceID forKey:@"selectedMediaSource"];[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser openSourceIdentifier:sourceID];};
    page.onSubscribeLive=^(NSDictionary *live){RootViewController *owner=weakSelf;NSString *url=live[@"url"];if(!url.length)return;if(![owner.subscriptionURLs containsObject:url]){[owner.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:owner.subscriptionURLs.allObjects forKey:@"subscriptions"];}[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[1]];owner.activeSource=url;owner.title=@"订阅直播";[owner fetchSubscription:url silent:NO];};
    page.onRemove=^{RootViewController *owner=weakSelf;[TVBoxCatalogStore removeCatalog:identifier];[owner.navigationController popViewControllerAnimated:YES];[owner refreshConfigurationPage];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)deleteSubscription:(NSString *)source {
    [self.subscriptionTasks[source] cancel];[self.subscriptionTasks removeObjectForKey:source];[self.subscriptionTraceIDs removeObjectForKey:source];[ProfileStore remove:source];
    [self.subscriptionURLs removeObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.shownChannels.count;}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {CGFloat width=collectionView.bounds.size.width;NSInteger columns=width>700?4:2;CGFloat itemWidth=floor((width-24-(columns-1)*8)/columns);UIFont *title=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection],*subtitle=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9] compatibleWithTraitCollection:self.traitCollection];CGFloat height=90+4+ceil(title.lineHeight)+1+ceil(subtitle.lineHeight)+4;return CGSizeMake(itemWidth,height);}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"channel.card" forIndexPath:ip];NSDictionary *ch=self.shownChannels[ip.item];
    HostStyleGlassCard(cell.contentView,9);
    const NSInteger posterTag=4101,logoTag=4102,brandTag=4103,numberTag=4104,titleTag=4105,subtitleTag=4106;
    UIView *poster=[cell.contentView viewWithTag:posterTag];UIImageView *logo=(UIImageView *)[cell.contentView viewWithTag:logoTag];UILabel *brand=(UILabel *)[cell.contentView viewWithTag:brandTag];UILabel *number=(UILabel *)[cell.contentView viewWithTag:numberTag];UILabel *title=(UILabel *)[cell.contentView viewWithTag:titleTag];UILabel *subtitle=(UILabel *)[cell.contentView viewWithTag:subtitleTag];
    if(!poster){poster=[[UIView alloc] initWithFrame:CGRectZero];poster.tag=posterTag;poster.autoresizingMask=UIViewAutoresizingFlexibleWidth;poster.backgroundColor=HostCard();poster.layer.cornerRadius=8;[cell.contentView addSubview:poster];
        logo=[UIImageView new];logo.tag=logoTag;logo.autoresizingMask=UIViewAutoresizingFlexibleWidth;logo.contentMode=UIViewContentModeScaleAspectFit;[poster addSubview:logo];
        brand=[UILabel new];brand.tag=brandTag;brand.textAlignment=NSTextAlignmentCenter;brand.font=[UIFont italicSystemFontOfSize:19];brand.adjustsFontForContentSizeCategory=YES;brand.textColor=HostText();brand.autoresizingMask=UIViewAutoresizingFlexibleWidth;[poster addSubview:brand];
        number=[UILabel new];number.tag=numberTag;number.font=[UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];number.textColor=UIColor.secondaryLabelColor;[poster addSubview:number];
        title=[UILabel new];title.tag=titleTag;title.autoresizingMask=UIViewAutoresizingFlexibleWidth;title.adjustsFontForContentSizeCategory=YES;title.numberOfLines=1;title.lineBreakMode=NSLineBreakByTruncatingTail;[cell.contentView addSubview:title];
        subtitle=[UILabel new];subtitle.tag=subtitleTag;subtitle.autoresizingMask=UIViewAutoresizingFlexibleWidth;subtitle.adjustsFontForContentSizeCategory=YES;subtitle.numberOfLines=1;subtitle.lineBreakMode=NSLineBreakByTruncatingTail;subtitle.textColor=UIColor.secondaryLabelColor;[cell.contentView addSubview:subtitle];}
    title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];subtitle.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9] compatibleWithTraitCollection:self.traitCollection];
    CGFloat titleHeight=ceil(title.font.lineHeight),subtitleHeight=ceil(subtitle.font.lineHeight),titleTop=94,subtitleTop=titleTop+titleHeight+1;
    poster.frame=CGRectMake(0,0,cell.bounds.size.width,90);logo.frame=CGRectMake(16,20,cell.bounds.size.width-32,48);brand.frame=logo.frame;number.frame=CGRectMake(7,72,70,12);title.frame=CGRectMake(2,titleTop,cell.bounds.size.width-4,titleHeight);subtitle.frame=CGRectMake(2,subtitleTop,cell.bounds.size.width-4,subtitleHeight);
    NSString *logoURL=[ch[@"logo"] isKindOfClass:NSString.class]?ch[@"logo"]:@"";logo.hidden=!logoURL.length;brand.hidden=logoURL.length>0;brand.text=ch[@"name"]?:@"";logo.image=nil;logo.accessibilityIdentifier=logoURL;if(logoURL.length)[self loadLogo:logoURL into:logo];
    number.text=[NSString stringWithFormat:@"%03lu",(unsigned long)ip.item+1];title.textColor=[ch[@"id"] isEqualToString:self.channelID]?HostAccent():HostText();title.text=[NSString stringWithFormat:@"%@%@",[self.favorites containsObject:ch[@"id"]]?@"♥ ":@"",ch[@"name"]?:ch[@"id"]];
    NSString *xmlSource=[ProfileStore epgSourceForChannel:ch];if(xmlSource.length && !self.epgCache[ch[@"id"]])[self cacheXMLRows:[[XMLTVStore shared] cachedRowsForSource:xmlSource channel:[ProfileStore epgIDForChannel:ch]] channel:ch[@"id"]];subtitle.text=self.epgCache[ch[@"id"]][@"now"]?:ch[@"group"];return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip { HostAnimateSelection([collectionView cellForItemAtIndexPath:ip]);[self selectChannel:self.shownChannels[ip.item]]; }
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSDictionary *ch=self.shownChannels[ip.item];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ch[@"id"] previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){BOOL favorite=[w.favorites containsObject:ch[@"id"]];UIAction *fav=[UIAction actionWithTitle:favorite?@"取消收藏":@"收藏频道" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){if(favorite)[w.favorites removeObject:ch[@"id"]];else[w.favorites addObject:ch[@"id"]];[NSUserDefaults.standardUserDefaults setObject:w.favorites forKey:@"favorites"];[w configureCatalogNavigation];[w applyFilter];}];UIAction *route=[UIAction actionWithTitle:@"线路与节目单" image:[UIImage systemImageNamed:@"list.bullet"] identifier:nil handler:^(UIAction *a){if([ch[@"remoteURL"] length])[w openEPGforChannel:ch[@"id"] name:ch[@"name"]];else[w presentRouteSheetForChannel:ch fromIndexPath:nil];}];NSMutableArray *actions=[NSMutableArray arrayWithObjects:fav,route,nil];
        if([ch[@"remoteURL"] length]){[actions addObject:[UIAction actionWithTitle:@"静音预览（30 秒）" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){[w previewChannel:ch];}]];[actions addObject:[UIAction actionWithTitle:@"EPG 手动匹配" image:[UIImage systemImageNamed:@"calendar"] identifier:nil handler:^(UIAction *a){[w editEPGMapping:ch];}]];}
        return [UIMenu menuWithTitle:ch[@"name"] children:actions];}];
}
- (void)selectChannel:(NSDictionary *)ch {
    // Repeated taps on an active/connecting channel must not restart VDN/DRM.
    BOOL sameChannel=[ch[@"id"] isEqualToString:self.channelID];
    BOOL activeNative=self.currentPlayer && !self.nativePlaybackFailed && ![ch[@"remoteURL"] length] && (self.firstRender || self.watchdog.isValid);
    BOOL activeRemote=([ch[@"remoteURL"] isEqualToString:self.currentRemoteURL]) && (self.remotePlaybackWanted || self.playbackReadiness);
    if(sameChannel && (activeNative || activeRemote)) {
        self.selectionVersion++;self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];self.playerExpanded=YES;[self.view setNeedsLayout];return;
    }
    // Coalesce rapid taps without the previous fixed 80 ms delay.
    NSTimeInterval selectedAt=CACurrentMediaTime();NSUInteger selection=++self.selectionVersion;NSString *selectionTraceID=NSUUID.UUID.UUIDString.lowercaseString;self.currentPlaybackTraceID=selectionTraceID;self.playbackIntentVersion++;[self.playbackReadiness cancel];[self stopPreview];
    BOOL remote=[ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]];
    NSMutableDictionary *selectionFields=[@{@"input_type":remote?@"subscription":@"cctv", @"selection_generation":@(selection), @"channel_id_kind":remote?@"http_url":@"sdk_channel_id", @"correlation_id":selectionTraceID} mutableCopy];
    if(remote)[selectionFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:ch[@"remoteURL"]?:ch[@"id"]?:@""])];
    if(RuntimeDiagnostics.shared.enabled){
        NSArray *subscriptionSources=[ch[@"subscriptionSources"] isKindOfClass:NSArray.class]?ch[@"subscriptionSources"]:@[];
        selectionFields[@"subscription_source_count"]=@(subscriptionSources.count);
        NSMutableArray *sourceFingerprints=[NSMutableArray array];
        for(id source in subscriptionSources){if(sourceFingerprints.count>=8)break;if([source isKindOfClass:NSString.class]){NSDictionary *fields=CCTVDiagnosticURLFields([NSURL URLWithString:source]);NSString *fingerprint=fields[@"source_route_fingerprint"];if(fingerprint.length)[sourceFingerprints addObject:fingerprint];}}
        if(sourceFingerprints.count)selectionFields[@"subscription_source_fingerprints"]=sourceFingerprints;
    }
    [RuntimeDiagnostics.shared recordEvent:@"channel_selected" category:@"playback" fields:selectionFields];
    self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];self.playerExpanded=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        if(selection!=self.selectionVersion){[RuntimeDiagnostics.shared recordEvent:@"channel_selection_superseded" category:@"playback" fields:@{@"correlation_id":selectionTraceID, @"selection_generation":@(selection), @"current_selection_generation":@(self.selectionVersion)}];return;}
        [self rememberChannel:ch];if(CCTVBoolPreference(@"rememberLastChannel",YES))[NSUserDefaults.standardUserDefaults setObject:ch forKey:@"lastChannel"];
        self.selectionRequestedAt=selectedAt;[self routePlayback:ch];[self configureCatalogNavigation];[self.view setNeedsLayout];
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
        cell.backgroundColor = HostCard();
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0;
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;
        cell.detailTextLabel.textColor = HostSecondaryText();
        UIView *selected = [[UIView alloc] init];
        selected.backgroundColor = HostSelectedSurface();
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
    cell.textLabel.textColor = playing ? HostAccent() : HostText();
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
                                                                  message:[NSString stringWithFormat:@"当前线路：%@ · %lu 个地址\n自选地址交给央视 SDK 播放；许可及版权仍由 SDK 处理。",
                                                                           [ch[@"id"] isEqual:self.channelID]?(self.routeName?:@"自动"):@"未选择", (unsigned long)routes.count]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"SDK 自动选线" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self playChannel:ch route:nil];
    }]];
    for (NSDictionary *r in routes) {
        NSString *res = [r[@"w"] intValue] > 0 ? [NSString stringWithFormat:@"%dx%d", [r[@"w"] intValue], [r[@"h"] intValue]] : @"";
        NSString *title = [NSString stringWithFormat:@"自选地址 %@ · 源标注 %@", [r[@"provider"] uppercaseString], res.length?res:@"未知"];
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

- (void)configureSDKLogging {
    BOOL verbose=CCTVBoolPreference(@"nativeSDKVerboseLogs",NO);
    Class cls=NSClassFromString(@"CNPlayer");
    for(NSString *selector in @[@"logEnabled:",@"logToStatEnabled:",@"playerCoreLogEnabled:",@"playerNetWorkLogEnabled:",@"statInfoLogEnabled:",@"statCoreInfoLogEnabled:"])
        [self callClass:cls sel:selector args:@[@(verbose)]];
}

- (void)setupSDK {
    Class cls = NSClassFromString(@"CNPlayer");
    if (!cls) { self.titleLabel.text = @"SDK 未加载"; return; }
    BOOL thumbnailGuardInstalled=[CNPlayerCrashGuard install];
    [self configureSDKLogging];
    [self callClass:cls sel:@"configSDK_CICADA_UDRMUrl:" args:@[kLicenseUrl]];
    @try {
        [CNPlayer startPlayerSDK_Options:[CNPlayer defaultOptions]];
    } @catch (NSException *e) {
        [self log:@"启动异常 %@", e.reason];
        return;
    }
    thumbnailGuardInstalled=thumbnailGuardInstalled||[CNPlayerCrashGuard install];
    if(thumbnailGuardInstalled)[self log:@"已启用央视播放器异常缩略图保护"];
    id ver = [self callClass:cls sel:@"SDKVersion" args:@[]];
    [self log:@"CCTVHost %@ · SDK %@ · 当前原生模式：%@ · Python %@",CCTVBuildTag(),ver,CCTVBoolPreference(@"legacyNativePlayback",YES)?@"兼容复用":@"独立实例",PyHost.running?@"运行中":@"未启动"];
    self.nativeCDNPreference=[NativeCDNPreference new];
    [self callClass:cls sel:@"authed" args:@[]];
    self.nativePreloader=[[NativeChannelPreloader alloc] initWithFactory:^id{ return [[NSClassFromString(@"CNPlayer") alloc] init]; } clock:^NSTimeInterval{return CACurrentMediaTime();}];
    __weak typeof(self) preloaderOwner=self;
    self.nativePreloader.onLog=^(NSString *message){[preloaderOwner log:@"%@",message];};

    // SDK 初始化返回后即可续播，不再固定等待 2.5 秒。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!CCTVBoolPreference(@"resumeLastChannel",NO)) { [self log:@"启动时自动续播已关闭，等待用户点选频道"]; return; }
        NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"lastChannel"];
        if (![last[@"id"] length] || self.channelID.length) return;
        [self log:@"续播上次频道 %@", last[@"name"] ?: last[@"id"]];
        if ([last[@"remoteURL"] length]) [self playRemote:last];
        else [self playChannel:last route:nil];
    });

    // 预热：提前建好播放器实例，缩短首次起播时间
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.sdkPlayer) return;
        id inst = nil;
        @try { inst = [[cls alloc] init]; } @catch (NSException *e) {}
        if (inst) { weakSelf.sdkPlayer = inst; weakSelf.sdkPlayerUsed=NO; [weakSelf log:@"播放器实例已预热"]; }
    });
}

#pragma mark - 播放

- (void)playChannel:(NSDictionary *)ch route:(NSDictionary *)route {
    if([ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]]){[self routePlayback:ch];return;}
    NSString *cid = ch[@"id"];
    if (!cid.length) return;
    if(!self.nativeCDNPreference)self.nativeCDNPreference=[NativeCDNPreference new];
    NSError *routeError=nil;
    NSString *selectedURL=route?[self.nativeCDNPreference URLForRoute:route error:&routeError]:nil;
    if(route&&!selectedURL){[self showNativeRouteError:routeError channel:ch];return;}
    if(self.nativeCDNPreference.overrideMayBeActive&&![self.nativeCDNPreference restoreDefault:&routeError]){
        [self showNativeRouteError:routeError channel:ch];return;
    }
    self.nativePlainRouteActive=NO;
    if(!self.currentPlaybackTraceID.length||self.selectionRequestedAt<=0)self.currentPlaybackTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    self.requestedNativeRoute=route;
    self.directNativeRouteActive=(route!=nil);
    [self beginPlaybackPriority];
    if(self.activeTab!=0)[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[0]];
    self.playbackGeneration += 1;self.selectionVersion++;
    self.currentRemoteURL = nil;
    self.currentRemoteHeaders = @{};
    self.playerExpanded=YES;
    [self.view setNeedsLayout];
    self.channelID = cid;
    self.channelName = ch[@"name"] ?: cid;
    self.routeName = route ? [NSString stringWithFormat:@"%@ · 自选地址", [route[@"provider"] uppercaseString]] : @"自动";
    if(self.playerTabs.selectedSegmentIndex!=3)self.playerTabs.selectedSegmentIndex=1;
    [self updatePlayerChannelLogoForChannel:ch];
    [self selectPlayerPanel];
    self.firstRender = NO;
    self.stallReported = NO;
    self.nativeStartupRecoveryUsed = NO;
    self.retryCount = 0;
    self.playStartedAt = self.selectionRequestedAt?:CACurrentMediaTime();self.selectionRequestedAt=0;
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
    if(route){
        NSUInteger generation=self.playbackGeneration;
        __weak typeof(self) weakSelf=self;
        void(^resolved)(BOOL)=^(BOOL plain){
            RootViewController *owner=weakSelf;
            if(!owner || generation!=owner.playbackGeneration || ![owner.channelID isEqual:cid] || ![owner.requestedNativeRoute isEqual:route])return;
            owner.nativeRouteProbe=nil;
            if(!owner.plainRouteCache)owner.plainRouteCache=[NSMutableDictionary dictionary];
            if(owner.plainRouteCache.count>=64)[owner.plainRouteCache removeAllObjects];
            owner.plainRouteCache[selectedURL]=@{@"plain":@(plain),@"at":@(CACurrentMediaTime())};
            if(plain){
                [owner log:@"自选线路明文 HLS 清单可读，使用 AVPlayer；等待实际视频首帧"];
                [owner.remoteAttemptedURLs removeAllObjects];owner.remoteRetryCount=0;
                [owner startRemoteChannel:@{@"id":cid,@"name":ch[@"name"]?:cid,@"remoteURL":selectedURL,@"nativePlainRoute":@YES}];
            }else{
                [owner log:@"自选线路未确认明文 HLS，保留所选地址交给 SDK"];
                [owner playViaSDKURL:selectedURL channelID:cid title:owner.channelName];
            }
        };
        NSDictionary *cached=self.plainRouteCache[selectedURL];
        NSTimeInterval age=CACurrentMediaTime()-[cached[@"at"] doubleValue];
        if(cached && age>=0 && age<([cached[@"plain"] boolValue]?30:3))resolved([cached[@"plain"] boolValue]);
        else{self.nativeRouteProbe=[HLSRouteProbe new];[self.nativeRouteProbe startURL:[NSURL URLWithString:selectedURL] completion:resolved];}
    }
    else {[self log:@"使用 SDK 按频道 ID 自动调度"];[self playViaSDK:cid title:self.channelName];}

    // Defer optional EPG traffic until the first video frame.
}

- (void)playSelectedNativeRouteOrChannel {
    if(self.requestedNativeRoute){
        NSError *error=nil;NSString *url=[self.nativeCDNPreference URLForRoute:self.requestedNativeRoute error:&error];
        if(!url){[self displayNativePlaybackFailure:@"所选线路配置无效" error:error];return;}
        [self playViaSDKURL:url channelID:self.channelID title:self.channelName];return;
    }
    [self playViaSDK:self.channelID title:self.channelName];
}

- (void)playViaSDKURL:(NSString *)url channelID:(NSString *)cid title:(NSString *)title {
    [CNPlayerCrashGuard install];
    if(!url.length||!cid.length){[self displayNativePlaybackFailure:@"所选线路参数缺失" error:nil];return;}
    NSMutableDictionary *traceFields=[@{@"route_type":@"user_selected", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[traceFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:url])];[RuntimeDiagnostics.shared recordEvent:@"native_playback_start_requested" category:@"playback" fields:traceFields];
    [self beginPlaybackPriority];
    self.nativeRetryPending=NO;self.nativePlaybackFailed=NO;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",title?:cid];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"所选地址交给央视 SDK 播放";[self.spinner startAnimating];
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    [self.nativePreloader cancel];self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
    Class cls=NSClassFromString(@"CNPlayer");SEL selector=NSSelectorFromString(@"playLIVEWithUrl:delegate:configOptions:");
    id player=nil;@try{player=[[cls alloc] init];}@catch(NSException *exception){[self log:@"创建 SDK 播放器异常 %@",exception.reason];}
    NSMethodSignature *signature=[player methodSignatureForSelector:selector];
    BOOL supported=player&&[player respondsToSelector:selector]&&signature&&signature.numberOfArguments==5&&signature.methodReturnType[0]=='B'&&strcmp([signature getArgumentTypeAtIndex:2],"@")==0&&strcmp([signature getArgumentTypeAtIndex:3],"@")==0&&strcmp([signature getArgumentTypeAtIndex:4],"@")==0;
    if(!supported){[self displayNativePlaybackFailure:@"SDK 不支持自选地址起播" error:nil];return;}
    self.currentPlayer=player;self.cicadaPlayer=nil;self.nativePlaybackFailed=NO;
    @try{[player setValue:@YES forKey:@"autoPlay"];}@catch(NSException *exception){}
    self.nativeStartupTuner=CCTVBoolPreference(@"fastNativeStartup",YES)?[NativeStartupTuner new]:nil;
    NSMutableDictionary *options=[@{kOptTitle:title?:cid,kOptURLChannelIDForStats:cid} mutableCopy];
    id dataManager=[self call:player sel:@"dataManager"];
    id userID=[self call:dataManager sel:@"userID"];
    if([userID isKindOfClass:NSString.class]&&[userID length])options[kOptUserID]=userID;
    [self log:@"CNPlayer URL 起播 %@ · %@",cid,[NSURL URLWithString:url].host?:@"未知主机"];
    id accepted=[self invokeTarget:player selector:selector args:@[url,self,options]];
    [self recordStartupStage:@"configure"];
    if(![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        self.currentPlayer=nil;@try{[player setValue:nil forKey:@"delegate"];}@catch(NSException *exception){}[self call:player sel:@"stop"];
        [self log:@"CNPlayer 未接受所选地址；保留线路选择，不回退自动"];
        [self displayNativePlaybackFailure:@"SDK 拒绝所选地址" error:nil];return;
    }
    if(![CNPlayerCrashGuard install])[self log:@"未能安装播放器缩略图异常保护"];
    [self attachVideoView];[self call:player sel:@"prepareToPlay"];[self recordStartupStage:@"prepareCall"];[self startWatchdog];
}

- (void)playViaSDK:(NSString *)cid title:(NSString *)title {
    // Some SDK builds load their IJK core lazily; install the guard again
    // before prepareToPlay can enter its asynchronous decoder/error path.
    [CNPlayerCrashGuard install];
    [RuntimeDiagnostics.shared recordEvent:@"native_playback_start_requested" category:@"playback" fields:@{@"route_type":@"sdk_auto", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"channel_id_kind":([ProfileStore isHTTP:cid]?@"http_url":@"sdk_channel_id")}];
    if([ProfileStore isHTTP:cid]){[self playRemote:@{@"id":cid,@"name":title?:cid,@"remoteURL":cid}];return;}
    [self beginPlaybackPriority];
    self.nativeRetryPending=NO;self.nativePlaybackFailed=NO;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",title?:cid];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"";[self.spinner startAnimating];
    // Default matches v0.12: stop the old playback, reset the retained wrapper,
    // then playLIVEWithChannelID + prepareToPlay. Fresh wrappers remain an A/B option.
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    Class cls=NSClassFromString(@"CNPlayer");SEL playSel=NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    BOOL legacy=CCTVBoolPreference(@"legacyNativePlayback",YES);
    id prepared=(!self.directNativeRouteActive && CCTVBoolPreference(@"preloadNativeChannel",YES))?[self.nativePreloader takeChannel:cid]:nil;
    [self.nativePreloader cancel];
    id inst=prepared?:self.sdkPlayer;
    if(prepared && self.sdkPlayer && prepared!=self.sdkPlayer)[self call:self.sdkPlayer sel:@"reset"];
    if(!prepared && !legacy&&self.sdkPlayerUsed)inst=nil;
    if(!prepared && legacy&&inst&&self.sdkPlayerUsed)[self call:inst sel:@"reset"];
    self.sdkPlayer=nil;
    if(!inst){@try{inst=[[cls alloc] init];}@catch(NSException *e){[self log:@"创建播放器异常 %@",e.reason];}}
    if(!inst||![inst respondsToSelector:playSel]){[self displayNativePlaybackFailure:@"SDK 接口不可用" error:nil];return;}
    self.currentPlayer=inst;self.cicadaPlayer=nil;self.sdkPlayer=legacy?inst:nil;self.sdkPlayerUsed=YES;
    @try{[inst setValue:@YES forKey:@"autoPlay"];}@catch(NSException *e){}
    self.nativePlaybackFailed=NO;
    self.nativeStartupTuner=CCTVBoolPreference(@"fastNativeStartup",YES)?[NativeStartupTuner new]:nil;
    NSDictionary *options=@{kOptTitle:title?:cid};
    [self log:@"原生起播 %@ · %@",cid,legacy?@"0.12 兼容复用":@"独立实例对比"];
    id accepted=@YES;
    if(prepared){
        @try{[inst setValue:self forKey:@"delegate"];}@catch(NSException *e){prepared=nil;}
        if(prepared){[self recordStartupStage:@"preloadedVDN"];[self log:@"命中原生预解析 %@，保留播放信息直接 prepare",cid];}
    }
    if(!prepared)accepted=[self invokeTarget:inst selector:playSel args:@[cid,self,options]];
    if([accepted isKindOfClass:NSNumber.class]&&![accepted boolValue]){
        id previous=inst;self.currentPlayer=nil;
        @try{[previous setValue:nil forKey:@"delegate"];}@catch(NSException *e){}
        [self call:previous sel:@"stop"];
        @try{inst=[[cls alloc] init];}@catch(NSException *e){inst=nil;}
        if(inst){self.currentPlayer=inst;self.sdkPlayer=legacy?inst:nil;@try{[inst setValue:@YES forKey:@"autoPlay"];}@catch(NSException *e){}accepted=[self invokeTarget:inst selector:playSel args:@[cid,self,options]];}
    }
    [self recordStartupStage:@"configure"];
    if(!inst||([accepted isKindOfClass:NSNumber.class]&&![accepted boolValue])){
        [self log:@"SDK 拒绝起播，等待具体错误回调"];[self displayNativePlaybackFailure:@"起播被拒绝" error:nil];return;
    }
    BOOL thumbnailGuardInstalled=[CNPlayerCrashGuard install];
    if(!thumbnailGuardInstalled)[self log:@"未能安装播放器缩略图异常保护"];
    [self attachVideoView];[self call:inst sel:@"prepareToPlay"];[self recordStartupStage:@"prepareCall"];[self startWatchdog];
}

- (void)recordStartupStage:(NSString *)stage {
    if([self.startupTrace record:stage atTime:CACurrentMediaTime()])
        [self log:@"起播阶段 %@ [%lu] %@ +%.2fs",self.channelID?:@"—",(unsigned long)self.playbackGeneration,stage,[self.startupTrace.stages[stage] doubleValue]];
}

- (void)stopPlayback {
    [self.nativeRouteProbe cancel];self.nativeRouteProbe=nil;
    self.nativeRetryPending=NO;
    self.moviePiPActive=NO;
    [self.moviePlayer pause];self.movieController.player=nil;self.moviePlayer=nil;self.movieController=nil;
    [self.nativeTimeshift cancel];self.nativeTimeshift=nil;self.nativeTransitionKind=nil;self.nativeTimeShiftActive=NO;
    self.nativeStartupTuner=nil; // Pending tuning blocks also check the playback generation.
    self.remotePlaybackWanted=NO;
    self.remoteFailureRecoveryPending=NO;
    if(self.avKeepUpObserved){[self.avPlayer.currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:kAVItemStatusContext];self.avKeepUpObserved=NO;}
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
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:self.avPlayer.currentItem];
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
    for (UIView *v in self.playerBox.subviews.copy) {
        if (v == self.titleLabel || v == self.infoLabel || v == self.spinner || v == self.controlBar || v == self.playerChannelLogo) continue;
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
    if(self.moviePlayer){if(self.moviePlayer.rate>0)[self.moviePlayer pause];else[self.moviePlayer play];return;}
    if(self.nativePlainRouteActive && self.remotePlaybackFailed){NSDictionary *channel=[self channelWithID:self.channelID];if(channel)[self playChannel:channel route:self.requestedNativeRoute];return;}
    if(self.remotePlaybackFailed && self.currentRemoteURL.length){[self playRemote:@{@"id":self.channelID?:self.currentRemoteURL,@"name":self.channelName?:self.currentRemoteURL,@"remoteURL":self.currentRemoteURL,@"headers":self.currentRemoteHeaders?:@{}}];return;}
    if(self.nativePlaybackFailed){NSDictionary *channel=[self channelWithID:self.channelID];if(!channel && self.channelID.length)channel=@{@"id":self.channelID,@"name":self.channelName?:self.channelID};if(channel){self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:self.requestedNativeRoute];}return;}
    if (self.avPlayer) {
        BOOL playing=self.remotePlaybackWanted;
        self.remotePlaybackWanted=!playing;
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
        self.bottomBarBackdrop.hidden = YES;
        self.channelGrid.hidden=YES;
        self.playerTabs.hidden=YES;
        self.playbackPanel.view.hidden=YES;
        self.tabPage.view.hidden=YES;
    } else {
        BOOL catalog=self.activeTab<2;
        BOOL matchingPlayer=self.favoritesOnly||(self.subscriptionCatalog==([self.currentRemoteURL length]>0));
        BOOL expanded=self.playerExpanded&&matchingPlayer;
        CGFloat ph=expanded?MIN(w*9.0/16.0,MAX(120,(height-top-safe.bottom)*0.50)):0;
        self.playerBox.frame=CGRectMake(0,top,w,ph);self.playerBox.hidden=!catalog||!expanded;
        CGFloat y=top+ph;self.groupControl.frame=CGRectMake(12,y+6,w-24,28);self.groupControl.hidden=!catalog||expanded;self.playerTabs.frame=CGRectMake(12,y+6,w-24,28);self.playerTabs.hidden=!catalog||!expanded;
        self.versionLabel.hidden=YES;
        CGFloat contentY=y+42;CGFloat tabY=height-safe.bottom-72;
        CGRect frame=CGRectMake(0,contentY,w,MAX(0,tabY-contentY));self.table.frame=frame;self.channelGrid.frame=frame;
        self.table.hidden=!catalog||self.gridMode||self.playbackPanel!=nil;self.channelGrid.hidden=!catalog||!self.gridMode||self.playbackPanel!=nil;self.playbackPanel.view.frame=frame;self.playbackPanel.view.hidden=!catalog;
        self.bottomBar.frame=CGRectMake(MAX(18,(w-420)/2),height-safe.bottom-64,MIN(w-36,420),56);self.bottomBarBackdrop.frame=self.bottomBar.frame;self.bottomBar.hidden=NO;self.bottomBarBackdrop.hidden=NO;
        self.tabPage.view.frame=CGRectMake(0,top,w,MAX(0,tabY-top));[self.view bringSubviewToFront:self.bottomBarBackdrop];[self.view bringSubviewToFront:self.bottomBar];
    }
    [self relayoutPlayer];
    CGFloat overlayTop = self.fullscreen ? safe.top : 0;
    self.titleLabel.frame = CGRectMake(12 + safe.left, overlayTop + 8, MAX(0, w - safe.left - safe.right - 104), 20);
    self.infoLabel.frame = CGRectMake(12 + safe.left, overlayTop + 30, MAX(0, w - safe.left - safe.right - 24), 16);
    self.playerChannelLogo.frame=CGRectMake(MAX(safe.left+12,w-safe.right-76),overlayTop+8,64,36);
    CGFloat bottom = self.fullscreen ? safe.bottom : 0;
    self.controlBar.frame = CGRectMake(8 + safe.left, CGRectGetHeight(self.playerBox.bounds) - bottom - 48,
                                      MAX(0, w - safe.left - safe.right - 16), 40);
    self.avLayer.frame = self.playerBox.bounds;
    [self attachVideoView];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        HostStyleNavigation(self.navigationController);
        HostRefreshAppearanceLayers(self.view.window);
    }
    if(previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self.channelGrid.collectionViewLayout invalidateLayout];
        [self.channelGrid reloadData];
        [self.table reloadData];
        [self.view setNeedsLayout];
    }
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
        self.bottomBarBackdrop.hidden = NO;
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
                [self log:@"已删除订阅 %@", CCTVServiceLogAddress(u)];
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
    page.onApplyService=^(NSDictionary *previousService,NSDictionary *updatedService,void (^completion)(NSError * _Nullable)){RootViewController *owner=weakSelf;if(owner)[owner applyServiceConfigurationFrom:previousService to:updatedService completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);};
    page.onBrowseService=^(NSDictionary *service){[NSUserDefaults.standardUserDefaults setObject:service[@"id"] forKey:@"selectedMediaSource"];[weakSelf.navigationController popToViewController:weakSelf animated:NO];[weakSelf selectBottomTab:(id)weakSelf.bottomBar.arrangedSubviews[2]];};
    page.onImportResource=^{[weakSelf.navigationController popToViewController:weakSelf animated:NO];[weakSelf selectBottomTab:(id)weakSelf.bottomBar.arrangedSubviews[3]];dispatch_async(dispatch_get_main_queue(),^{[weakSelf importMediaPackage];});};
    page.onOpenLog=^(NSDictionary *service){if(service)[weakSelf openDiagnosticLogForIdentifier:service[@"id"] name:service[@"name"]];else[weakSelf openDiagnosticLog];};
    page.onSubscribe=^(NSString *url){RootViewController *owner=weakSelf;NSString *key=[owner stableURLKey:url];if(!owner||!key.length)return;NSDictionary *service=[owner localServiceForURL:[NSURL URLWithString:key]];if(service){NSMutableDictionary *metadata=[@{@"managedServiceID":service[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:key][@"name"])[metadata addEntriesFromDictionary:@{@"name":service[@"name"]?:@"本机直播服务"}];[ProfileStore update:key values:metadata];}if(![owner.subscriptionURLs containsObject:key]){[owner.subscriptionURLs addObject:key];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:owner.subscriptionURLs.allObjects] forKey:@"subscriptions"];}if(service&&![PyHost isRunningServiceIdentifier:service[@"id"]]){[owner changeService:service enabled:YES completion:^(NSError *error){if(error){[owner showServiceError:error.localizedDescription];return;}[owner fetchSubscription:key silent:NO];}];}else[owner fetchSubscription:key silent:NO];};
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
    NSDictionary *builtinService=nil;for(NSDictionary *service in [ServiceStore services])if([service[@"builtin"] boolValue]){builtinService=service;break;}
    NSString *builtinID=[builtinService[@"id"] copy],*builtinName=[builtinService[@"name"] copy];
    page.onOpenLog = ^{[weakSelf openDiagnosticLogForIdentifier:builtinID name:builtinName];};
    [page updateRunning:[PyHost isRunningServiceIdentifier:builtinID] subscriptionCount:self.subscriptionURLs.count];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)openSettingsPage {
    [self.navigationController pushViewController:[self makeSettingsPage] animated:YES];
}

- (SettingsViewController *)makeSettingsPage {
    SettingsViewController *page=[SettingsViewController new];
    __weak typeof(self) weakSelf=self;
    page.onExportData=^{[weakSelf exportLocalConfiguration];};page.onImportData=^{[weakSelf importLocalConfiguration];};page.onOpenLog=^{[weakSelf openDiagnosticLog];};
    page.onOpenDiagnostics=^{[weakSelf.navigationController pushViewController:[[RuntimeDiagnosticsViewController alloc] initWithSessionID:nil] animated:YES];};
    page.onClearEPG=^{ [[XMLTVStore shared] clear];[weakSelf.epgCache removeAllObjects]; [weakSelf saveEPGCache]; [weakSelf.table reloadData]; };
    page.onPreferenceChanged=^(NSString *key, BOOL value){
        if([key isEqualToString:HostDarkThemePreferenceKey]||[key isEqualToString:HostThemeModePreferenceKey]){UIWindow *window=weakSelf.view.window;window.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostStyleNavigation(weakSelf.navigationController);HostRefreshAppearanceLayers(window);});}
        if ([key isEqualToString:@"runtimeDiagnosticsEnabled"]) [RuntimeDiagnostics.shared setEnabled:value];
        if ([key isEqualToString:@"nativeSDKVerboseLogs"]) [weakSelf configureSDKLogging];
        if ([key isEqualToString:@"preloadNativeChannel"] && !value) [weakSelf.nativePreloader cancel];
        if ([key isEqualToString:@"allowBackgroundAudio"]) [weakSelf activateAudioSession];
        if ([key isEqualToString:@"autoLoadEPG"]) { [weakSelf.epgTimer invalidate]; weakSelf.epgTimer=nil; weakSelf.epgRefreshDesired=value;if(value) [weakSelf restartEPGTimer]; else weakSelf.infoLabel.text=@"节目单自动获取已关闭"; }
    };
    return page;
}

- (void)exportLocalConfiguration {
    NSData *data=[NSJSONSerialization dataWithJSONObject:[HostBackup snapshot] options:NSJSONWritingPrettyPrinted error:NULL];NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"CCTVHost-configuration.json"];[data writeToFile:path atomically:YES];UIActivityViewController *v=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];v.popoverPresentationController.sourceView=self.bottomBar;v.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:v animated:YES completion:nil];
}
- (void)importLocalConfiguration {self.importingPlaylist=NO;self.importingMediaPackage=NO;self.importingTVBoxCatalog=NO;UIDocumentPickerViewController *v=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];v.delegate=self;[self presentViewController:v animated:YES completion:nil];}
- (void)importMediaPackage {
    self.importingMediaPackage=YES;self.importingPlaylist=NO;self.importingTVBoxCatalog=NO;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)downloadPackageURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    [self.packageDownloader cancel];MediaPackageDownloader *downloader=[MediaPackageDownloader new];self.packageDownloader=downloader;
    UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"导入影视 / 插件资源" message:@"准备下载…" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakProgress=progress;__block BOOL delivered=NO;__block NSString *lastStage=nil;NSString *traceID=NSUUID.UUID.UUIDString.lowercaseString;
    [RuntimeDiagnostics.shared recordEvent:@"resource_import_started" category:@"import" fields:@{@"correlation_id":traceID, @"source_host":url.host?:@"", @"source_extension":url.pathExtension?:@""}];
    void(^finish)(NSDictionary *,NSError *)=^(NSDictionary *service,NSError *error){
        RootViewController *owner=weakSelf;if(delivered)return;delivered=YES;
        if(!owner||owner.packageDownloader!=downloader){if(service)[ServiceStore remove:service[@"id"]];return;}
        owner.packageDownloader=nil;owner.navigationItem.prompt=nil;
        [RuntimeDiagnostics.shared recordEvent:service?@"resource_import_succeeded":@"resource_import_failed" category:@"import" fields:@{@"correlation_id":traceID, @"service_id":service[@"id"]?:@"", @"stage":lastStage?:@"download", @"configuration_state":service[@"configurationState"]?:@"", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];
        dispatch_block_t done=^{
            if(error&&error.code!=NSURLErrorCancelled){
                UIAlertController *failure=[UIAlertController alertControllerWithTitle:@"资源导入失败" message:[NSString stringWithFormat:@"%@\n%@",lastStage?:@"下载阶段",error.localizedDescription?:@"请检查网络后重试"] preferredStyle:UIAlertControllerStyleAlert];
                [failure addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){if(completion)completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
                [failure addAction:[UIAlertAction actionWithTitle:@"重新下载并校验" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner downloadPackageURL:url completion:completion];}]];
                [owner presentViewController:failure animated:YES completion:nil];return;
            }
            if(completion)completion(service,error);
        };
        if(owner.presentedViewController==weakProgress)[weakProgress dismissViewControllerAnimated:YES completion:done];else done();
    };
    [progress addAction:[UIAlertAction actionWithTitle:@"取消下载" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[downloader cancel];finish(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
    downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){if(delivered||weakSelf.packageDownloader!=downloader)return;if(![lastStage isEqual:stage]){lastStage=stage;[RuntimeDiagnostics.shared recordEvent:@"resource_import_stage" category:@"import" fields:@{@"correlation_id":traceID, @"stage":stage, @"received_bytes":@(received), @"expected_bytes":@(expected)}];}NSString *amount=expected>0?[NSString stringWithFormat:@"%.2f / %.2f MB · %ld%%",received/1048576.0,expected/1048576.0,(long)MIN(100,received*100/expected)]:[NSString stringWithFormat:@"已接收 %.2f MB",received/1048576.0];weakProgress.message=[NSString stringWithFormat:@"%@\n%@\n导入完成后可选择启动，当前不会执行脚本。",stage,amount];};
    dispatch_block_t show=^{RootViewController *owner=weakSelf;if(!owner||owner.packageDownloader!=downloader||delivered)return;[owner presentViewController:progress animated:YES completion:^{if(!delivered)[downloader importURL:url completion:finish];}];};
    if(self.presentedViewController)[self.presentedViewController dismissViewControllerAnimated:YES completion:show];else show();
}
- (void)importMediaURL {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"导入影视资源链接" message:@"支持 JS、Python、ZIP，以及对应的 .md5 地址。导入后再启用运行。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"https://…/index.js.md5 或插件.zip";field.keyboardType=UIKeyboardTypeURL;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSString *text=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(text.length>8192){[self showServiceError:@"资源地址过长"];return;}
        __weak typeof(self) weakSelf=self;[self downloadPackageURL:[NSURL URLWithString:text] completion:^(NSDictionary *service,NSError *error){[weakSelf acceptImportedMedia:service error:error];}];
    }]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)importTVBoxCatalog {
    UIAlertController *choice=[UIAlertController alertControllerWithTitle:@"导入 TVBox 配置" message:@"合集仅保存站点和直播列表索引；选择单个条目后才会访问或导入，不会批量启动。站点脚本仍会经过现有导入器检查，并由你单独启停。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    [choice addAction:[UIAlertAction actionWithTitle:@"从 URL 导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"TVBox 配置地址" message:@"输入包含 sites 或 lives 的 JSON 配置。" preferredStyle:UIAlertControllerStyleAlert];[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"https://…/tvbox.json";field.keyboardType=UIKeyboardTypeURL;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;}];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){NSString *text=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSURL *url=[NSURL URLWithString:text];if(!url){[owner showServiceError:@"请输入有效的 HTTP/HTTPS 地址"];return;}[owner.tvboxCatalogDownloader cancel];owner.tvboxCatalogDownloader=[TVBoxCatalogDownloader new];owner.navigationItem.prompt=@"正在下载并检查 TVBox 配置…";[owner.tvboxCatalogDownloader loadURL:url completion:^(NSDictionary *catalog,NSError *error){RootViewController *root=weakSelf;root.navigationItem.prompt=nil;if(error){[root showServiceError:error.localizedDescription];return;}[root acceptTVBoxCatalog:catalog];}];}]];[owner presentViewController:alert animated:YES completion:nil];}]];
    [choice addAction:[UIAlertAction actionWithTitle:@"从本地 JSON 导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;owner.importingTVBoxCatalog=YES;owner.importingPlaylist=NO;owner.importingMediaPackage=NO;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];picker.delegate=owner;[owner presentViewController:picker animated:YES completion:nil];}]];
    [choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(choice.popoverPresentationController){choice.popoverPresentationController.sourceView=self.view;choice.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);}
    [self presentViewController:choice animated:YES completion:nil];
}
- (void)importMacCMSAPI {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"添加 MacCMS 影视接口" message:@"支持常见 MacCMS JSON 与 XML 采集响应。导入时只保存接口；选中来源后才会请求内容。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"https://example.com/api.php/provide/vod/";field.keyboardType=UIKeyboardTypeURL;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"来源名称（可选）";}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存来源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *url=alert.textFields.firstObject.text?:@"";NSString *name=alert.textFields.lastObject.text?:@"";NSError *error=nil;NSDictionary *catalog=[TVBoxCatalogStore catalogWithMacCMSAPIURL:url name:name error:&error];if(!catalog){[self showServiceError:error.localizedDescription?:@"接口地址无效"];return;}[self acceptTVBoxCatalog:catalog];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)acceptTVBoxCatalog:(NSDictionary *)catalog {
    if(!catalog){[self showServiceError:@"TVBox 配置无法解析"];return;}
    NSString *url=catalog[@"url"]?:@"";NSDictionary *existing=nil;if(url.length)for(NSDictionary *row in [TVBoxCatalogStore catalogs])if([row[@"url"] isEqual:url]){existing=row;break;}
    if(!existing&&[TVBoxCatalogStore catalogs].count>=50){[self showServiceError:@"最多保存 50 个资源合集，请先移除不再使用的合集"];return;}
    if(!existing){[TVBoxCatalogStore saveCatalog:catalog];[self refreshConfigurationPage];[self openTVBoxCatalog:catalog[@"id"]];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"发现相同配置地址" message:@"原合集不会被覆盖。可打开现有合集，或将这次导入保留为独立副本。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保留独立副本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[TVBoxCatalogStore saveCatalog:catalog];[self refreshConfigurationPage];[self openTVBoxCatalog:catalog[@"id"]];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"打开已有合集" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self openTVBoxCatalog:existing[@"id"]];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)importTVBoxSite:(NSDictionary *)site { [self importTVBoxSite:site browseAfterImport:NO]; }
- (void)importTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport {
    NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";if(!api.length){[self showServiceError:@"此 TVBox 站点没有可导入的脚本地址"];return;}
    self.pendingTVBoxExt=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";self.pendingTVBoxSiteName=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"";
    __weak typeof(self) weakSelf=self;
    [self downloadPackageURL:[NSURL URLWithString:api] completion:^(NSDictionary *service,NSError *error){RootViewController *owner=weakSelf;owner.navigationItem.prompt=nil;if(error){owner.pendingTVBoxExt=nil;owner.pendingTVBoxSiteName=nil;if(error.code!=NSURLErrorCancelled)[owner showServiceError:error.localizedDescription];return;}if(!service){[owner showServiceError:@"站点脚本导入失败"];return;}NSMutableDictionary *updated=[service mutableCopy];NSMutableDictionary *manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];NSString *ext=owner.pendingTVBoxExt,*name=owner.pendingTVBoxSiteName;if(ext.length)manifest[@"options"]=ext;if(name.length){manifest[@"name"]=name;updated[@"name"]=name;}updated[@"manifest"]=manifest;updated[@"tvboxSiteKey"]=site[@"key"]?:@"";owner.pendingTVBoxExt=nil;owner.pendingTVBoxSiteName=nil;[owner acceptImportedMedia:updated error:nil autoBrowse:browseAfterImport];}];
}
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error {
    [self acceptImportedMedia:service error:error autoBrowse:NO];
}
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error autoBrowse:(BOOL)autoBrowse {
    self.navigationItem.prompt=nil;if(error){if(error.code!=NSURLErrorCancelled)[self showServiceError:error.localizedDescription];return;}
    if(!service){[self showServiceError:@"资源导入失败"];return;}
    NSString *sourceURL=[service[@"url"] isKindOfClass:NSString.class]?service[@"url"]:@"";
    NSDictionary *existing=nil;
    if(sourceURL.length)for(NSDictionary *candidate in [ServiceStore services])if(![candidate[@"builtin"] boolValue]&&![candidate[@"id"] isEqual:service[@"id"]]&&[candidate[@"url"] isEqual:sourceURL]){existing=candidate;break;}
    if(existing){
        BOOL unchanged=[service[@"downloadChecksum"] length]&&[service[@"downloadChecksum"] isEqual:existing[@"downloadChecksum"]]&&[(service[@"configDownloadChecksum"]?:@"") isEqual:(existing[@"configDownloadChecksum"]?:@"")]&&[(service[@"configurationState"]?:@"") isEqual:(existing[@"configurationState"]?:@"")]&&[(service[@"configContentChecksum"]?:@"") isEqual:(existing[@"configContentChecksum"]?:@"")];
        for(NSString *key in @[@"runtime",@"protocol",@"moduleType",@"configEntry"])unchanged=unchanged&&[(service[@"manifest"][key]?:@"") isEqual:(existing[@"manifest"][key]?:@"")];
        if(unchanged){
            [ServiceStore remove:service[@"id"]];UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"未发现资源更新" message:@"本次主脚本、配套配置校验和运行类型与已有资源一致。" preferredStyle:UIAlertControllerStyleAlert];
            [notice addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [notice addAction:[UIAlertAction actionWithTitle:autoBrowse?@"启动并浏览资源":@"打开已有资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:existing]?@"vod":([ServiceStore subscriptionURLForService:existing].length?@"live":@"configuration");[self usePluginService:existing kind:kind];}else [self openPluginResource:[@"plugin:" stringByAppendingString:existing[@"id"]]];}]];
            [self presentViewController:notice animated:YES completion:nil];return;
        }
        NSString *identifier=[service[@"id"] copy];NSString *existingID=[existing[@"id"] copy];
        UIAlertController *duplicate=[UIAlertController alertControllerWithTitle:@"发现相同来源" message:@"检测到已导入过这个完整资源地址（含查询参数）。更新会先停止该服务，保留服务 ID、账号数据、端口、配置和日志，并保留上一版代码供切回。也可打开原资源或另存副本。" preferredStyle:UIAlertControllerStyleAlert];
        [duplicate addAction:[UIAlertAction actionWithTitle:@"更新已有资源（保留配置）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            dispatch_block_t update=^{NSError *error=nil;NSDictionary *updated=[ServiceStore replaceImportedService:existing withService:service error:&error];if(!updated){[ServiceStore remove:identifier];[self showServiceError:error.localizedDescription];return;}[self refreshConfigurationPage];if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:updated]?@"vod":([ServiceStore subscriptionURLForService:updated].length?@"live":@"configuration");[self usePluginService:updated kind:kind];}else [self openPluginResource:[@"plugin:" stringByAppendingString:existingID]];};
            if([PyHost isManagedServiceIdentifier:existingID])[self changeService:existing enabled:NO completion:^(NSError *error){if(error){[ServiceStore remove:identifier];[self showServiceError:error.localizedDescription];}else update();}];else update();
        }]];
        [duplicate addAction:[UIAlertAction actionWithTitle:@"取消本次导入" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[ServiceStore remove:identifier];}]];
        [duplicate addAction:[UIAlertAction actionWithTitle:@"保留为独立副本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self saveImportedMedia:service autoBrowse:autoBrowse];}]];
        [duplicate addAction:[UIAlertAction actionWithTitle:autoBrowse?@"启动并浏览已有资源":@"打开已有资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[ServiceStore remove:identifier];if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:existing]?@"vod":([ServiceStore subscriptionURLForService:existing].length?@"live":@"configuration");[self usePluginService:existing kind:kind];}else [self openPluginResource:[@"plugin:" stringByAppendingString:existingID]];}]];
        [self presentViewController:duplicate animated:YES completion:nil];return;
    }
    [self saveImportedMedia:service autoBrowse:autoBrowse];
}
- (void)saveImportedMedia:(NSDictionary *)service {
    [self saveImportedMedia:service autoBrowse:NO];
}
- (void)saveImportedMedia:(NSDictionary *)service autoBrowse:(BOOL)autoBrowse {
    [ServiceStore save:service];[self refreshConfigurationPage];
    NSArray *verifiedLocal=[service[@"manifest"][@"verifiedLocalChecksums"] isKindOfClass:NSArray.class]?service[@"manifest"][@"verifiedLocalChecksums"]:@[];
    NSString *verification=([service[@"downloadChecksum"] length]&&[service[@"configurationState"] isEqual:@"verified"])?@"主脚本与配套配置均已通过 MD5 校验。":(verifiedLocal.count?([service[@"downloadChecksum"] length]?[NSString stringWithFormat:@"下载资源及 ZIP 内 %@ 的 MD5 均已通过校验。",[verifiedLocal componentsJoinedByString:@"、"]]:[NSString stringWithFormat:@"ZIP 内已校验：%@。",[verifiedLocal componentsJoinedByString:@"、"]]):([service[@"downloadChecksum"] length]?@"下载资源 MD5 校验已通过。":@"可在资源详情查看校验与配套配置状态。"));
    if(autoBrowse){NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[self usePluginService:service kind:kind];return;}
    NSString *message=[NSString stringWithFormat:@"已检查并导入 %@。%@",service[@"name"],verification];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"资源已导入" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"启动并浏览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[self usePluginService:service kind:kind];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看能力与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]]];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {self.importingPlaylist=NO;self.importingMediaPackage=NO;self.importingTVBoxCatalog=NO;}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u=urls.firstObject;if(!u){self.importingPlaylist=NO;self.importingMediaPackage=NO;self.importingTVBoxCatalog=NO;return;}
    if(self.importingTVBoxCatalog){self.importingTVBoxCatalog=NO;BOOL scoped=[u startAccessingSecurityScopedResource];__weak typeof(self) weakSelf=self;self.navigationItem.prompt=@"正在读取 TVBox 配置…";dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *readError=nil;NSData *data=nil;NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:u error:&readError];@try{if(file)data=[file readDataUpToLength:2*1024*1024+1 error:&readError];}@catch(NSException *exception){readError=[NSError errorWithDomain:@"CCTVHostImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取所选 TVBox JSON 文件"}];}@finally{[file closeAndReturnError:NULL];if(scoped)[u stopAccessingSecurityScopedResource];}if(data.length>2*1024*1024){data=nil;readError=[NSError errorWithDomain:@"CCTVHostTVBox" code:2 userInfo:@{NSLocalizedDescriptionKey:@"TVBox 配置超过 2 MiB 上限"}];}NSError *parseError=nil;NSDictionary *catalog=data? [TVBoxCatalogStore parseData:data sourceURL:nil error:&parseError]:nil;dispatch_async(dispatch_get_main_queue(),^{RootViewController *owner=weakSelf;owner.navigationItem.prompt=nil;if(readError)[owner showServiceError:readError.localizedDescription];else if(parseError)[owner showServiceError:parseError.localizedDescription];else[owner acceptTVBoxCatalog:catalog];});});return;}
    if(self.importingMediaPackage){self.importingMediaPackage=NO;self.navigationItem.prompt=@"正在检查并导入资源…";BOOL scoped=[u startAccessingSecurityScopedResource];__weak typeof(self) weakSelf=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{NSError *error=nil;NSDictionary *service=nil;@try{service=[MediaPackageImporter importFile:u error:&error];}@finally{if(scoped)[u stopAccessingSecurityScopedResource];}dispatch_async(dispatch_get_main_queue(),^{[weakSelf acceptImportedMedia:service error:error];});}});return;}
    BOOL playlist=self.importingPlaylist;self.importingPlaylist=NO;
    BOOL scoped=[u startAccessingSecurityScopedResource];__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{@autoreleasepool {
        NSUInteger limit=(playlist?10:32)*1024*1024;NSError *readError=nil;NSData *data=nil;
        NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:u error:&readError];
        @try {if(file)data=[file readDataUpToLength:limit+1 error:&readError];}
        @catch(NSException *exception){readError=[NSError errorWithDomain:@"CCTVHostImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取所选资源文件"}];}
        @finally {[file closeAndReturnError:NULL];if(scoped)[u stopAccessingSecurityScopedResource];}
        if(data.length>limit){data=nil;readError=[NSError errorWithDomain:@"CCTVHostImport" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"文件超过 %lu MB 导入上限",(unsigned long)(limit/1024/1024)]}];}
        dispatch_async(dispatch_get_main_queue(), ^{if(readError){[weakSelf showServiceError:readError.localizedDescription];return;}[weakSelf finishResourceImport:data playlist:playlist name:u.lastPathComponent];});
    }});
}
- (void)finishResourceImport:(NSData *)data playlist:(BOOL)playlist name:(NSString *)name {
    if(playlist){[self importPlaylistData:data name:name];return;}
    NSError *error=nil;NSDictionary *backup=[HostBackup validatedBackup:data error:&error];if(!backup){[self showServiceError:error.localizedDescription];return;}
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"导入本机配置" message:@"将替换本机订阅、收藏和偏好。Python 服务代码单独导入，不受影响。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        for(NSString *source in self.subscriptionURLs.allObjects){self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];}
        [HostBackup restore:backup];self.subscriptionURLs=[NSMutableSet setWithArray:backup[@"subscriptions"]];self.favorites=[backup[@"favorites"] mutableCopy];self.recents=[[NSUserDefaults.standardUserDefaults arrayForKey:@"recents"] mutableCopy];self.activeSource=nil;self.gridMode=CCTVBoolPreference(@"channelGridMode",YES);for(NSString *source in self.subscriptionURLs)[self fetchSubscription:source silent:YES];[self activateAudioSession];[self applyFilter];[self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews.firstObject];
    }]];[self presentViewController:a animated:YES completion:nil];
}
- (PlaybackInfoViewController *)playbackInformationPage {
    PlaybackInfoViewController *v=[PlaybackInfoViewController new];__weak typeof(self) w=self;v.rowsProvider=^{NSString *engine=w.avPlayer?@"AVPlayer":(w.cicadaPlayer?@"CicadaPlayer":(w.currentPlayer?NSStringFromClass([w.currentPlayer class]):@"等待播放"));NSMutableArray *r=[NSMutableArray arrayWithArray:@[@{@"title":@"频道名称",@"value":w.channelName?:@"未选台"},@{@"title":@"频道 ID",@"value":w.channelID?:@"—"},@{@"title":@"播放引擎",@"value":engine},@{@"title":@"线路方式",@"value":w.routeName?:@"自动"},@{@"title":@"首帧耗时",@"value":w.firstRender?[NSString stringWithFormat:@"%.2f 秒",w.firstFrameSeconds]:@"等待画面"},@{@"title":@"应用版本",@"value":CCTVBuildTag()}]];
        if(w.requestedNativeRoute[@"url"])[r addObject:@{@"title":@"所选线路完整地址",@"value":[w displaySafeSourceURL:w.requestedNativeRoute[@"url"]]}];AVPlayerItem *item=w.avPlayer.currentItem;if(item){CGSize size=item.presentationSize;[r addObject:@{@"title":@"视频分辨率",@"value":size.width>0?[NSString stringWithFormat:@"%.0f × %.0f",size.width,size.height]:@"等待视频信息"}];AVPlayerItemAccessLogEvent *event=item.accessLog.events.lastObject;if(event)[r addObject:@{@"title":@"观测带宽",@"value":[NSString stringWithFormat:@"%.2f Mbps",event.observedBitrate/1000000.0]}];}else if(w.currentPlayer)[r addObject:@{@"title":@"SDK 报告节点",@"value":[NativeCDNPreference observedCDNDescriptionForPlayer:w.currentPlayer]}];return r;};return v;
}
- (NSString *)displaySafeSourceURL:(NSString *)raw {
    NSURLComponents *components=[NSURLComponents componentsWithString:raw?:@""];
    if(!components.host.length||![@[@"http",@"https"] containsObject:components.scheme.lowercaseString])return @"播放地址已隐藏";
    BOOL hidden=components.user.length||components.password.length;
    components.user=nil;components.password=nil;components.fragment=nil;
    NSString *value=components.string?:@"播放地址已隐藏";
    return hidden?[value stringByAppendingString:@" · 凭据已隐藏"]:value;
}
- (NSArray<NSDictionary *> *)playerCategoryRows {
    NSArray *groups=@[@"全部",@"央视",@"卫视",@"地方",@"教育",@"熊猫",@"订阅"];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSSet *favoriteIDs=[NSSet setWithArray:self.favorites?:@[]];NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary dictionary];
    for(NSDictionary *channel in self.allChannels){
        BOOL remote=[channel[@"remoteURL"] length]>0;if(!self.favoritesOnly&&remote!=self.subscriptionCatalog)continue;
        if(!remote&&(!CCTVBoolPreference(@"nativeChannelsEnabled",YES)||self.activeSource.length))continue;
        if(remote){NSMutableSet *owners=[NSMutableSet setWithArray:channel[@"subscriptionSources"]?:@[]];[owners minusSet:disabled];if(!owners.count||(self.activeSource.length&&![owners containsObject:self.activeSource]))continue;}
        if(self.favoritesOnly&&![favoriteIDs containsObject:channel[@"id"]?:@""])continue;
        NSString *query=self.query.lowercaseString;NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"";NSString *identifier=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
        if(query.length && ![name.lowercaseString containsString:query] && ![identifier.lowercaseString containsString:query])continue;
        counts[@"全部"]=@([counts[@"全部"] unsignedIntegerValue]+1);NSString *group=channel[@"group"]?:@"订阅";counts[group]=@([counts[group] unsignedIntegerValue]+1);
    }
    NSMutableArray *rows=[NSMutableArray array];for(NSUInteger i=0;i<groups.count;i++){NSString *group=groups[i];[rows addObject:@{@"index":@(i),@"title":group,@"detail":[NSString stringWithFormat:@"%lu 个频道",(unsigned long)[counts[group] unsignedIntegerValue]],@"selected":@(self.groupControl.selectedSegmentIndex==(NSInteger)i),@"symbol":i==0?@"square.grid.2x2":@"folder"}];}return rows;
}
- (CCTVPlaybackListPanelController *)categoryPanel {
    CCTVPlaybackListPanelController *panel=[CCTVPlaybackListPanelController new];panel.items=[self playerCategoryRows];panel.emptyMessage=@"当前没有可显示的频道分组";__weak typeof(self) weakSelf=self;
    panel.selectionHandler=^(NSDictionary *item){RootViewController *owner=weakSelf;if(!owner)return;owner.groupControl.selectedSegmentIndex=[item[@"index"] integerValue];[owner onGroupChanged];owner.playerTabs.selectedSegmentIndex=1;[owner selectPlayerPanel];};return panel;
}
- (CCTVPlaybackListPanelController *)routesPanel {
    CCTVPlaybackListPanelController *panel=[CCTVPlaybackListPanelController new];NSMutableArray *rows=[NSMutableArray array];NSDictionary *channel=[self channelWithID:self.channelID];
    if(self.currentRemoteURL.length){
        NSString *name=channel[@"name"]?:self.channelName?:@"订阅频道";NSArray *alternates=self.altSources[CCTVRouteGroupKey(channel)]?:@[self.currentRemoteURL];NSMutableSet *seen=[NSMutableSet set];NSUInteger index=0;
        for(NSString *url in alternates){NSString *stable=[self stableURLKey:url];if(!stable.length||[seen containsObject:stable])continue;[seen addObject:stable];index++;BOOL selected=[stable isEqualToString:self.currentRemoteURL];NSURL *target=[NSURL URLWithString:url];NSString *host=target.host?:@"播放源";NSString *title=alternates.count>1?[NSString stringWithFormat:@"播放源 %lu · %@",(unsigned long)index,host]:name;NSString *detail=[NSString stringWithFormat:@"%@ · %@",selected?@"当前播放":@"点按切换",[self displaySafeSourceURL:url]];[rows addObject:@{@"kind":@"remote",@"url":url,@"title":title,@"detail":detail,@"selected":@(selected),@"symbol":@"dot.radiowaves.left.and.right"}];}
    }else if(channel){
        NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];BOOL automatic=self.requestedNativeRoute==nil;
        [rows addObject:@{@"kind":@"automatic",@"title":@"SDK 自动选择",@"detail":@"由央视 SDK 调度并处理版权；节点未主动探测",@"selected":@(automatic),@"symbol":@"sparkles"}];
        for(NSDictionary *route in routes){NSString *provider=[route[@"provider"] isKindOfClass:NSString.class]?route[@"provider"]:@"线路";NSInteger width=[route[@"w"] integerValue],height=[route[@"h"] integerValue];NSString *resolution=width>0&&height>0?[NSString stringWithFormat:@"源标注 %ld × %ld",(long)width,(long)height]:@"源标注分辨率未知";NSString *url=[route[@"url"] isKindOfClass:NSString.class]?route[@"url"]:@"";BOOL selected=[provider caseInsensitiveCompare:self.requestedNativeRoute[@"provider"]?:@""]==NSOrderedSame;[rows addObject:@{@"kind":@"native",@"route":route,@"title":[NSString stringWithFormat:@"自选地址 %@",provider.uppercaseString],@"detail":[NSString stringWithFormat:@"%@ · 明文用 AVPlayer，其余交给央视 SDK\n%@",resolution,[self displaySafeSourceURL:url]],@"selected":@(selected),@"symbol":@"antenna.radiowaves.left.and.right"}];}
    }
    panel.items=rows;panel.emptyMessage=self.channelID.length?@"此频道没有可用的线路信息。可以使用顶部线路菜单或检查频道来源。":@"请先选择频道";__weak typeof(self) weakSelf=self;
    NSString *panelChannelID=self.channelID.copy;
    panel.selectionHandler=^(NSDictionary *item){RootViewController *owner=weakSelf;if(!owner||![owner.channelID isEqual:panelChannelID])return;NSDictionary *active=[owner channelWithID:owner.channelID];if([item[@"kind"] isEqual:@"remote"]){NSMutableDictionary *next=[(active?:@{@"id":owner.channelID?:@"",@"name":owner.channelName?:@"直播"}) mutableCopy];next[@"remoteURL"]=item[@"url"];[owner routePlayback:next];[owner configureCatalogNavigation];return;}if(!active)return;[owner playChannel:active route:[item[@"kind"] isEqual:@"native"]?item[@"route"]:nil];[owner configureCatalogNavigation];};return panel;
}
- (void)updatePlayerChannelLogoForChannel:(NSDictionary *)channel {
    NSString *logo=[channel[@"logo"] isKindOfClass:NSString.class]?channel[@"logo"]:@"";self.playerChannelLogo.image=nil;self.playerChannelLogo.hidden=!logo.length;self.playerChannelLogo.accessibilityIdentifier=logo;
}
- (void)loadPlayerChannelLogoAfterFirstFrame {
    NSString *url=self.playerChannelLogo.accessibilityIdentifier;if(url.length&&self.firstRender)[[HostImageLoader shared] loadURL:url intoImageView:self.playerChannelLogo];
}
- (void)selectPlayerPanel {
    if(self.playbackPanel){[self.playbackPanel willMoveToParentViewController:nil];[self.playbackPanel.view removeFromSuperview];[self.playbackPanel removeFromParentViewController];self.playbackPanel=nil;}
    NSInteger index=self.playerTabs.selectedSegmentIndex;UIViewController *v=nil;
    if(index==0)v=[self categoryPanel];else if(index==2)v=[self epgPageForChannel:self.channelID name:self.channelName];else if(index==3)v=[self routesPanel];
    if(v){self.playbackPanel=v;[self addChildViewController:v];[self.view addSubview:v.view];[v didMoveToParentViewController:self];}[self.view setNeedsLayout];
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
    NSString *sourceKey=url.absoluteString?:@"";NSString *managedID=[ProfileStore metadata:sourceKey][@"managedServiceID"];
    NSArray<NSDictionary *> *services=[ServiceStore services];
    if([managedID isKindOfClass:NSString.class]&&managedID.length)for(NSDictionary *service in services)if([service[@"id"] isEqual:managedID]&&[service[@"port"] integerValue]==port)return service;
    NSMutableArray<NSDictionary *> *matches=[NSMutableArray array];for(NSDictionary *service in services)if([service[@"port"] integerValue]==port)[matches addObject:service];
    if(matches.count==1)return matches.firstObject;
    // A duplicated port is ambiguous. Prefer the only live owner; never start
    // whichever service happens to appear first in persisted configuration.
    NSDictionary *running=nil;for(NSDictionary *service in matches)if([PyHost isRunningServiceIdentifier:service[@"id"]]){if(running)return nil;running=service;}
    return running;
}
- (NSDictionary *)localServiceForChannel:(NSDictionary *)channel URL:(NSURL *)url {
    NSString *host=url.host.lowercaseString;if(![@[@"127.0.0.1",@"localhost",@"::1",@"[::1]"] containsObject:host])return nil;
    NSInteger port=url.port?url.port.integerValue:([url.scheme.lowercaseString isEqualToString:@"https"]?443:80);
    NSMutableDictionary<NSString *,NSDictionary *> *owners=[NSMutableDictionary dictionary];
    for(NSString *source in [ProfileStore orderedSources:channel[@"subscriptionSources"]?:@[]]){NSString *identifier=[ProfileStore metadata:source][@"managedServiceID"];if(![identifier isKindOfClass:NSString.class]||!identifier.length)continue;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:identifier]&&[service[@"port"] integerValue]==port)owners[identifier]=service;}
    if(owners.count==1)return owners.allValues.firstObject;
    if(owners.count>1){NSDictionary *running=nil;for(NSDictionary *service in owners.allValues)if([PyHost isRunningServiceIdentifier:service[@"id"]]){if(running)return nil;running=service;}if(running)return running;return nil;}
    return [self localServiceForURL:url];
}
- (NSArray<NSString *> *)managedSubscriptionSourcesForService:(NSDictionary *)service excludingURL:(NSString *)url {
    NSString *identifier=[service[@"id"] isKindOfClass:NSString.class]?service[@"id"]:@"";if(!identifier.length)return @[];
    NSMutableArray<NSString *> *matches=[NSMutableArray array];
    for(NSString *source in self.subscriptionURLs){if([source isEqual:url])continue;if([[ProfileStore metadata:source][@"managedServiceID"] isEqual:identifier])[matches addObject:source];}
    return matches;
}
- (LocalServiceReadiness *)readinessForURL:(NSURL *)url service:(NSDictionary *)service {
    NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    BOOL health=[service[@"builtin"] boolValue] || [ServiceStore isMediaService:service];
    if(health)c.path=@"/health";else if(!c.path.length)c.path=[ServiceStore playlistPathForService:service]?:@"/";
    c.query=nil;c.fragment=nil;
    LocalServiceReadiness *readiness=[[LocalServiceReadiness alloc] initWithURL:c.URL timeout:20 requiresHealthJSON:health];readiness.diagnosticContext=@{@"service_id":service[@"id"]?:@"",@"trigger":@"local_channel_playback"};NSString *engine=[service[@"engine"] isKindOfClass:NSString.class]?service[@"engine"]:@"python";if(service && [engine isEqualToString:@"python"]){NSString *identifier=[service[@"id"] copy];readiness.failureProvider=^NSError *{return [PyHost startupErrorForServiceIdentifier:identifier];};}return readiness;
}
- (BOOL)startService:(NSDictionary *)service error:(NSError **)error {
    service=[ServiceStore resolvedService:service];
    NSString *entryPath=[ServiceStore codePath:service];
    if([service[@"manifest"] isKindOfClass:NSDictionary.class] && (!entryPath.length || ![NSFileManager.defaultManager fileExistsAtPath:entryPath])){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:8 userInfo:@{NSLocalizedDescriptionKey:@"资源入口文件不存在。已检查当前 App 沙盒中的同一服务目录；请从“资源”重新导入原文件。原服务配置和日志会保留。"}];return NO;}
    NSString *serviceID=service[@"id"];
    [ServiceStore associateLegacyLoopbackSubscriptionsForService:service];
    if([PyHost isRunningServiceIdentifier:serviceID])return YES;
    if([PyHost isManagedServiceIdentifier:serviceID]){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:7 userInfo:@{NSLocalizedDescriptionKey:@"该服务仍有启动中或状态待确认的会话，请先停止并确认清理后重试。"}];return NO;}
    NSInteger port=[service[@"port"] integerValue];if(port<1||port>65535){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:5 userInfo:@{NSLocalizedDescriptionKey:@"服务端口必须是 1 到 65535 之间的有效端口。"}];return NO;}
    for(NSDictionary *other in [ServiceStore services])if(![other[@"id"] isEqual:serviceID]&&[other[@"port"] integerValue]==port&&[PyHost isManagedServiceIdentifier:other[@"id"]]){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:6 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"端口 %ld 正由“%@”使用或待清理，请先停止该服务。",(long)port,other[@"name"]?:other[@"id"]]}];return NO;}
    NSString *dataDir=[ServiceStore dataDirectoryForService:service error:error];if(!dataDir.length)return NO;
    NSString *bind=[service[@"lan"] boolValue]?@"0.0.0.0":@"127.0.0.1";NSMutableArray *args=[NSMutableArray array];
    if([ServiceStore isMediaService:service]){
        NSData *data=[NSJSONSerialization dataWithJSONObject:service[@"manifest"] options:0 error:error];if(!data)return NO;
        [args addObjectsFromArray:@[[NSString stringWithFormat:@"%ld",(long)port],@"--bind",bind,@"--package",service[@"packageRoot"],@"--manifest",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding],@"--data-dir",dataDir]];
    }else if([service[@"builtin"] boolValue]){
        [args addObjectsFromArray:@[[NSString stringWithFormat:@"%ld",(long)port],@"--bind",bind,@"--data-dir",dataDir]];
        if(![service[@"id"] isEqual:@"builtin-yangshipin-js"])[args addObjectsFromArray:@[@"--no-engine",@"--cache-mb",@"32",@"--links-per-device",@"2",@"--zap-debounce",@"15",@"--stable-playback"]];
    }else{
        for(NSString *part in [service[@"arguments"]?:@"" componentsSeparatedByString:@"|"]){if(!part.length)continue;NSString *arg=[part stringByReplacingOccurrencesOfString:@"{port}" withString:[NSString stringWithFormat:@"%ld",(long)port]];arg=[arg stringByReplacingOccurrencesOfString:@"{bind}" withString:bind];[args addObject:[arg stringByReplacingOccurrencesOfString:@"{dataDir}" withString:dataDir]];}
    }
    __weak typeof(self) w=self;serviceID=[serviceID copy];NSString *serviceName=[service[@"name"] copy];[PluginLogStore.shared beginRunForIdentifier:serviceID];void(^serviceLogger)(NSString *)=^(NSString *line){if(line.length)[w logPluginLine:line identifier:serviceID name:serviceName];};[PyHost setLogHandler:serviceLogger forServiceIdentifier:serviceID];[NodePluginRuntime.shared setLogHandler:serviceLogger forServiceIdentifier:serviceID];[JSPluginRuntime.shared setLogHandler:serviceLogger forServiceIdentifier:serviceID];
    [self logPluginLine:@"插件启动请求" identifier:serviceID name:serviceName];
    for(NSString *origin in self.readyLocalOrigins.allKeys.copy){NSURL *known=[NSURL URLWithString:origin];if(known.port.integerValue==port)[self.readyLocalOrigins removeObjectForKey:origin];} // This service must prove readiness again.
    if(![PyHost startScriptAtPath:[ServiceStore scriptPath:service] identifier:serviceID port:port dataDir:dataDir arguments:args error:error]){if(error&&*error)[self logPluginLine:(*error).localizedDescription identifier:serviceID name:serviceName];[PluginLogStore.shared finishRunForIdentifier:serviceID status:@"启动失败"];[self clearServiceLogHandlers:serviceID];return NO;}
    [PluginLogStore.shared markRunRunningForIdentifier:serviceID];
    [NSUserDefaults.standardUserDefaults setObject:service[@"id"] forKey:@"activePythonService"];
    [self log:@"服务进程启动 %@ · %ld，等待 HTTP 就绪",service[@"name"],(long)port];
    NSString *playlistURL=[ServiceStore subscriptionURLForService:service];
    if(playlistURL.length){
        NSArray<NSString *> *previousSources=[self managedSubscriptionSourcesForService:service excludingURL:playlistURL];
        NSDictionary *newMetadata=[ProfileStore metadata:playlistURL];
        BOOL alreadySubscribed=[self.subscriptionURLs containsObject:playlistURL];
        if(!alreadySubscribed){[self.subscriptionURLs addObject:playlistURL];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];}
        NSMutableDictionary *sourceMetadata=[@{@"managedServiceID":serviceID} mutableCopy];
        if(![newMetadata[@"name"] isKindOfClass:NSString.class]||![newMetadata[@"name"] length]){NSString *previousName=nil;for(NSString *oldSource in previousSources){id candidate=[ProfileStore metadata:oldSource][@"name"];if([candidate isKindOfClass:NSString.class]&&[candidate length]){previousName=candidate;break;}}sourceMetadata[@"name"]=previousName?:serviceName?:@"本机直播服务";}
        if(![newMetadata[@"epgURL"] isKindOfClass:NSString.class]||![newMetadata[@"epgURL"] length])for(NSString *oldSource in previousSources){id configured=[ProfileStore metadata:oldSource][@"epgURL"];if([ProfileStore isHTTP:configured]){sourceMetadata[@"epgURL"]=configured;break;}}
        [ProfileStore update:playlistURL values:sourceMetadata];
        for(NSString *oldSource in previousSources)[ProfileStore update:oldSource values:@{@"status":@"服务端口或列表路径已变更 · 等待新订阅验证，保留旧频道"}];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:playlistURL];
        for(NSString *oldSource in previousSources)[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:oldSource];
        [self logPluginLine:[NSString stringWithFormat:@"服务订阅地址：%@",playlistURL] identifier:serviceID name:serviceName];
        NSString *epg=[ServiceStore epgURLForService:service];
        [self logPluginLine:epg.length?[NSString stringWithFormat:@"节目单地址：%@",CCTVServiceLogAddress(epg)]:@"节目单地址：等待读取订阅清单后识别" identifier:serviceID name:serviceName];
    }else if([service[@"protocol"] isEqual:@"python-http"]){
        [self logPluginLine:@"未发现可用的服务订阅地址：请在服务编辑页配置播放列表路径，启动不会添加猜测地址。" identifier:serviceID name:serviceName];
    }
    for(NSString *source in self.subscriptionURLs.allObjects){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:source]];if([owner[@"id"] isEqualToString:service[@"id"]])[self fetchSubscription:source silent:YES];}
    [self refreshConfigurationPage];
    [self.pluginPage updateRunning:[PyHost isRunningServiceIdentifier:@"builtin-ysp"] subscriptionCount:self.subscriptionURLs.count];return YES;
}
- (void)toggleService:(NSDictionary *)service enabled:(BOOL)enabled {
    [self changeService:service enabled:enabled completion:^(NSError *error){if(error)[self showServiceError:error.localizedDescription];}];
}
- (void)restartMediaService:(NSDictionary *)source completion:(void (^)(NSError *))completion {
    NSString *identifier=source[@"id"]?:@"";NSDictionary *snapshot=nil;
    for(NSDictionary *candidate in ServiceStore.services)if([candidate[@"id"] isEqual:identifier]){snapshot=candidate;break;}
    NSError *(^failure)(NSString *)=^NSError *(NSString *message){return [NSError errorWithDomain:@"CCTVHostServiceRecovery" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];};
    if(!snapshot||![snapshot[@"port"] isEqual:source[@"port"]]){if(completion)completion(failure(@"资源已移除或端口已修改，请重新选择来源。"));return;}
    if(!self.serviceOperations)self.serviceOperations=[NSMutableSet set];
    if([self.serviceOperations containsObject:identifier]){if(completion)completion(failure(@"该服务已有启停操作，请等待当前操作完成。"));return;}
    [self.serviceOperations addObject:identifier];
    [RuntimeDiagnostics.shared recordEvent:@"service_recovery_started" category:@"service" fields:@{@"service_id":identifier,@"port":snapshot[@"port"]?:@0,@"trigger":@"user_restart"}];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        __block NSError *error=nil;BOOL stopped=[PyHost stopServiceIdentifier:identifier error:&error];
        int portState=stopped?HostLocalPortState([snapshot[@"port"] intValue]):-1;
        if(stopped&&portState!=0)error=failure(portState==1?@"旧服务停止后端口仍可访问，已阻止重复启动。请检查是否有其他服务占用该端口。":@"无法确认旧端口已释放，已阻止重复启动。请稍后重试。 ");
        if(!stopped&&!error)error=failure(@"服务停止未确认，已取消重新启动。请查看该服务日志。 ");
        dispatch_async(dispatch_get_main_queue(),^{
            BOOL unchanged=NO;for(NSDictionary *candidate in ServiceStore.services)if([candidate[@"id"] isEqual:identifier]){unchanged=[candidate isEqualToDictionary:snapshot];break;}
            if(stopped){[self logPluginLine:@"重启前旧服务已停止" identifier:identifier name:snapshot[@"name"]?:identifier];[PluginLogStore.shared finishRunForIdentifier:identifier status:@"重启前已停止"];}
            if(!error&&!unchanged)error=failure(@"重启期间资源配置已变更，已取消启动。请重新选择来源。 ");
            if(!error){[self clearServiceLogHandlers:identifier];NSError *startError=nil;if(![self startService:snapshot error:&startError])error=startError?:failure(@"重新启动请求失败，请查看服务日志。 ");}
            [self.serviceOperations removeObject:identifier];
            [RuntimeDiagnostics.shared recordEvent:@"service_recovery_finished" category:@"service" fields:@{@"service_id":identifier,@"phase":@"start_request_finished",@"http_health_verified":@NO,@"stop_confirmed":@(stopped),@"port_released":@(stopped&&portState==0),@"start_accepted":@(!error),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];
            [self refreshConfigurationPage];if(completion)completion(error);
        });
    });
}
- (void)changeService:(NSDictionary *)service enabled:(BOOL)enabled completion:(void (^)(NSError *))completion {
    NSString *serviceID=service[@"id"]?:@"";if(!self.serviceOperations)self.serviceOperations=[NSMutableSet set];
    if([self.serviceOperations containsObject:serviceID]){if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:4 userInfo:@{NSLocalizedDescriptionKey:@"该服务正在启停，请稍候。"}]);return;}
    if(enabled && [PyHost isRunningServiceIdentifier:serviceID]){
        [self refreshConfigurationPage];if(completion)completion(nil);return;
    }
    if(enabled){
        NSError *error=nil;BOOL started=[self startService:service error:&error];
        [RuntimeDiagnostics.shared recordEvent:started?@"service_start_accepted":@"service_start_failed" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0, @"start_phase":started?@"request_accepted":@"rejected", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];
        [self refreshConfigurationPage];if(completion)completion(error);return;
    }
    [self.serviceOperations addObject:serviceID];
    [RuntimeDiagnostics.shared recordEvent:@"service_stop_requested" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0}];
    [self log:@"正在停止服务 %@",service[@"name"]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *stopError=nil;BOOL stopped=[PyHost stopServiceIdentifier:serviceID error:&stopError];
        dispatch_async(dispatch_get_main_queue(),^{
            [self.serviceOperations removeObject:serviceID];[RuntimeDiagnostics.shared recordEvent:stopped?@"service_stopped":@"service_stop_failed" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0, @"error_domain":stopError.domain?:@"", @"error_code":@(stopError.code), @"error_message":stopError.localizedDescription?:@""}];if(!stopped){if(completion)completion(stopError);[self refreshConfigurationPage];return;}
            [self completeServiceStopForIdentifier:serviceID];[self refreshConfigurationPage];if(completion)completion(nil);
        });
    });
}
- (void)completeServiceStopForIdentifier:(NSString *)serviceID {
    [(MediaBrowserViewController *)self.tabPages[@2] invalidateServiceIdentifier:serviceID];
    NSDictionary *stopped=nil;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqualToString:serviceID]){stopped=service;break;}if(serviceID.length){[self logPluginLine:@"插件服务已停止" identifier:serviceID name:stopped[@"name"]?:@"插件"];[PluginLogStore.shared finishRunForIdentifier:serviceID status:@"已停止"];}
    for(NSString *source in self.subscriptionURLs.allObjects){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:source]];if([owner[@"id"] isEqual:serviceID]){[ProfileStore update:source values:@{@"status":@"服务已停止 · 保留最近一次频道清单"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:source];}}
    for(NSString *origin in self.readyLocalOrigins.allKeys.copy){for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqualToString:serviceID] && [origin containsString:[NSString stringWithFormat:@":%@",service[@"port"]]])[self.readyLocalOrigins removeObjectForKey:origin];}
    if(stopped[@"port"]){NSInteger stoppedPort=[stopped[@"port"] integerValue];for(NSString *origin in self.readyLocalOrigins.allKeys.copy)if([NSURL URLWithString:origin].port.integerValue==stoppedPort)[self.readyLocalOrigins removeObjectForKey:origin];for(NSString *key in self.subscriptionReadiness.allKeys.copy){NSDictionary *owner=[self localServiceForURL:[NSURL URLWithString:key]];if([owner[@"id"] isEqualToString:serviceID]){[self.subscriptionReadiness[key] cancel];[self.subscriptionReadiness removeObjectForKey:key];}}}
    NSDictionary *currentService=[self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]];
    if([currentService[@"id"] isEqualToString:serviceID]){
        self.playbackGeneration++;[self stopPlayback];[self.spinner stopAnimating];self.titleLabel.hidden=NO;self.titleLabel.text=@"本机服务已停止";
    }
    [self log:@"服务 %@ 已停止，保留订阅供下次启动续播",stopped[@"name"]?:serviceID];
    [self clearServiceLogHandlers:serviceID];
}
- (void)showServiceError:(NSString *)message {[self log:@"服务操作失败：%@",message?:@"未知错误"];UIAlertController *a=[UIAlertController alertControllerWithTitle:@"服务" message:message?:@"服务操作失败，请查看日志。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];UIViewController *top=self.navigationController.topViewController?:self;[top presentViewController:a animated:YES completion:nil];}
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

- (void)loadLogo:(NSString *)url into:(UIImageView *)iv {
    if(CACurrentMediaTime()<self.playbackPriorityUntil){iv.image=nil;iv.accessibilityIdentifier=url;return;}
    [[HostImageLoader shared] loadURL:url intoImageView:iv];
}

#pragma mark - 搜索 / 最近 / 节目单缓存

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    if(self.activeTab>=2)return;
    self.query = sc.searchBar.text;
    NSUInteger generation=++self.catalogSearchGeneration;
    if(!self.query.length){[self applyFilter];return;}
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(generation==weakSelf.catalogSearchGeneration && weakSelf.activeTab<2)[weakSelf applyFilter];
    });
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
    NSMutableDictionary<NSString *,NSNumber *> *ranks=[NSMutableDictionary dictionary];
    for(NSUInteger index=0;index<self.favorites.count;index++)if(!ranks[self.favorites[index]])ranks[self.favorites[index]]=@(index);
    NSArray *sorted = [base sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSNumber *left=ranks[a[@"id"]?:@""],*right=ranks[b[@"id"]?:@""];
        if(left && right)return [left compare:right];
        if(left || right)return left?NSOrderedAscending:NSOrderedDescending;
        return NSOrderedSame;
    }];
    self.shownChannels = sorted;
    [self.table reloadData];
    [self.channelGrid reloadData];
    NSString *empty=self.query.length?@"没有找到匹配频道":(self.favoritesOnly?@"还没有收藏频道，长按频道即可收藏":(self.subscriptionCatalog?@"暂无订阅频道\n点击右上角更多 → 添加订阅，或在资源中导入播放列表":@"暂无官方频道，请在资源中启用官方频道"));
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
    if(self.subscriptionCatalog||self.activeTab==3){for(NSString *u in self.subscriptionURLs.allObjects)[self fetchSubscription:u silent:NO];}
    else{[self.epgCache removeAllObjects];[self saveEPGCache];if(self.firstRender)[self refreshNowNext];[self applyFilter];}
    [self.table.refreshControl endRefreshing];[self.channelGrid.refreshControl endRefreshing];
}

- (void)loadEPGForChannel:(NSString *)cid section:(NSIndexPath *)ip {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)) return;
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
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
    ResourceImportSheetViewController *sheet=[ResourceImportSheetViewController new];
    sheet.modalPresentationStyle=UIModalPresentationPageSheet;
    __weak typeof(self) weakSelf=self;
    sheet.onSelect=^(ResourceImportOption option){
        RootViewController *owner=weakSelf;if(!owner)return;
        switch(option){
            case ResourceImportOptionLiveURL:[owner addSubscriptionURL];break;
            case ResourceImportOptionMediaURL:[owner importMediaURL];break;
            case ResourceImportOptionLiveFile:{
                owner.importingPlaylist=YES;owner.importingMediaPackage=NO;
                UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
                picker.delegate=owner;
                [owner presentViewController:picker animated:YES completion:nil];
            }break;
            case ResourceImportOptionMediaFile:[owner importMediaPackage];break;
            case ResourceImportOptionServices:[owner openServicesPage];break;
            case ResourceImportOptionTVBox:[owner importTVBoxCatalog];break;
            case ResourceImportOptionMacCMS:[owner importMacCMSAPI];break;
        }
    };
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)addSubscriptionURL {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"添加订阅"
                                                              message:@"输入 M3U / TXT 直播列表地址，例如插件输出的 http://127.0.0.1:8767/all.m3u"
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
    BOOL isHTTPSource=[ProfileStore isHTTP:sourceKey];
    if(silent && CACurrentMediaTime()<self.playbackPriorityUntil){[self.deferredLocalSubscriptions addObject:sourceKey];[ProfileStore update:sourceKey values:@{@"status":@"起播中，稍后自动刷新"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];return;}
    NSString *traceID=nil;if(isHTTPSource){traceID=self.subscriptionTraceIDs[sourceKey];if(!traceID.length){traceID=NSUUID.UUID.UUIDString.lowercaseString;self.subscriptionTraceIDs[sourceKey]=traceID;}}
    // Exact normalized source URLs, including query parameters, are independent
    // request identities. A repeat of the same URL joins the work already in flight.
    if(self.subscriptionTasks[sourceKey]){NSMutableDictionary *fields=[@{@"source_type":isHTTPSource?@"http":@"imported_text", @"correlation_id":traceID?:@""} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:sourceKey])];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_joined_existing" category:@"subscription" fields:fields];[ProfileStore update:sourceKey values:@{@"status":@"刷新已合并 · 当前请求仍在进行"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[self refreshConfigurationPage];return;}
    [ProfileStore update:sourceKey values:@{@"status":@"刷新中…"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[self refreshConfigurationPage];
    if(![ProfileStore isHTTP:sourceKey]){NSString *text=[ProfileStore metadata:sourceKey][@"text"];[self applyPlaylistText:text source:sourceKey];return;}
    NSURL *sourceURL=[NSURL URLWithString:sourceKey];NSDictionary *localService=[self localServiceForURL:sourceURL];
    if(localService){
        if(![PyHost isRunningServiceIdentifier:localService[@"id"]]){
            if(![self.deferredLocalSubscriptions containsObject:sourceKey])[self log:@"本机订阅暂缓加载，等待服务启动 %@",CCTVServiceLogAddress(sourceKey)];
            [self.deferredLocalSubscriptions addObject:sourceKey];[ProfileStore update:sourceKey values:@{@"status":@"等待本机服务启动"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[self refreshConfigurationPage];return;
        }
        NSString *origin=[self originForURL:sourceURL];NSNumber *readyAt=self.readyLocalOrigins[origin];
        if(!readyAt||CACurrentMediaTime()-readyAt.doubleValue>2){
            if(self.subscriptionReadiness[sourceKey])return;
            NSUInteger readinessVersion=[self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]+1;self.subscriptionRequestVersions[sourceKey]=@(readinessVersion);
            LocalServiceReadiness *probe=[self readinessForURL:sourceURL service:localService];self.subscriptionReadiness[sourceKey]=probe;__weak typeof(self) w=self;
            [probe start:^(NSError *error,NSTimeInterval elapsed){
                if(w.subscriptionReadiness[sourceKey]!=probe)return;[w.subscriptionReadiness removeObjectForKey:sourceKey];
                if([w.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]!=readinessVersion||![w.subscriptionURLs containsObject:sourceKey])return;
                NSMutableDictionary *probeFields=[@{@"correlation_id":traceID?:@"", @"service_id":localService[@"id"]?:@"", @"service_name":localService[@"name"]?:@"", @"engine":localService[@"engine"]?:@"python", @"port":localService[@"port"]?:@0, @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:probe.diagnosticSummary];[probeFields addEntriesFromDictionary:CCTVDiagnosticURLFields(sourceURL)];
                if(error){probeFields[@"error_domain"]=error.domain?:@"";probeFields[@"error_code"]=@(error.code);probeFields[@"error_message"]=error.localizedDescription?:@"";[RuntimeDiagnostics.shared recordEvent:@"local_service_health_failed" category:@"service" fields:probeFields];[ProfileStore update:sourceKey values:@{@"status":error.localizedDescription?:@"服务未就绪"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[w refreshConfigurationPage];[w logPluginLine:[NSString stringWithFormat:@"订阅接口健康检查失败 · %@",[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"]] identifier:localService[@"id"] name:localService[@"name"]];[w log:@"本机订阅等待服务失败 %@",error.localizedDescription];return;}
                [RuntimeDiagnostics.shared recordEvent:@"local_service_health_ready" category:@"service" fields:probeFields];[w logPluginLine:[NSString stringWithFormat:@"订阅接口健康检查通过 · %.2f 秒",elapsed] identifier:localService[@"id"] name:localService[@"name"]];
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
    __weak typeof(self) weakSelf = self;NSTimeInterval requestStartedAt=CACurrentMediaTime();
    NSMutableDictionary *subscriptionFields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"timeout_seconds":@12} mutableCopy];[subscriptionFields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];
    [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_started" category:@"subscription" fields:subscriptionFields];
    NSURLSessionDataTask *subscriptionTask=[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status=[resp isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)resp statusCode]:0;
        NSUInteger receivedBytes=data.length;NSString *mimeType=resp.MIMEType?:@"";
        if(status<200||status>=300||data.length>10*1024*1024)data=nil;
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSError *parseError=nil;
        NSArray<M3UChannel *> *list = text.length ? [M3UParser parse:text baseURL:url error:&parseError] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([weakSelf.subscriptionRequestVersions[sourceKey] unsignedIntegerValue] != requestVersion) return;
            [weakSelf.subscriptionTasks removeObjectForKey:sourceKey];
            if (!list.count) {
                NSString *failureStage=err?@"network_or_timeout":(parseError?@"parse_limit":((status<200||status>=300)?@"http_status":(receivedBytes>10*1024*1024?@"response_too_large":(receivedBytes==0?@"empty_response":(text.length?@"no_valid_channels":@"invalid_utf8")))));
                NSMutableDictionary *fields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"http_status":@(status), @"response_mime_type":mimeType, @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-requestStartedAt)*1000)), @"error_domain":err.domain?:@"", @"error_code":@(err.code), @"error_message":err.localizedDescription?:@"", @"received_bytes":@(receivedBytes), @"failure_stage":failureStage} mutableCopy];
                [fields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];
                [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:fields];
                [weakSelf.subscriptionTraceIDs removeObjectForKey:sourceKey];
                NSDictionary *sourceMetadata=[ProfileStore metadata:sourceKey];id cachedChannels=sourceMetadata[@"cachedChannels"];
                NSUInteger retainedCount=[cachedChannels isKindOfClass:NSArray.class]?[(NSArray *)cachedChannels count]:0;
                if(!retainedCount)for(NSDictionary *channel in weakSelf.allChannels)if([channel[@"subscriptionSources"] containsObject:sourceKey])retainedCount++;
                NSString *reason=err.localizedDescription?:parseError.localizedDescription?:[NSString stringWithFormat:@"HTTP %ld / 无有效 M3U",(long)status];
                NSString *statusText=retainedCount?[NSString stringWithFormat:@"刷新失败 · 保留上次 %lu 个频道 · %@",(unsigned long)retainedCount,reason]:[NSString stringWithFormat:@"刷新失败 · %@",reason];
                [ProfileStore update:sourceKey values:@{@"status":statusText}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[weakSelf refreshConfigurationPage];
                if(localService)[weakSelf logPluginLine:[NSString stringWithFormat:@"订阅地址读取失败 · %@",[HostLogRedactor redactText:reason]] identifier:localService[@"id"] name:localService[@"name"]];
                [weakSelf log:@"订阅失败 %@ %@", CCTVServiceLogAddress(urlString), [HostLogRedactor redactText:err.localizedDescription ?: @"无有效条目"]];
                return;
            }
            NSMutableDictionary *fields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"http_status":@(status), @"response_mime_type":mimeType, @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-requestStartedAt)*1000)), @"channel_count":@(list.count), @"received_bytes":@(receivedBytes)} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_succeeded" category:@"subscription" fields:fields];[weakSelf.subscriptionTraceIDs removeObjectForKey:sourceKey];
            NSString *detected=[M3UParser epgURL:text baseURL:url];if(detected.length){NSString *prior=[ProfileStore metadata:sourceKey][@"detectedEPGURL"]?:[ProfileStore metadata:sourceKey][@"epgURL"];[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];if(![prior isEqual:detected])[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];if(localService&&![prior isEqual:detected])[weakSelf logPluginLine:[NSString stringWithFormat:@"节目单地址：%@",CCTVServiceLogAddress(detected)] identifier:localService[@"id"] name:localService[@"name"]];}
            if(localService)[weakSelf logPluginLine:[NSString stringWithFormat:@"订阅清单可读取 · %lu 个频道",(unsigned long)list.count] identifier:localService[@"id"] name:localService[@"name"]];
            [weakSelf installPlaylist:list source:sourceKey];
        });
    }];self.subscriptionTasks[sourceKey]=subscriptionTask;[subscriptionTask resume];
}
- (void)installPlaylist:(NSArray<M3UChannel *> *)list source:(NSString *)sourceKey {
            NSDictionary *managedService=[self localServiceForURL:[NSURL URLWithString:sourceKey]];
            NSArray<NSString *> *retiredManagedSources=managedService?[self managedSubscriptionSourcesForService:managedService excludingURL:sourceKey]:@[];
            NSSet<NSString *> *retiredSourceSet=[NSSet setWithArray:retiredManagedSources];
            NSMutableArray *merged = [NSMutableArray array];
            for (NSDictionary *existing in self.allChannels ?: @[]) {
                NSArray *originalOwners=existing[@"subscriptionSources"]?:@[];NSMutableSet *owners = [NSMutableSet setWithArray:originalOwners];
                [owners minusSet:retiredSourceSet];
                if ([owners containsObject:sourceKey]) {
                    [owners removeObject:sourceKey];
                    if (!owners.count) continue;
                    NSMutableDictionary *copy = [existing mutableCopy];
                    copy[@"subscriptionSources"] = owners.allObjects;
                    [merged addObject:copy];
                } else if(!owners.count) {
                    // Built-in SDK channels have no subscription owner. Keep them
                    // when replacing a playlist; only discard channels that were
                    // owned by a subscription and became orphaned above.
                    if (!originalOwners.count) [merged addObject:existing];
                } else if(owners.count!=originalOwners.count) {
                    NSMutableDictionary *copy=[existing mutableCopy];copy[@"subscriptionSources"]=owners.allObjects;[merged addObject:copy];
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
                NSNumber *existingIndex = urlIndexes[stable];
                if (existingIndex) {
                    NSMutableDictionary *entry = [merged[existingIndex.unsignedIntegerValue] mutableCopy];
                    NSMutableSet *owners = [NSMutableSet setWithArray:entry[@"subscriptionSources"] ?: @[]];
                    [owners addObject:sourceKey];
                    entry[@"subscriptionSources"] = owners.allObjects;
                    entry[@"name"] = c.name;
                    entry[@"group"] = c.group ?: @"订阅";
                    if (c.epgID.length) entry[@"epgID"]=c.epgID;
                    if (c.tvgName.length) entry[@"tvgName"]=c.tvgName; else [entry removeObjectForKey:@"tvgName"];
                    if (c.logo.length) entry[@"logo"] = c.logo; else [entry removeObjectForKey:@"logo"];
                    if (c.headers.count) entry[@"headers"] = c.headers; else [entry removeObjectForKey:@"headers"];
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
                    if (c.tvgName.length) entry[@"tvgName"]=c.tvgName;
                    if (c.logo.length) entry[@"logo"] = c.logo;
                    if (c.headers.count) entry[@"headers"] = c.headers;
                    urlIndexes[stable] = @(merged.count);
                    [merged addObject:entry];
                    added++;
                }
            }
            if(merged.count>20000){NSString *message=@"合并后频道数量超过 20000 条安全上限，已保留上次有效订阅";[ProfileStore update:sourceKey values:@{@"status":message}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"playlist",@"failure_stage":@"merged_channel_limit",@"channel_count":@(merged.count)}];[self refreshConfigurationPage];[self log:@"%@",message];return;}
            NSArray *owned=[merged filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *b){return [c[@"subscriptionSources"] containsObject:sourceKey];}]];
            NSData *snapshot=[NSJSONSerialization dataWithJSONObject:owned options:0 error:NULL];
            if(!snapshot.length||snapshot.length>4*1024*1024){NSString *message=@"频道快照超过 4 MiB 安全上限，已保留上次有效订阅";[ProfileStore update:sourceKey values:@{@"status":message}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"playlist",@"failure_stage":@"snapshot_size_limit",@"snapshot_bytes":@(snapshot.length)}];[self refreshConfigurationPage];[self log:@"%@",message];return;}
            NSArray *disabledBefore=[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[];BOOL migratedDisabled=NO;NSMutableArray *profileOrder=[[NSUserDefaults.standardUserDefaults arrayForKey:@"profileOrder"]?:@[] mutableCopy];NSUInteger replacementOrderIndex=NSNotFound;
            for(NSString *retiredSource in retiredManagedSources){if([disabledBefore containsObject:retiredSource])migratedDisabled=YES;NSUInteger position=[profileOrder indexOfObject:retiredSource];if(position!=NSNotFound&&position<replacementOrderIndex)replacementOrderIndex=position;[profileOrder removeObject:retiredSource];}
            if(replacementOrderIndex!=NSNotFound){[profileOrder removeObject:sourceKey];[profileOrder insertObject:sourceKey atIndex:MIN(replacementOrderIndex,profileOrder.count)];[NSUserDefaults.standardUserDefaults setObject:profileOrder forKey:@"profileOrder"];}
            for(NSString *retiredSource in retiredManagedSources){
                self.subscriptionRequestVersions[retiredSource]=@([self.subscriptionRequestVersions[retiredSource] unsignedIntegerValue]+1);
                [self.subscriptionTasks[retiredSource] cancel];[self.subscriptionTasks removeObjectForKey:retiredSource];
                [self.subscriptionReadiness[retiredSource] cancel];[self.subscriptionReadiness removeObjectForKey:retiredSource];[self.deferredLocalSubscriptions removeObject:retiredSource];
                NSString *oldOrigin=[self originForURL:[NSURL URLWithString:retiredSource]];if(oldOrigin.length)[self.readyLocalOrigins removeObjectForKey:oldOrigin];
                [self.subscriptionTraceIDs removeObjectForKey:retiredSource];[self.subscriptionURLs removeObject:retiredSource];[ProfileStore remove:retiredSource];
            }
            if(migratedDisabled){NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];if(![disabled containsObject:sourceKey])[disabled addObject:sourceKey];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}
            if(retiredManagedSources.count){[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];[self logPluginLine:[NSString stringWithFormat:@"新订阅地址已验证，已替换 %lu 个旧服务地址",(unsigned long)retiredManagedSources.count] identifier:managedService[@"id"] name:managedService[@"name"]];}
            self.allChannels = merged;
            [self.altSources removeAllObjects];for(NSDictionary *c in merged){NSString *url=c[@"remoteURL"],*groupKey=CCTVRouteGroupKey(c);if(!url.length||!groupKey.length)continue;if(!self.altSources[groupKey])self.altSources[groupKey]=[NSMutableArray array];if(![self.altSources[groupKey] containsObject:url])[self.altSources[groupKey] addObject:url];}
            [ProfileStore update:sourceKey values:@{@"cachedChannels":owned,@"status":@"已更新",@"updatedAt":@(NSDate.date.timeIntervalSince1970)}];
            [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];
            [self applyFilter];
            if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];
            if (skippedInvalidURLs) [self log:@"订阅跳过 %lu 条无效地址（仅允许有效 HTTP/HTTPS URL）", (unsigned long)skippedInvalidURLs];
            [self log:@"订阅 %@ 新增 %lu 个频道（共 %lu）", CCTVServiceLogAddress(sourceKey), (unsigned long)added, (unsigned long)list.count];
}
- (void)applyPlaylistText:(NSString *)text source:(NSString *)sourceKey {
    NSString *traceID=NSUUID.UUID.UUIDString.lowercaseString;
    NSUInteger byteCount=[[text dataUsingEncoding:NSUTF8StringEncoding] length];
    [RuntimeDiagnostics.shared recordEvent:@"subscription_text_parse_started" category:@"subscription" fields:@{@"source_type":@"imported_text", @"correlation_id":traceID, @"input_bytes":@(byteCount)}];
    NSArray *list=[M3UParser parse:text baseURL:nil];
    if(!list.count){
        [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_failed" category:@"subscription" fields:@{@"source_type":@"imported_text", @"correlation_id":traceID, @"input_bytes":@(byteCount), @"channel_count":@0, @"failure_stage":text.length?@"no_valid_channels":@"empty_input"}];
        [ProfileStore update:sourceKey values:@{@"status":@"无有效 HTTP/HTTPS 频道，保留上次频道"}];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];
        [self refreshConfigurationPage];
        return;
    }
    [RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_succeeded" category:@"subscription" fields:@{@"source_type":@"imported_text", @"correlation_id":traceID, @"input_bytes":@(byteCount), @"channel_count":@(list.count)}];
    NSString *detected=[M3UParser epgURL:text baseURL:nil];
    if(detected.length)[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];
    [self installPlaylist:list source:sourceKey];
}
- (void)playRemote:(NSDictionary *)ch {
    if(!self.currentPlaybackTraceID.length||self.selectionRequestedAt<=0)self.currentPlaybackTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    self.requestedNativeRoute=nil;self.directNativeRouteActive=NO;
    [self.remoteAttemptedURLs removeAllObjects];self.remoteRetryCount=0;self.remoteFailureRecoveryPending=NO;self.remotePlaybackFailed=NO;
    [self startRemoteChannel:ch];
}
- (void)startRemoteChannel:(NSDictionary *)ch {
    NSString *u=[self stableURLKey:ch[@"remoteURL"]];if(!u.length)return;
    [self.remoteAttemptedURLs addObject:u];
    [self.nativePreloader cancel];
    [self beginPlaybackPriority];
    self.nativePlainRouteActive=[ch[@"nativePlainRoute"] boolValue];
    self.currentRemoteHeaders=MediaPlaybackHeadersFromResult(@{@"headers":([ch[@"headers"] isKindOfClass:NSDictionary.class]?ch[@"headers"]:@{})});
    self.currentRemotePlaybackAttemptID=NSUUID.UUID.UUIDString.lowercaseString;
    NSInteger playbackTab=self.nativePlainRouteActive?0:1;if(self.activeTab!=playbackTab)[self selectBottomTab:(id)self.bottomBar.arrangedSubviews[playbackTab]];
    self.playbackGeneration += 1;self.selectionVersion++;NSUInteger generation=self.playbackGeneration;self.remotePlaybackFailed=NO;self.nativePlaybackFailed=NO;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    NSMutableDictionary *traceFields=[@{@"route_type":self.nativePlainRouteActive?@"user_selected":@"subscription", @"playback_generation":@(generation), @"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"", @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[traceFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(self.currentRemoteHeaders)];[traceFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:u])];[RuntimeDiagnostics.shared recordEvent:@"remote_playback_start_requested" category:@"playback" fields:traceFields];
    NSTimeInterval requestedAt=self.selectionRequestedAt?:CACurrentMediaTime();self.selectionRequestedAt=0;
    [self stopPlayback];self.remoteFailureRecoveryPending=NO;self.playerExpanded=YES;[self.view setNeedsLayout];
    self.currentRemoteURL=u;self.channelID=ch[@"id"]?:u;self.channelName=ch[@"name"]?:u;self.routeName=self.nativePlainRouteActive?[NSString stringWithFormat:@"%@ · AVPlayer 明文线路",self.requestedNativeRoute[@"provider"]?:@"自选"]:@"订阅";
    if(self.playerTabs.selectedSegmentIndex!=3)self.playerTabs.selectedSegmentIndex=1;[self updatePlayerChannelLogoForChannel:ch];[self selectPlayerPanel];
    self.firstRender=NO;self.retryCount=0;self.playStartedAt=requestedAt;self.firstFrameSeconds=0;
    self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    [self recordStartupStage:@"teardown"];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",self.channelName];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"";[self.spinner startAnimating];
    [self.table reloadData];[self.channelGrid reloadData];[self log:@"订阅起播 %@ [%lu]",CCTVServiceLogAddress(u),(unsigned long)generation];
    NSDictionary *service=[self localServiceForChannel:ch URL:[NSURL URLWithString:u]];
    if(!service){[self startRemoteURL:u generation:generation];return;}
    if(![PyHost isRunningServiceIdentifier:service[@"id"]]){
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · 正在启动本机服务",self.channelName];
        self.infoLabel.text=@"频道请求会启动其所属服务，并在接口就绪后继续播放。";
        NSMutableDictionary *fields=[@{@"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"service_id":service[@"id"]?:@"", @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"unknown", @"port":service[@"port"]?:@0, @"trigger":@"channel_playback"} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:u])];[RuntimeDiagnostics.shared recordEvent:@"local_service_start_for_playback_requested" category:@"service" fields:fields];
        [self logPluginLine:@"收到频道播放请求，正在启动本机服务" identifier:service[@"id"] name:service[@"name"]];
        __weak typeof(self) weakSelf=self;
        [self changeService:service enabled:YES completion:^(NSError *startError){
            RootViewController *owner=weakSelf;if(!owner||generation!=owner.playbackGeneration)return;
            NSMutableDictionary *result=[fields mutableCopy];result[@"result"]=startError?@"failed":@"accepted";if(startError){result[@"error_domain"]=startError.domain?:@"";result[@"error_code"]=@(startError.code);result[@"error_message"]=startError.localizedDescription?:@"";}[RuntimeDiagnostics.shared recordEvent:@"local_service_start_for_playback_result" category:@"service" fields:result];
            if(startError){[owner failRemoteReadiness:startError generation:generation];return;}
            // startService accepts the worker-thread request before CPython has
            // necessarily finished initializing. Let the cancellable HTTP
            // readiness probe wait for that transition instead of treating the
            // brief "starting" state as a failed service.
            [owner continueRemotePlaybackForURL:u service:service generation:generation];
        }];
        return;
    }
    [self continueRemotePlaybackForURL:u service:service generation:generation];
}
- (void)continueRemotePlaybackForURL:(NSString *)u service:(NSDictionary *)service generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;
    BOOL serviceRunning=[PyHost isRunningServiceIdentifier:service[@"id"]];
    BOOL serviceStarting=[PyHost isStartingServiceIdentifier:service[@"id"]];
    if(!serviceRunning&&!serviceStarting){
        NSString *engine=[service[@"engine"] isKindOfClass:NSString.class]?service[@"engine"]:@"python";
        NSError *startupError=[engine isEqualToString:@"python"]?[PyHost startupErrorForServiceIdentifier:service[@"id"]]:nil;
        if(!startupError)startupError=[NSError errorWithDomain:@"CCTVHostService" code:3 userInfo:@{@"NSLocalizedDescriptionKey":@"服务既未运行也未处于启动状态，请检查服务日志后重试。"}];
        [self failRemoteReadiness:startupError generation:generation];return;
    }
    NSNumber *readyAt=self.readyLocalOrigins[[self originForURL:[NSURL URLWithString:u]]];
    if(readyAt && CACurrentMediaTime()-readyAt.doubleValue<5){
        [RuntimeDiagnostics.shared recordEvent:@"playback_readiness_cached" category:@"service" fields:@{@"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"port":service[@"port"]?:@0, @"engine":service[@"engine"]?:@"unknown"}];
        [self recordStartupStage:@"serviceCached"];[self recordStartupStage:@"service"];
        [self startRemoteURL:u generation:generation];return;
    }
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待本机服务",self.channelName];
    self.infoLabel.text=@"正在检查此频道的本机接口，成功后开始请求视频。";
    LocalServiceReadiness *probe=[self readinessForURL:[NSURL URLWithString:u] service:service];self.playbackReadiness=probe;__weak typeof(self) w=self;
    [probe start:^(NSError *error,NSTimeInterval elapsed){
        if(generation!=w.playbackGeneration||w.playbackReadiness!=probe)return;
        w.playbackReadiness=nil;NSMutableDictionary *probeFields=[@{@"correlation_id":w.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"service_id":service[@"id"]?:@"", @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"unknown", @"port":service[@"port"]?:@0, @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:probe.diagnosticSummary];[probeFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:u])];
        probeFields[@"probe_result"]=error?@"failed":@"ready";if(error){probeFields[@"error_domain"]=error.domain?:@"";probeFields[@"error_code"]=@(error.code);probeFields[@"error_message"]=error.localizedDescription?:@"";}[RuntimeDiagnostics.shared recordEvent:@"playback_readiness_probe_result" category:@"service" fields:probeFields];
        if(error){[w logPluginLine:[NSString stringWithFormat:@"播放接口健康检查失败 · %@",[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"]] identifier:service[@"id"] name:service[@"name"]];[w failRemoteReadiness:error generation:generation];return;}
        w.readyLocalOrigins[[w originForURL:[NSURL URLWithString:u]]]=@(CACurrentMediaTime());[w recordStartupStage:@"service"];
        [w logPluginLine:[NSString stringWithFormat:@"播放接口健康检查通过 · %.2f 秒",elapsed] identifier:service[@"id"] name:service[@"name"]];[w log:@"本机服务 HTTP 就绪 %.2fs",elapsed];[w startRemoteURL:u generation:generation];
    }];
}
- (void)failRemoteReadiness:(NSError *)error generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;NSDictionary *service=[self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]];NSMutableDictionary *fields=[@{@"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(generation), @"failure_stage":error.code==1?@"health_probe_timeout":@"service_start_or_state", @"service_id":service[@"id"]?:@"", @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"unknown", @"port":service[@"port"]?:@0, @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:self.currentRemoteURL?:@""])];[RuntimeDiagnostics.shared recordEvent:@"playback_readiness_failed" category:@"service" fields:fields];self.remotePlaybackFailed=YES;[self endPlaybackPriority];[self.spinner stopAnimating];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 服务未就绪",self.channelName];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;[self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;NSString *reason=[HostLogRedactor redactText:error.localizedDescription?:@""];if(service)[self logPluginLine:[NSString stringWithFormat:@"播放接口未就绪 · %@",reason.length?reason:@"无可用错误详情"] identifier:service[@"id"] name:service[@"name"]];[self log:@"本机续播失败 %@",reason];self.infoLabel.text=reason.length?[NSString stringWithFormat:@"%@\n查看该服务日志后重试。",reason]:@"服务未就绪。查看该服务日志后重试。";
}
- (void)startRemoteURL:(NSString *)url generation:(NSUInteger)generation {
    if(generation!=self.playbackGeneration)return;
    NSDictionary *headers=self.nativePlainRouteActive?@{@"User-Agent":@"qqlive",@"Referer":@"https://live.cctv.cn/"}:(self.currentRemoteHeaders?:@{});
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL URLWithString:url] options:headers.count?@{@"AVURLAssetHTTPHeaderFieldsKey":headers}:nil];
    AVPlayerItem *item=[AVPlayerItem playerItemWithAsset:asset];item.preferredForwardBufferDuration=0;
    self.avPlayer=[AVPlayer playerWithPlayerItem:item];self.avPlayer.automaticallyWaitsToMinimizeStalling=YES;self.remotePlaybackWanted=YES;
    self.avLayer=[AVPlayerLayer playerLayerWithPlayer:self.avPlayer];self.avLayer.frame=self.playerBox.bounds;self.avLayer.videoGravity=AVLayerVideoGravityResizeAspect;[self.playerBox.layer insertSublayer:self.avLayer atIndex:0];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:kAVItemStatusContext];
    self.avKeepUpObserved=YES;
    [item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:NSKeyValueObservingOptionNew context:kAVItemStatusContext];
    self.avLayerObserved=YES;
    [self.avLayer addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:kAVLayerFrameContext];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(avItemStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
    [self recordStartupStage:@"prepareCall"];[self.avPlayer play];__weak typeof(self) w=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        // A terminal AVPlayerItem failure has its own recovery path. Do not let
        // the first-frame watchdog overwrite that result with a second, false
        // timeout after retry/alternate-source recovery has already stopped.
        if(generation!=w.playbackGeneration||item!=w.avPlayer.currentItem||
           item.status==AVPlayerItemStatusFailed||!w.remotePlaybackWanted||w.firstRender)return;
        NSMutableDictionary *timeoutFields=[@{@"player":@"AVPlayer", @"timeout_seconds":@12, @"playback_generation":@(generation), @"playback_attempt_id":w.currentRemotePlaybackAttemptID?:@"", @"correlation_id":w.currentPlaybackTraceID?:@""} mutableCopy];[timeoutFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(w.currentRemoteHeaders)];[timeoutFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:w.currentRemoteURL])];CCTVAddAVPlayerFailureFields(timeoutFields,item,w.avPlayer,item.error);[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame_timeout" category:@"playback" fields:timeoutFields];
        [w.spinner stopAnimating];w.remotePlaybackFailed=YES;w.titleLabel.hidden=NO;w.titleLabel.text=[NSString stringWithFormat:@"%@ · 等待视频首帧",w.channelName];w.infoLabel.hidden=NO;w.infoLabel.text=@"仍可等待，或点按“重试”重新连接";[w.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];w.playPauseBtn.enabled=YES;NSDictionary *service=[w localServiceForURL:[NSURL URLWithString:w.currentRemoteURL?:@""]];if(service)[w logPluginLine:@"接口已请求，但 12 秒内未收到视频首帧" identifier:service[@"id"] name:service[@"name"]];[w log:@"订阅 12 秒未渲染首帧（并非播放器就绪时间）"];
    });
}

- (void)avItemStalled:(NSNotification *)n {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self avItemStalled:n];});return;}
    if(n.object!=self.avPlayer.currentItem)return;
    [self log:@"订阅缓冲不足 · 进度 %.2fs · %@",CMTimeGetSeconds(self.avPlayer.currentTime),self.remotePlaybackWanted?@"等待分片后续播":@"用户已暂停"];
    // Keep the current item/session. Recreating it here repeats the first frame.
    if(self.remotePlaybackWanted)[self.avPlayer play];
}

- (void)recoverRemoteFailureForItem:(AVPlayerItem *)item error:(NSError *)error {
    if(!item || item!=self.avPlayer.currentItem || !self.remotePlaybackWanted || self.remoteFailureRecoveryPending)return;
    BOOL retrySameURL=self.remoteRetryCount<1&&CCTVRemotePlaybackErrorCanRetrySameURL(error);
    NSMutableDictionary *failureFields=[@{@"player":@"AVPlayer", @"stage":@"item_failure", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"retry_count":@(self.remoteRetryCount), @"recovery_action":retrySameURL?@"retry_same_url":@"try_alternate_or_stop", @"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"", @"correlation_id":self.currentPlaybackTraceID?:@"", @"playback_generation":@(self.playbackGeneration)} mutableCopy];[failureFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(self.currentRemoteHeaders)];[failureFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:self.currentRemoteURL])];CCTVAddAVPlayerFailureFields(failureFields,item,self.avPlayer,error);
    failureFields[@"route_type"]=self.nativePlainRouteActive?@"user_selected":@"subscription";
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:failureFields];
    self.remoteFailureRecoveryPending=YES;
    [self.readyLocalOrigins removeObjectForKey:[self originForURL:[NSURL URLWithString:self.currentRemoteURL]]];
    [self endPlaybackPriority];[self.spinner stopAnimating];
    NSString *safeReason=[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"];NSDictionary *failedService=[self localServiceForURL:[NSURL URLWithString:self.currentRemoteURL?:@""]];if(failedService)[self logPluginLine:[NSString stringWithFormat:@"播放器请求失败 · %@",safeReason] identifier:failedService[@"id"] name:failedService[@"name"]];[self log:@"订阅播放失败 %@",safeReason];
    if(retrySameURL){
        self.remoteRetryCount++;NSUInteger generation=self.playbackGeneration;NSString *url=self.currentRemoteURL?:@"";
        NSDictionary *retry=@{@"id":self.channelID?:url,@"name":self.channelName?:url,@"remoteURL":url,@"nativePlainRoute":@(self.nativePlainRouteActive),@"headers":self.currentRemoteHeaders?:@{}};
        [self log:@"同源自动恢复 1/1，保留一次短重试"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if(generation!=self.playbackGeneration || item!=self.avPlayer.currentItem || !self.remotePlaybackWanted || ![url isEqualToString:self.currentRemoteURL])return;
            self.remoteFailureRecoveryPending=NO;[self startRemoteChannel:retry];
        });
        return;
    }
    [self tryAlternateSource];
}

- (void)avItemFailed:(NSNotification *)n {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self avItemFailed:n];});return;}
    if (n.object != self.avPlayer.currentItem) return;
    NSError *e = n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
    [self recoverRemoteFailureForItem:n.object error:e];
}

- (void)tryAlternateSource {
    if(!self.remotePlaybackWanted)return;
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    for (NSDictionary *channel in self.allChannels) {
        if(self.nativePlainRouteActive || self.remoteAttemptedURLs.count>=4)break;
        if(![channel[@"name"] isEqualToString:self.channelName])continue;
        NSString *url=[self stableURLKey:channel[@"remoteURL"]];
        if(!url.length || [self.remoteAttemptedURLs containsObject:url])continue;
        NSMutableSet *owners=[NSMutableSet setWithArray:channel[@"subscriptionSources"]?:@[]];[owners minusSet:disabled];
        if(!owners.count)continue;
        self.remoteRetryCount=0;self.remoteFailureRecoveryPending=NO;
        [self log:@"换源重试 %lu/4",(unsigned long)self.remoteAttemptedURLs.count+1];
        [self startRemoteChannel:channel];
        return;
    }
    self.remotePlaybackWanted=NO;self.remotePlaybackFailed=YES;[self.avPlayer pause];[self.spinner stopAnimating];[self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;
    self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 播放失败",self.channelName?:@"频道"];
    self.infoLabel.text=self.nativePlainRouteActive?@"所选线路播放失败 · 点按“重试”或在线路面板换线":@"自动换源已结束 · 点按“重试”再试一次";
}

- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)change context:(void *)context {
    if(![NSThread isMainThread]){dispatch_async(dispatch_get_main_queue(), ^{[self observeValueForKeyPath:kp ofObject:obj change:change context:context];});return;}
    if(context==kAVLayerFrameContext){
        if(obj!=self.avLayer||!self.avLayer.readyForDisplay||self.firstRender)return;
        NSURL *playingURL=[NSURL URLWithString:self.currentRemoteURL];NSDictionary *service=[self localServiceForURL:playingURL];
        if(service && [PyHost isRunningServiceIdentifier:service[@"id"]])self.readyLocalOrigins[[self originForURL:playingURL]]=@(CACurrentMediaTime());
        self.firstRender=YES;self.remotePlaybackFailed=NO;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;[self endPlaybackPriority];self.firstFrameSeconds=CACurrentMediaTime()-self.playStartedAt;[self recordStartupStage:@"frame"];
        NSMutableDictionary *frameFields=[@{@"player":@"AVPlayer", @"elapsed_ms":@((NSInteger)(self.firstFrameSeconds*1000)), @"playback_generation":@(self.playbackGeneration), @"playback_attempt_id":self.currentRemotePlaybackAttemptID?:@"", @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[frameFields addEntriesFromDictionary:MediaPlaybackDiagnosticHeaderFields(self.currentRemoteHeaders)];[frameFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:self.currentRemoteURL])];CCTVAddAVPlayerFailureFields(frameFields,self.avPlayer.currentItem,self.avPlayer,nil);[RuntimeDiagnostics.shared recordEvent:@"playback_first_frame" category:@"playback" fields:frameFields];if(service)[self logPluginLine:[NSString stringWithFormat:@"视频首帧已渲染 · %.2f 秒 · %@",self.firstFrameSeconds,self.startupTrace.summary] identifier:service[@"id"] name:service[@"name"]];
        [self.spinner stopAnimating];self.titleLabel.hidden=YES;self.infoLabel.hidden=YES;[self loadPlayerChannelLogoAfterFirstFrame];[self updateNowPlaying];[self refreshNowNext];[self restartEPGTimer];
        [self log:@"订阅视频首帧 %.2fs · %@",self.firstFrameSeconds,self.startupTrace.summary];return;
    }
    if(context==kAVItemStatusContext){
        AVPlayerItem *item=obj;if(item!=self.avPlayer.currentItem)return;
        if([kp isEqualToString:@"playbackLikelyToKeepUp"]){
            if(item.playbackLikelyToKeepUp && self.remotePlaybackWanted && self.avPlayer.rate==0){[self.avPlayer play];[self log:@"订阅分片恢复，继续原播放会话"];}return;
        }
        if(item.status==AVPlayerItemStatusReadyToPlay){[self recordStartupStage:@"itemReady"];[self log:@"订阅播放器就绪，继续等待视频渲染"];}else if(item.status==AVPlayerItemStatusFailed){self.titleLabel.text=[NSString stringWithFormat:@"%@ · 失败，尝试恢复",self.channelName];[self recoverRemoteFailureForItem:item error:item.error];}
        return;
    }
    [super observeValueForKeyPath:kp ofObject:obj change:change context:context];
}

- (void)showNativeRouteError:(NSError *)error channel:(NSDictionary *)channel {
    NSString *message=error.localizedDescription?:@"SDK 未接受所选线路。";
    [self log:@"线路配置失败：%@",message];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"自选线路无法起播" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) owner=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"使用 SDK 自动线路" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner playChannel:channel route:nil];}]];
    [(self.navigationController.topViewController?:self) presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 节目单

- (void)openEPG {
    if (!self.channelID.length) { [self log:@"请先选择频道"]; return; }
    [self openEPGforChannel:self.channelID name:self.channelName];
}

- (NSString *)epgIDForChannel:(NSDictionary *)ch {
    if(!ch)return nil;if(![ch[@"remoteURL"] length])return ch[@"id"];
    NSString *key=[[ProfileStore epgIDForChannel:ch] lowercaseString];NSDictionary *matched=key.length?[self channelWithID:key]:nil;if(matched&&![matched[@"remoteURL"] length])return key;
    for(NSDictionary *native in self.allChannels){if([native[@"remoteURL"] length])continue;if([native[@"name"] isEqualToString:ch[@"tvgName"]]||[native[@"name"] isEqualToString:ch[@"name"]])return native[@"id"];}
    return nil;
}
- (void)openEPGforChannel:(NSString *)cid name:(NSString *)name {
    [self.navigationController pushViewController:[self epgPageForChannel:cid name:name] animated:YES];
}

- (void)restartEPGTimer {
    self.epgRefreshDesired=CCTVBoolPreference(@"autoLoadEPG",YES);
    if (!self.epgRefreshDesired || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || CACurrentMediaTime()<self.playbackPriorityUntil) { [self.epgTimer invalidate]; self.epgTimer=nil; return; }
    [self.epgTimer invalidate];
    self.epgTimer = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(refreshNowNext) userInfo:nil repeats:YES];
}

- (void)refreshNowNext {
    if(!CCTVBoolPreference(@"autoLoadEPG",YES)||!self.firstRender)return;
    NSDictionary *channel=[self channelWithID:self.channelID];NSString *source=[ProfileStore epgSourceForChannel:channel];
    if(!source.length){[self refreshOfficialNowNext];return;}
    NSString *cid=self.channelID;NSUInteger epgGeneration=self.playbackGeneration;__weak typeof(self) w=self;
    [[XMLTVStore shared] loadSource:source channel:[ProfileStore epgIDForChannel:channel] force:NO completion:^(NSArray *rows,NSError *error){
        if(epgGeneration!=w.playbackGeneration||![w.channelID isEqualToString:cid])return;
        if(rows.count){[w cacheXMLRows:rows channel:cid];[w saveEPGCache];[w.channelGrid reloadData];[w.table reloadData];}
        else if(error.code!=NSURLErrorCancelled)[w refreshOfficialNowNext];
    }];
}
- (void)refreshOfficialNowNext {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||CACurrentMediaTime()<self.playbackPriorityUntil) return;
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
    NSString *officialID=[self epgIDForChannel:[self channelWithID:cid]];if(!officialID.length)return;
    NSUInteger epgGeneration = self.playbackGeneration;
    NSUInteger requestGeneration=++self.officialEPGRequestGeneration;
    NSString *url = [NSString stringWithFormat:@"https://api.cntv.cn/epg/get3D12HEPG?c=%@&serviceId=cbox",
                     [officialID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
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
            if (![weakSelf.epgChannel isEqualToString:cid] || requestGeneration!=weakSelf.officialEPGRequestGeneration || epgGeneration != weakSelf.playbackGeneration ||
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
    if(!self.directNativeRouteActive && !self.nativeTimeShiftActive && [self.startupTrace shouldRecoverMissingSetupAtTime:CACurrentMediaTime() alreadyRetried:self.nativeStartupRecoveryUsed failed:self.nativePlaybackFailed]){
        self.nativeStartupRecoveryUsed=YES;
        [self log:@"VDN 成功后持续未创建播放内核，使用全新实例恢复一次 · %@",self.startupTrace.summary];
        self.playbackGeneration++;
        [self stopPlayback];[self.nativePreloader cancel];self.sdkPlayer=nil;
        self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
        [self recordStartupStage:@"recovery"];self.stallReported=NO;
        [self playSelectedNativeRouteOrChannel];return;
    }
    if(elapsed>=10&&!self.stallReported){
        self.stallReported=YES;BOOL vdnDone=self.startupTrace.stages[@"vdn"]!=nil;NSString *waitState=self.directNativeRouteActive?@"自选地址等待视频数据":(vdnDone?@"等待视频数据":@"调度等待中");
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@",self.channelName,waitState];
        [self log:@"原生起播等待 %.2fs · %@ · %@",elapsed,self.directNativeRouteActive?@"SDK URL 路径":(vdnDone?@"VDN 已完成":@"VDN 尚未完成"),self.startupTrace.summary];
    }
    if(elapsed>=25){[timer invalidate];[self log:@"25 秒未首帧 · %@",self.startupTrace.summary];[self displayNativePlaybackFailure:@"起播超时" error:nil];}

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
    if(event==2) {
        [self recordStartupStage:@"setup"];
        NSUInteger generation=self.playbackGeneration;NativeStartupTuner *tuner=self.nativeStartupTuner;
        // Setup is emitted immediately after core creation, BEFORE the SDK installs
        // its DRM config. Run next turn to preserve that completed config.
        dispatch_async(dispatch_get_main_queue(), ^{
            if(generation!=self.playbackGeneration || player!=self.currentPlayer || self.firstRender || !tuner || tuner!=self.nativeStartupTuner)return;
            BOOL applied=[tuner applyToPlayer:player];
            [self log:@"%@",tuner.summary];if(applied)[self recordStartupStage:@"bufferTuned"];
        });
    }
    if (event == 3 && !self.firstRender) {
        self.firstFrameSeconds = CACurrentMediaTime() - self.playStartedAt;
        self.firstRender = YES;self.nativePlaybackFailed=NO;
        if([self.nativeStartupTuner restore])[self log:@"首帧后已恢复 SDK 稳态缓冲"];
        [self endPlaybackPriority];
        [self.spinner stopAnimating];
        self.titleLabel.text = self.channelName;
        self.titleLabel.hidden = YES;
        self.infoLabel.hidden = YES;
        [self loadPlayerChannelLogoAfterFirstFrame];
        [self recordStartupStage:@"frame"];
        [RuntimeDiagnostics.shared recordEvent:@"playback_first_frame" category:@"playback" fields:@{@"player":@"CNPlayerSDK", @"elapsed_ms":@((NSInteger)(self.firstFrameSeconds*1000)), @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"route_type":self.requestedNativeRoute?@"user_selected":@"sdk_auto"}];
        if(self.nativeTransitionKind.length){[self log:@"原生%@首帧 %.2fs · %@",self.nativeTransitionKind,self.firstFrameSeconds,self.startupTrace.summary];self.nativeTransitionKind=nil;}
        else [self log:@"首帧渲染 %.2fs · %@", self.firstFrameSeconds,self.startupTrace.summary];
        [self log:@"SDK 报告节点 %@ · 请求线路 %@",[NativeCDNPreference observedCDNDescriptionForPlayer:self.currentPlayer],self.routeName?:@"自动"];
        [self updateNowPlaying];
        [self refreshNowNext];
        [self restartEPGTimer];
        NSUInteger generation=self.playbackGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self prepareNextNativeChannelForGeneration:generation];});
    }
}

- (void)prepareNextNativeChannelForGeneration:(NSUInteger)generation {
    if(generation!=self.playbackGeneration || !self.firstRender || self.nativeTimeShiftActive || !self.currentPlayer || self.avPlayer || self.directNativeRouteActive || !CCTVBoolPreference(@"preloadNativeChannel",YES) || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    NSMutableArray *native=[NSMutableArray array];
    for(NSDictionary *channel in self.allChannels)if(![channel[@"remoteURL"] length] && ![ProfileStore isHTTP:channel[@"id"]])[native addObject:channel];
    NSUInteger index=[native indexOfObjectPassingTest:^BOOL(NSDictionary *channel,NSUInteger i,BOOL *stop){return [channel[@"id"] isEqualToString:self.channelID];}];
    if(index==NSNotFound || native.count<2)return;
    NSDictionary *next=native[(index+1)%native.count];[self.nativePreloader prepareChannel:next[@"id"] title:next[@"name"]];
}

- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player playBackStateDidChanged:state]; }); return; }
    if (player != self.currentPlayer || self.nativePlaybackFailed) return;
    if (state == 1) [self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    if (state == 2) [self.playPauseBtn setTitle:@"继续" forState:UIControlStateNormal];
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player playbackFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    if(self.nativeRetryPending){[self log:@"忽略自动重连期间重复的播放器错误回调"];return;}
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"播放失败 %ld %@", (long)error.code, error.localizedDescription];
    if(self.nativeTransitionKind.length || self.nativeTimeShiftActive){self.nativeTransitionKind=nil;[self.nativeTimeshift cancel];[self log:@"时移操作失败，请返回直播或重新选台"];[self displayNativePlaybackFailure:@"时移 / 回看失败" error:error];return;}
    if (error.code >= 4000 && error.code < 5000) {
        [self log:@"参数/调度错误不自动重试，请查看错误详情"];
        [self displayNativePlaybackFailure:@"播放被拒绝" error:error];
        return;
    }
    if (self.retryCount < 2) {
        self.retryCount += 1;
        self.nativeRetryPending=YES;
        double delay = self.retryCount == 1 ? 1.0 : 3.0;
        [self log:@"断流重连 第 %ld 次（%.0fs 后）", (long)self.retryCount, delay];
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · 正在重连",self.channelName?:@"频道"];self.titleLabel.hidden=NO;self.infoLabel.text=[NSString stringWithFormat:@"第 %ld / 2 次自动恢复",(long)self.retryCount];self.infoLabel.hidden=NO;[self.spinner startAnimating];[self.playPauseBtn setTitle:@"重连中" forState:UIControlStateNormal];self.playPauseBtn.enabled=NO;
        NSUInteger generation = self.playbackGeneration;
        NSString *cid = self.channelID;
        NSString *name = self.channelName;
        BOOL remotePlayback = self.avPlayer != nil;
        NSString *remoteURL = remotePlayback ? self.currentRemoteURL : nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self.playbackGeneration || player != self.currentPlayer || ![cid isEqualToString:self.channelID]) return;
            if (remotePlayback) {
                self.nativeRetryPending=NO;
                if (remoteURL.length) [self playRemote:@{@"id": cid, @"name": name ?: cid, @"remoteURL": remoteURL}];
            } else {
                self.playbackGeneration+=1;self.stallReported=NO;
                self.playStartedAt=CACurrentMediaTime();self.firstRender=NO;self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
                [self playSelectedNativeRouteOrChannel];
            }
        });
    }else{
        [self displayNativePlaybackFailure:@"播放失败" error:error];
    }
}

- (void)displayNativePlaybackFailure:(NSString *)stage error:(NSError *)error {
    NSString *player=self.avPlayer?@"AVPlayer":(self.cicadaPlayer?@"CicadaPlayer":@"CNPlayerSDK");
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:@{@"player":player, @"stage":stage?:@"unknown", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"route_type":self.directNativeRouteActive?@"user_selected":@"sdk_auto"}];
    self.nativePlaybackFailed=YES;self.nativeRetryPending=NO;[self.watchdog invalidate];self.watchdog=nil;[self.nativeStartupTuner restore];[self endPlaybackPriority];[self.spinner stopAnimating];
    NSString *channel=self.channelName.length?self.channelName:@"频道";
    self.titleLabel.text=error.code?[NSString stringWithFormat:@"%@ · %@ (%ld)",channel,stage,(long)error.code]:[NSString stringWithFormat:@"%@ · %@",channel,stage];
    self.titleLabel.hidden=NO;self.infoLabel.text=@"点按“重试”或重新选择频道";self.infoLabel.hidden=NO;
    [self.playPauseBtn setTitle:@"重试" forState:UIControlStateNormal];self.playPauseBtn.enabled=YES;
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player vdnRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"VDN 请求失败 %ld", (long)error.code];[self displayNativePlaybackFailure:@"频道调度失败" error:error];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player parameterError:error rate:rate]; }); return; }
    if (player != self.currentPlayer) return;
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"参数错误 %ld", (long)error.code];[self displayNativePlaybackFailure:@"参数错误" error:error];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration; dispatch_async(dispatch_get_main_queue(), ^{ if(generation!=self.playbackGeneration)return; [self player:player publicRequestFailed:error]; }); return; }
    if (player != self.currentPlayer) return;
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];
    [self log:@"版权请求失败 %ld", (long)error.code];[self displayNativePlaybackFailure:@"版权请求失败" error:error];
}

- (void)authFailed:(NSError *)error {
    if (![NSThread isMainThread]) { NSUInteger generation=self.playbackGeneration;dispatch_async(dispatch_get_main_queue(), ^{if(generation!=self.playbackGeneration)return;[self authFailed:error];}); return; }
    self.nativePlaybackFailed=YES;[self.nativeStartupTuner restore];[self endPlaybackPriority];[self log:@"鉴权失败 %ld", (long)error.code];[self displayNativePlaybackFailure:@"鉴权失败" error:error];
}

- (void)showPlaybackInfo {
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:[self playbackInformationPage]];HostStyleNavigation(nav);nav.navigationBar.prefersLargeTitles=NO;nav.modalPresentationStyle=UIModalPresentationPageSheet;nav.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];nav.sheetPresentationController.prefersGrabberVisible=YES;[self presentViewController:nav animated:YES completion:nil];
}

- (EPGViewController *)epgPageForChannel:(NSString *)cid name:(NSString *)name {
    NSDictionary *channel=[self channelWithID:cid]?:@{@"id":cid?:@"",@"name":name?:@"节目单"};
    EPGViewController *page=[[EPGViewController alloc] initWithChannel:channel officialID:[self epgIDForChannel:channel]?:@""];
    if(![channel[@"remoteURL"] length] && ![ProfileStore isHTTP:cid]){
        __weak typeof(self) weakSelf=self;
        page.onReplay=^(NSDictionary *program){
            if(![weakSelf.channelID isEqualToString:cid] || !weakSelf.currentPlayer || weakSelf.avPlayer){[weakSelf showServiceError:@"请先播放这个 CCTV 频道，再选择已播节目。"];return;}
            [weakSelf.navigationController popToViewController:weakSelf animated:YES];
            weakSelf.playerTabs.selectedSegmentIndex=1;[weakSelf selectPlayerPanel];
            [weakSelf seekNativeStart:[program[@"start"] doubleValue] end:[program[@"end"] doubleValue]];
        };
    }
    return page;
}
- (void)showNativeTimeshiftActions {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"时移 / 回看" message:@"由频道服务确认可用时间范围与版权；不支持的时间会返回失败。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSNumber *minutes in @[@1,@5,@30]){
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"回退 %@ 分钟",minutes] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self seekNativeStart:NSDate.date.timeIntervalSince1970-minutes.doubleValue*60 end:0];}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"返回直播" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self returnToNativeLive];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.moreBtn;sheet.popoverPresentationController.sourceRect=self.moreBtn.bounds;[self presentViewController:sheet animated:YES completion:nil];
}
- (void)beginNativeTransition:(NSString *)kind {
    [self.nativePreloader cancel];[self beginPlaybackPriority];self.playbackGeneration++;
    self.firstRender=NO;self.nativePlaybackFailed=NO;self.stallReported=NO;self.nativeTransitionKind=kind;
    self.playStartedAt=CACurrentMediaTime();self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@中",self.channelName,kind];self.titleLabel.hidden=NO;[self.spinner startAnimating];[self startWatchdog];
}
- (void)seekNativeStart:(NSTimeInterval)start end:(NSTimeInterval)end {
    if(!self.currentPlayer || self.avPlayer || !self.firstRender){[self showServiceError:@"请等待 CCTV 原生频道起播完成后再操作。"];return;}
    if(!self.nativeTimeshift)self.nativeTimeshift=[[NativeTimeshiftSession alloc] initWithPlayer:self.currentPlayer];
    [self beginNativeTransition:end==0?@"时移":@"回看"];self.nativeTimeShiftActive=YES;
    NSUInteger generation=self.playbackGeneration;__weak id player=self.currentPlayer;__weak typeof(self) weakSelf=self;
    BOOL accepted=[self.nativeTimeshift seekStart:start end:end now:NSDate.date.timeIntervalSince1970 completion:^(BOOL allowed,NSError *error){
        if(generation!=weakSelf.playbackGeneration || player!=weakSelf.currentPlayer)return;
        if(!allowed || error){[weakSelf failNativeTransition:@"频道未允许该时间的时移/回看，请返回直播或重新选台。"];}else [weakSelf log:@"原生时移请求已完成，等待/确认首帧"];
    }];
    if(!accepted)[self failNativeTransition:@"当前 SDK 不支持此调用，或时间范围无效。"];
}
- (void)failNativeTransition:(NSString *)message {
    [self.nativeTimeshift cancel];self.nativeTransitionKind=nil;self.nativePlaybackFailed=YES;[self.watchdog invalidate];[self.spinner stopAnimating];[self endPlaybackPriority];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 时移操作失败",self.channelName];[self log:@"%@",message];[self showServiceError:message];
}
- (void)returnToNativeLive {
    if(!self.currentPlayer || self.avPlayer)return;
    if(!self.nativeTimeshift)self.nativeTimeshift=[[NativeTimeshiftSession alloc] initWithPlayer:self.currentPlayer];
    [self beginNativeTransition:@"返回直播"];self.nativeTimeShiftActive=NO;
    if(![self.nativeTimeshift backToLive])[self failNativeTransition:@"当前 SDK 无法执行返回直播，请重新选台。"];
}

- (void)showMorePlaybackActions {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:self.channelName ?: @"播放操作" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:self.fullscreen?@"退出全屏":@"全屏" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self toggleFullscreen]; }]];
    if(self.currentPlayer && !self.avPlayer){
        [sheet addAction:[UIAlertAction actionWithTitle:@"时移 / 回看" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self showNativeTimeshiftActions];}]];
        if(self.nativeTimeShiftActive)[sheet addAction:[UIAlertAction actionWithTitle:@"返回直播" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self returnToNativeLive];}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"播放信息" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self showPlaybackInfo]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"画中画" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self togglePiP]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"诊断日志" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self openDiagnosticLog]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) { sheet.popoverPresentationController.sourceView=self.moreBtn; sheet.popoverPresentationController.sourceRect=self.moreBtn.bounds; }
    [self presentViewController:sheet animated:YES completion:nil];
}


- (void)beginPlaybackPriority {
    self.playbackIntentVersion++;NSUInteger intent=self.playbackIntentVersion;
    self.playbackPriorityUntil=CACurrentMediaTime()+12;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(intent==self.playbackIntentVersion && self.playbackPriorityUntil>0){[self log:@"起播优先窗口结束，恢复订阅刷新"];[self endPlaybackPriority];}
    });
    [self stopPreview];[[XMLTVStore shared] setPaused:YES];self.subscriptionParseGeneration++;
    for(NSString *source in self.subscriptionTasks.allKeys){[self.subscriptionTasks[source] cancel];[self.deferredLocalSubscriptions addObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);}
    [self.subscriptionTasks removeAllObjects];
    for(NSString *source in self.subscriptionReadiness.allKeys){[self.subscriptionReadiness[source] cancel];[self.deferredLocalSubscriptions addObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);}[self.subscriptionReadiness removeAllObjects];
    [[HostImageLoader shared] cancelPending];
}
- (void)endPlaybackPriority {
    self.playbackPriorityUntil=0;BOOL background=UIApplication.sharedApplication.applicationState!=UIApplicationStateActive;[[XMLTVStore shared] setPaused:background];if(!background&&self.epgRefreshDesired){[self restartEPGTimer];[self refreshNowNext];}NSUInteger generation=self.playbackGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{if(generation==self.playbackGeneration&&CACurrentMediaTime()>=self.playbackPriorityUntil){[self refreshSubscriptionsWhenIdle];if(self.activeTab<2){[self.channelGrid reloadData];[self.table reloadData];}}});
}
- (void)refreshSubscriptionsWhenIdle {
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
    NSArray *pending=self.deferredLocalSubscriptions.allObjects;[self.deferredLocalSubscriptions removeAllObjects];for(NSString *s in pending)[self fetchSubscription:s silent:YES];
}
- (void)refreshConfigurationPage {if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];}
- (void)importPlaylistData:(NSData *)data name:(NSString *)name {
    NSString *text=data.length<=10*1024*1024?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
    if(![M3UParser parse:text baseURL:nil].count){[self showServiceError:@"文件须为 UTF-8 M3U 播放列表，包含有效 HTTP/HTTPS 频道，且不超过 10MB。"];return;}
    NSString *source=[@"local-playlist:" stringByAppendingString:NSUUID.UUID.UUIDString];[ProfileStore update:source values:@{@"name":name?:@"本地播放列表",@"text":text}];[self.subscriptionURLs addObject:source];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];[self applyPlaylistText:text source:source];
}
- (void)editProfile:(NSString *)source {
    BOOL wasDisabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] containsObject:source];
    NSDictionary *p=[ProfileStore metadata:source];UIAlertController *a=[UIAlertController alertControllerWithTitle:@"编辑配置" message:@"XMLTV 地址留空时使用播放列表提供的 EPG。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"配置名称";t.text=p[@"name"]?:[NSURL URLWithString:source].host;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"订阅链接（本地文件不可修改）";t.text=[ProfileStore isHTTP:source]?source:@"本地文件";t.enabled=[ProfileStore isHTTP:source];t.autocapitalizationType=UITextAutocapitalizationTypeNone;t.keyboardType=UIKeyboardTypeURL;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *t){t.placeholder=@"XMLTV / XMLTV.gz 地址";t.text=p[@"epgURL"]?:p[@"detectedEPGURL"];t.autocapitalizationType=UITextAutocapitalizationTypeNone;t.keyboardType=UIKeyboardTypeURL;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *u=[ProfileStore isHTTP:source]?[self stableURLKey:a.textFields[1].text]:source;NSString *epg=[a.textFields[2].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!u.length||(epg.length&&![ProfileStore isHTTP:epg])){[self showServiceError:@"订阅和 EPG 地址须为有效 HTTP/HTTPS 链接。"];return;}
        NSMutableDictionary *values=[p mutableCopy];values[@"name"]=a.textFields[0].text?:@"";values[@"epgURL"]=epg?:@"";
        if(![source isEqualToString:u]){[self deleteSubscription:source];[values removeObjectForKey:@"cachedChannels"];[self.subscriptionURLs addObject:u];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];}
        if(wasDisabled){NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];if(![disabled containsObject:u])[disabled addObject:u];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}
        self.activeSource=nil;[ProfileStore update:u values:values];[self.epgCache removeAllObjects];[self fetchSubscription:u silent:NO];[self refreshConfigurationPage];
    }]];[self presentViewController:a animated:YES completion:nil];
}
- (void)editEPGMapping:(NSDictionary *)ch {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"EPG 手动匹配" message:@"输入 XMLTV channel ID 或央视官方频道 ID；留空恢复自动匹配。" preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *t){t.text=[ProfileStore epgIDForChannel:ch];t.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *m=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"epgMappings"]?:@{} mutableCopy];NSString *key=ch[@"id"];NSString *value=[a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(value.length)m[key]=value;else[m removeObjectForKey:key];[NSUserDefaults.standardUserDefaults setObject:m forKey:@"epgMappings"];[self.epgCache removeObjectForKey:key];[self saveEPGCache];[self applyFilter];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)showRemoteTools:(NSDictionary *)ch {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:ch[@"name"] message:@"订阅频道 · AVPlayer" preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"重新播放" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self routePlayback:ch];}]];
    for(NSString *url in self.altSources[CCTVRouteGroupKey(ch)]){if([url isEqual:ch[@"remoteURL"]])continue;[a addAction:[UIAlertAction actionWithTitle:[NSURL URLWithString:url].host?:@"备用源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSMutableDictionary *other=[ch mutableCopy];other[@"remoteURL"]=url;[self routePlayback:other];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self openEPGforChannel:ch[@"id"] name:ch[@"name"]];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"EPG 手动匹配" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self editEPGMapping:ch];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"静音预览（30 秒）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self previewChannel:ch];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)previewChannel:(NSDictionary *)ch {
    if(self.currentPlayer||self.avPlayer||self.playbackReadiness){[self showServiceError:@"为保证正式播放，预览仅在没有频道播放时启动。"];return;}
    NSString *url=[self stableURLKey:ch[@"remoteURL"]];if(!url.length)return;
    NSDictionary *localService=[self localServiceForChannel:ch URL:[NSURL URLWithString:url]];if(localService&&![PyHost isRunningServiceIdentifier:localService[@"id"]]){[self showServiceError:@"请先启动该频道的本机服务。"];return;}
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
