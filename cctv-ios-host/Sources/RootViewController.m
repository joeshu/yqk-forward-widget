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
#import "CCTVTimeshiftController.h"
#import "PlaybackInfoViewController.h"
#import "LogCenterViewController.h"
#import "PluginRunHistoryViewController.h"
#import "RuntimeDiagnostics.h"
#import "PluginLogStore.h"
#import "CNPlayerCrashGuard.h"
#import "ResourceImportWorkflowViewController.h"
#import "SubscriptionResourceViewController.h"
#import "CNPlayerSessionDelegate.h"
#import "ResourceImportSheetViewController.h"
#import "PluginResourceDetailViewController.h"
#import "MediaPlaybackViewController.h"
#import "MediaPlaybackHeaders.h"
#import "TVBoxCatalogStore.h"
#import "TVBoxCatalogPackageExporter.h"
#import "TVBoxCatalogBulkImporter.h"
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
#import <Security/Security.h>
#import <ifaddrs.h>
#import <arpa/inet.h>

static NSString *CCTVDeviceLANIPv4Address(void) {
    struct ifaddrs *interfaces = NULL;
    NSString *fallback = nil;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *cursor = interfaces; cursor != NULL; cursor = cursor->ifa_next) {
            if (!cursor->ifa_addr || cursor->ifa_addr->sa_family != AF_INET) continue;
            NSString *ifName = cursor->ifa_name ? [NSString stringWithUTF8String:cursor->ifa_name] : @"";
            if ([ifName isEqualToString:@"lo0"]) continue;
            char addrBuf[INET_ADDRSTRLEN] = {0};
            const struct sockaddr_in *sin = (const struct sockaddr_in *)cursor->ifa_addr;
            if (!inet_ntop(AF_INET, &sin->sin_addr, addrBuf, sizeof(addrBuf))) continue;
            NSString *ip = [NSString stringWithUTF8String:addrBuf];
            if (!ip.length || [ip hasPrefix:@"127."] || [ip hasPrefix:@"169.254."]) continue;
            if ([ifName isEqualToString:@"en0"] || [ifName isEqualToString:@"en1"]) {
                freeifaddrs(interfaces);
                return ip;
            }
            if (!fallback) fallback = ip;
        }
        freeifaddrs(interfaces);
    }
    return fallback ?: @"127.0.0.1";
}

static NSString *const CCTVTVBoxTokenPlaceholder = @"__LYTVS_SUBSCRIPTION_TOKEN__";
static NSDictionary *CCTVTVBoxTokenKeychainQuery(void) {
    return @{
        (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.yqk.cctvhost.resource-subscription",
        (__bridge id)kSecAttrAccount:@"lytvs-ios"
    };
}
static NSURL *CCTVURLFromPossiblyUnescapedString(NSString *raw) {
    if(![raw isKindOfClass:NSString.class]||!raw.length)return nil;
    NSURL *u=[NSURL URLWithString:raw];
    if(u)return u;
    NSMutableCharacterSet *allowed=[NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed addCharactersInString:@"#%/:?@[]!$&'()*+,;="];
    NSString *encoded=[raw stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return encoded.length?[NSURL URLWithString:encoded]:nil;
}
static BOOL CCTVTVBoxSaveSubscriptionToken(NSString *token) {
    NSData *data=[token dataUsingEncoding:NSUTF8StringEncoding];if(!data.length||data.length>512)return NO;
    NSMutableDictionary *attributes=[@{(__bridge id)kSecValueData:data,(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly} mutableCopy];
    NSDictionary *query=CCTVTVBoxTokenKeychainQuery();OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)attributes);
    if(status==errSecItemNotFound){NSMutableDictionary *item=[query mutableCopy];[item addEntriesFromDictionary:attributes];status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);}
    return status==errSecSuccess;
}
static NSString *CCTVTVBoxTokenFromInput(NSString *input) {
    NSString *value=[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";NSURL *u=CCTVURLFromPossiblyUnescapedString(value);NSURLComponents *parts=u?[NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO]:[NSURLComponents componentsWithString:value];
    if([parts.host.lowercaseString isEqual:@"sub.lytvs.top"]){for(NSURLQueryItem *item in parts.queryItems)if([@[@"token",@"tk"] containsObject:item.name.lowercaseString]&&item.value.length&&![item.value isEqualToString:CCTVTVBoxTokenPlaceholder])return item.value;return nil;}
    if(value.length>512||[value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound)return nil;return value;
}
static NSString *CCTVTVBoxStoredSubscriptionToken(void) {
    NSMutableDictionary *query=[CCTVTVBoxTokenKeychainQuery() mutableCopy];query[(__bridge id)kSecReturnData]=@YES;query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)query,&result)==errSecSuccess&&result){
        NSData *data=(__bridge_transfer NSData *)result;NSString *stored=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if(stored.length)return stored;
    }
    for(NSDictionary *cat in [TVBoxCatalogStore catalogs]){
        for(NSString *urlKey in @[@"url",@"origin",@"sourceURL"]){
            NSString *u=[cat[urlKey] isKindOfClass:NSString.class]?cat[urlKey]:@"";
            if([u.lowercaseString containsString:@"sub.lytvs.top"]){
                NSString *extracted=CCTVTVBoxTokenFromInput(u);
                if(extracted.length){CCTVTVBoxSaveSubscriptionToken(extracted);return extracted;}
            }
        }
    }
    return nil;
}
static NSString *CCTVTVBoxURLByResolvingToken(NSString *url,NSString *token) {
    if(![url containsString:CCTVTVBoxTokenPlaceholder]){
        NSURL *u=CCTVURLFromPossiblyUnescapedString(url);
        return u?u.absoluteString:url;
    }
    NSURL *baseU=CCTVURLFromPossiblyUnescapedString(url);
    NSURLComponents *parts=baseU?[NSURLComponents componentsWithURL:baseU resolvingAgainstBaseURL:NO]:[NSURLComponents componentsWithString:url];
    if(!parts)return nil;BOOL replaced=NO;NSMutableArray *items=[NSMutableArray array];
    for(NSURLQueryItem *item in parts.queryItems){NSString *value=item.value?:@"";if([value containsString:CCTVTVBoxTokenPlaceholder]){value=[value stringByReplacingOccurrencesOfString:CCTVTVBoxTokenPlaceholder withString:token?:@""];replaced=YES;}[items addObject:[NSURLQueryItem queryItemWithName:item.name value:value]];}
    if(!replaced)return nil;parts.queryItems=items;return parts.URL.absoluteString;
}

static NSString *CCTVBuildTag(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"未知";
}
static NSString *CCTVImportRuntimeLabel(NSString *runtime) {
    if([runtime isEqual:@"node"])return @"Node.js Mobile 18.20.4";
    if([runtime isEqual:@"python"])return @"CPython 3.13";
    if([runtime isEqual:@"javascript"])return @"JavaScriptCore";
    return runtime.length?runtime:@"未识别";
}
static NSString *CCTVImportProtocolLabel(NSString *protocol) {
    NSDictionary *labels=@{@"python-spider":@"Python Spider",@"python-http":@"Python HTTP 服务",@"catvod-js":@"CatVod / TVBox JS",@"catvod-spider":@"CatPaw JS Spider",@"drpy":@"DRPY",@"cctvhost.media/1":@"CCTVHost Media API",@"catpaw-http":@"CatPaw HTTP",@"iptv-extractor":@"IPTV Extractor",@"widget-extractor":@"Widget Extractor",@"nanotv-service-v2":@"NanoTV Service v2",@"hamo-source-v3":@"Hamo Source v3"};
    return labels[protocol]?: (protocol.length?protocol:@"未知协议");
}
static NSArray<NSDictionary *> *CCTVPlaylistSnapshotRows(NSArray *channels,NSString *source) {
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray arrayWithCapacity:channels.count];
    for(id value in channels){
        if([value isKindOfClass:NSDictionary.class]){if([NSPropertyListSerialization propertyList:value isValidForFormat:NSPropertyListBinaryFormat_v1_0])[rows addObject:[value copy]];continue;}
        if(![value isKindOfClass:M3UChannel.class])continue;
        M3UChannel *channel=value;NSMutableDictionary *row=[@{@"name":channel.name?:@"未命名频道",@"group":channel.group?:@"订阅",@"verified":@NO,@"remoteURL":channel.url?:@"",@"subscriptionSources":source.length?@[source]:@[]} mutableCopy];
        if(channel.epgID.length)row[@"epgID"]=channel.epgID;if(channel.tvgName.length)row[@"tvgName"]=channel.tvgName;if(channel.logo.length)row[@"logo"]=channel.logo;if(channel.headers.count)row[@"headers"]=channel.headers;
        if([NSPropertyListSerialization propertyList:row isValidForFormat:NSPropertyListBinaryFormat_v1_0])[rows addObject:row.copy];
    }
    return rows.copy;
}
static void *const kAVItemStatusContext = (void *)&kAVItemStatusContext;
static void *const kAVLayerFrameContext = (void *)&kAVLayerFrameContext;
// 这两个键名来自 CNPlayerSDK 导出常量（值即常量名本身），SDK 缺 Title 会直接拒播并报错误码 4012
static NSString *const kOptTitle = @"CNPlayerConfigOptionKey_Title";
static NSString *const kOptDefaultRate = @"CNPlayerConfigOptionKey_DefaultRate";
static NSString *const kOptUserID = @"CNPlayerConfigOptionKey_UserID";
static NSString *const kOptURLChannelIDForStats = @"CNPlayerConfigOptionKey_URLSource_VID_ChannelIDUsedStat";
static UIImage *CCTVChannelLogoImage(NSDictionary *channel) {
    NSString *identifier=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    if(identifier.length){UIImage *asset=[UIImage imageNamed:[@"ChannelLogo_" stringByAppendingString:identifier]];if(asset)return asset;}
    static NSCache<NSString *,UIImage *> *cache;static dispatch_once_t once;dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=100;});
    NSString *cacheKey=identifier.length?identifier:([channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"频道");
    UIImage *cached=[cache objectForKey:cacheKey];if(cached)return cached;
    NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:(identifier.length?identifier:@"直播频道");
    NSUInteger hash=2166136261u;for(NSUInteger index=0;index<cacheKey.length;index++){hash^=[cacheKey characterAtIndex:index];hash*=16777619u;}
    NSArray<UIColor *> *palette=@[[UIColor colorWithRed:.78 green:.05 blue:.20 alpha:1],[UIColor colorWithRed:.10 green:.38 blue:.72 alpha:1],[UIColor colorWithRed:.85 green:.36 blue:.08 alpha:1],[UIColor colorWithRed:.14 green:.52 blue:.43 alpha:1],[UIColor colorWithRed:.48 green:.29 blue:.69 alpha:1]];UIColor *accent=palette[hash%palette.count];
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];format.scale=2;format.opaque=NO;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(120,72) format:format];
    UIImage *generated=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){(void)context;
        CGRect bounds=CGRectMake(1,1,118,70);UIBezierPath *card=[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:10];[[accent colorWithAlphaComponent:.10] setFill];[card fill];[[accent colorWithAlphaComponent:.55] setStroke];card.lineWidth=1.5;[card stroke];
        CGFloat fontSize=14;UIFont *font=[UIFont systemFontOfSize:fontSize weight:UIFontWeightBold];NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:accent};while(fontSize>9&&[name sizeWithAttributes:attributes].width>bounds.size.width-12){fontSize-=1;font=[UIFont systemFontOfSize:fontSize weight:UIFontWeightBold];attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:accent};}
        CGSize textSize=[name sizeWithAttributes:attributes];[name drawAtPoint:CGPointMake(CGRectGetMidX(bounds)-textSize.width/2,CGRectGetMidY(bounds)-textSize.height/2) withAttributes:attributes];
    }];[cache setObject:generated forKey:cacheKey];return generated;
}
static BOOL CCTVChannelLogoNeedsDarkBacking(NSString *identifier) {
    return [identifier hasPrefix:@"cctv"]||[identifier hasPrefix:@"cetv"]||[identifier isEqual:@"neimenggu"]||[identifier isEqual:@"neimenggu2"];
}
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
// 订阅来源只应是字符串数组；缓存/旧版本数据里一旦混入非数组，
// setWithArray:/containsObject: 会直接抛异常。统一归一为空数组。
static NSArray *CCTVStringArrayValue(id value) {
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
static NSString *CCTVRouteGroupKey(NSDictionary *channel) {
    NSString *rawEPGID=[channel[@"epgID"] isKindOfClass:NSString.class]?channel[@"epgID"]:@"";
    NSString *epgID=[rawEPGID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(epgID.length)return [@"tvg-id:" stringByAppendingString:epgID.lowercaseString];
    // A shared display name is not enough evidence that two URLs carry the same channel.
    NSString *channelID=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    return [@"channel:" stringByAppendingString:channelID];
}

static BOOL CCTVRouteRequiresSDK(NSDictionary *route) {
    if([route[@"requiresSDK"] boolValue]||[route[@"drm"] boolValue])return YES;
    NSString *raw=[route[@"url"] isKindOfClass:NSString.class]?route[@"url"]:@"";
    NSURLComponents *components=nil;@try{if(raw.length<=8192)components=[NSURLComponents componentsWithString:raw];}@catch(NSException *exception){}
    NSString *path=components.percentEncodedPath.lowercaseString?:@"",*query=components.percentEncodedQuery.lowercaseString?:@"";
    // UDRM endpoints can omit EXT-X-KEY while still requiring the broadcaster's SDK.
    return [path containsString:@"/udrm"]||[query containsString:@"udrm"];
}

static void CCTVApplyImmersiveScrollGeometry(UIScrollView *scroll, CGRect frame, UIEdgeInsets insets) {
    if(!scroll)return;
    CGRect oldFrame=scroll.frame;UIEdgeInsets oldInsets=scroll.contentInset;CGPoint offset=scroll.contentOffset;
    BOOL wasAtTop=offset.y<=-oldInsets.top+1;
    CGFloat originDelta=CGRectGetMinY(oldFrame)-CGRectGetMinY(frame);
    scroll.frame=frame;scroll.contentInset=insets;scroll.scrollIndicatorInsets=insets;
    if(wasAtTop)offset.y=-insets.top;else if(fabs(originDelta)>0.5)offset.y+=originDelta;
    if(fabs(scroll.contentOffset.y-offset.y)>0.5)scroll.contentOffset=offset;
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
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();
    self.tableView=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.tableView.backgroundColor=HostBackground();
    self.tableView.dataSource=self;self.tableView.delegate=self;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=66;
    self.tableView.separatorColor=HostSeparator();
    self.emptyLabel=[UILabel new];self.emptyLabel.text=self.emptyMessage?:@"暂无可显示内容";self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.numberOfLines=0;self.emptyLabel.textAlignment=NSTextAlignmentCenter;
    self.tableView.backgroundView=self.emptyLabel;
    [self.view addSubview:self.tableView];
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.backgroundColor=HostBackground();
    self.tableView.backgroundColor=HostBackground();
    self.tableView.separatorColor=HostSeparator();
    self.emptyLabel.textColor=HostSecondaryText();
    [self.tableView reloadData];
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
    if(!cell){cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];cell.backgroundColor=HostCard();cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=3;cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();}
    NSDictionary *item=self.items[indexPath.row];BOOL selected=[item[@"selected"] boolValue];
    cell.backgroundColor=selected?HostSelectedSurface():HostCard();
    cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;
    cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());
    cell.textLabel.text=item[@"title"]?:@"";cell.detailTextLabel.text=item[@"detail"]?:@"";
    cell.textLabel.textColor=selected?HostAccent():HostText();cell.detailTextLabel.textColor=HostSecondaryText();
    cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;
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

@interface CCTVChannelListCell : UITableViewCell @end
@implementation CCTVChannelListCell
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width=CGRectGetWidth(self.contentView.bounds),height=CGRectGetHeight(self.contentView.bounds);
    self.imageView.contentMode=UIViewContentModeScaleAspectFit;
    self.imageView.frame=CGRectMake(12,MAX(4,(height-36)/2),56,36);
    CGFloat titleHeight=MIN(height,ceil(self.textLabel.font.lineHeight)),detailHeight=MIN(MAX(0,height-titleHeight-4),ceil(self.detailTextLabel.font.lineHeight*MAX(1,self.detailTextLabel.numberOfLines)));
    CGFloat blockHeight=titleHeight+3+detailHeight,top=MAX(4,floor((height-blockHeight)/2));
    CGFloat textX=80,accessorySpace=self.accessoryView?44:(self.accessoryType==UITableViewCellAccessoryDisclosureIndicator?30:12);
    CGFloat textWidth=MAX(0,width-textX-accessorySpace);
    self.textLabel.frame=CGRectMake(textX,top,textWidth,titleHeight);
    self.detailTextLabel.frame=CGRectMake(textX,top+titleHeight+3,textWidth,detailHeight);
}
@end

@interface RootViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate, AVPlayerViewControllerDelegate, UINavigationControllerDelegate>
@property(nonatomic,strong) ResourceImportWorkflowViewController *resourceImportWorkflow;
- (void)saveImportCandidate:(NSDictionary *)candidate update:(BOOL)update completion:(void (^)(NSError *error))completion;
- (NSString *)importPlaylistData:(NSData *)data name:(NSString *)name metadata:(NSDictionary *)metadata;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSURLSessionTask *> *subscriptionEditTasks;
- (void)replaceSubscription:(NSString *)source URL:(NSString *)url values:(NSDictionary *)values disabled:(BOOL)disabled completion:(void (^)(NSError *error))completion;
- (void)openSubscriptionProfile:(NSString *)source editing:(BOOL)editing;
// 播放
@property (nonatomic, strong) UIView *playerBox;
@property (nonatomic, strong) UIView *playerTopScrim;
@property (nonatomic, strong) CAGradientLayer *playerTopGradient;
@property (nonatomic, strong) UIView *playerBottomScrim;
@property (nonatomic, strong) CAGradientLayer *playerBottomGradient;
@property (nonatomic, strong) CAGradientLayer *bottomDockFadeGradient;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIImageView *playerChannelLogo;
@property (nonatomic, strong) UIStackView *controlBar;
@property (nonatomic, strong) UIButton *liveResourceCapsule;
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) UIButton *muteBtn;
@property (nonatomic, strong) UIButton *routeBtn;
@property (nonatomic, strong) UIButton *epgBtn;
@property (nonatomic, strong) UIButton *castBtn;
@property (nonatomic, strong) AVRoutePickerView *hiddenRoutePicker;
@property (nonatomic, copy) NSString *activeAirPlayRouteName;
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
@property (nonatomic, strong) CCTVTimeshiftController *timeshiftController;
@property(nonatomic,copy) NSString *nativeTransitionKind;
@property(nonatomic) BOOL nativeTimeShiftActive;
@property (nonatomic) BOOL nativePlaybackFailed;
@property (nonatomic, strong) LocalServiceReadiness *playbackReadiness;
@property (nonatomic, strong) NSMutableDictionary<NSString *,LocalServiceReadiness *> *subscriptionReadiness;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingSubscriptionRefresh;
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
@property(nonatomic) BOOL bundledMediaSeedInProgress;
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
@property (nonatomic, assign) BOOL nativeSafeStartupActive;
@property (nonatomic, assign) NSTimeInterval nativeAttemptStartedAt;
@property (nonatomic, strong) NSMutableSet<NSString *> *serviceOperations;
// 频道
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UICollectionView *channelGrid;
@property (nonatomic, strong) UISegmentedControl *playerTabs;
@property (nonatomic, strong) UIViewController *playbackPanel;
@property (nonatomic, strong) UIViewController *tabPage;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIViewController *> *tabPages;
@property (nonatomic, strong) UIButton *resourceActionsButton;
@property (nonatomic, assign) BOOL gridMode;
@property (nonatomic, assign) NSInteger channelSortMode;
@property (nonatomic, assign) NSInteger gridColumns;
@property (nonatomic, assign) BOOL playerExpanded;
@property (nonatomic, copy) NSString *activeSource;
@property (nonatomic, strong) UIView *catalogTopImmersiveScrim;
@property (nonatomic, strong) CAGradientLayer *catalogTopImmersiveGradient;
@property (nonatomic, strong) UIView *catalogGroupGlassCard;
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
// Native SDK session, bumped at every native play start and on stopPlayback.
// The session delegate captures the ID at creation; a stale delegate drops
// callbacks from the previous stream. Timeshift/back-to-live bump
// playbackGeneration but keep the session, so they do not touch these.
@property (nonatomic, assign) NSUInteger nativeSessionID;
@property (nonatomic, strong) CNPlayerSessionDelegate *nativeSessionDelegate;
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
@property (nonatomic, strong) UIView *bottomBarBackdrop;
@property (nonatomic, strong) UIVisualEffectView *bottomDockGlass;
@property (nonatomic, strong) UIView *liveMiniPlayerBar;
@property (nonatomic, strong) UILabel *liveMiniPlayerLabel;
@property (nonatomic, strong) UIButton *liveMiniPlayerResumeButton;
@property (nonatomic, strong) UIButton *liveMiniPlayerCloseButton;
@property (nonatomic, strong) NSTimer *liveSleepTimer;
@property (nonatomic, assign) NSInteger liveSleepMinutes;
@property (nonatomic, strong) UIView *catalogFloatingControls;
@property (nonatomic, strong) UIButton *catalogLayoutButton;
@property (nonatomic, strong) UIButton *catalogMoreButton;
@property (nonatomic, strong) AVRoutePickerView *catalogFloatingAirPlayPicker;
@property (nonatomic, assign) NSInteger activeTab;
@property (nonatomic, assign) BOOL initialTabRestorePending;
@property (nonatomic, assign) BOOL restoringLastTab;
@property (nonatomic, assign) BOOL userInitiatedTabSelection;
@property (nonatomic, assign) BOOL subscriptionCatalog;
@property (nonatomic, assign) BOOL favoritesOnly;
@property (nonatomic, assign) BOOL recentsOnly;
@property (nonatomic, strong) UIButton *moreBtn;
@property (nonatomic, copy) NSString *epgChannel;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSURLSessionDataTask *> *subscriptionTasks;
@property(nonatomic,strong) NSMutableSet<NSString *> *remoteAttemptedURLs;
@property(nonatomic) NSUInteger catalogSearchGeneration;
@property(nonatomic,strong) AVPlayer *moviePlayer;
@property(nonatomic,strong) AVPlayerViewController *movieController;
@property(nonatomic) BOOL moviePiPActive;
@property(nonatomic,strong) MediaPackageDownloader *packageDownloader;
@property(nonatomic,strong) TVBoxCatalogDownloader *tvboxCatalogDownloader;
@property(nonatomic,strong) TVBoxCatalogBulkImporter *tvboxCatalogBulkImporter;
@property(nonatomic,strong) TVBoxCatalogPackageExporter *tvboxCatalogPackageExporter;
@property(nonatomic,strong) UIAlertController *tvboxCatalogExportProgressAlert;
@property(nonatomic,copy) NSString *pendingTVBoxExt;
@property(nonatomic,copy) NSString *pendingTVBoxSiteName;
@property(nonatomic,strong) NSMutableDictionary *catalogStates;
@property(nonatomic) NSUInteger remoteRetryCount;
@property(nonatomic) BOOL remoteFailureRecoveryPending;
@property(nonatomic) BOOL remotePlaybackFailed;
@property(nonatomic) BOOL nativeRetryPending;
@property(nonatomic) BOOL livePlaybackSuspendedForNavigation;
@property(nonatomic,strong) AVPlayer *previewPlayer;
@property(nonatomic,strong) AVPlayerLayer *previewLayer;
@property(nonatomic,strong) UIView *previewBox;
@property(nonatomic,strong) NSTimer *previewTimer;
@property(nonatomic,assign) NSUInteger selectionVersion;
@property(nonatomic,assign) NSTimeInterval selectionRequestedAt;
@property(nonatomic,assign) NSUInteger playbackIntentVersion;
@property(nonatomic,assign) NSUInteger subscriptionParseGeneration;
@property(nonatomic,copy) NSDictionary *pendingNativeReplayProgram;
- (void)loadChannels;
- (void)
configureCatalogNavigation;
- (BOOL)hasVisibleExpandedLivePlayer;
- (BOOL)isExpandedLivePlayerVisible;
- (CGFloat)playerOverlayTopInset;
- (UIEdgeInsets)playerOverlayInsets;
- (void)showCatalogSearch;
- (void)updateLiveResourceCapsule;
- (void)selectLiveResourceSource:(nullable NSString *)source;
- (BOOL)subscriptionOwner:(NSString *)owner matchesLiveResourceSource:(NSString *)source;
- (void)activateAudioSession;
- (void)setupRemoteCommands;
- (void)registerCallbackProtocol;
- (void)setupSDK;
- (void)refreshConfigurationPage;
- (void)selectBottomTab
:(UIButton *)sender;
- (void)stopPreview;
- (id)call:(id)object sel:(NSString *)name;
- (id)call:(id)object sel:(NSString *)name args:(NSArray *)arguments;
- (void)restartEPGTimer;
- (void)refreshNowNext;
- (void)buildBottomBar;
- (MediaBrowserViewController *)mediaPageCreatingIfNeeded;
- (void)showServiceError:(NSString *)message;
- (void)exportDiagnosticLog;
- (void)clearDiagnosticLog;
- (void)displayNativePlaybackFailure:(NSString *)stage error:(nullable NSError *)error;
- (BOOL)recoverNativeStartupForReason:(NSString *)reason;
- (void)suspendLivePlaybackForReason:(NSString *)reason;
- (void)toggleCurrentFavorite;
- (void)playAdjacentChannel:(NSInteger)direction;
- (void)scrollCatalogToPlayingChannel;
- (void)retryPlaybackWithAlternateSource;
- (MPRemoteCommandHandlerStatus)stepToNextChannelForRemoteCommand:(MPRemoteCommandEvent *)event;
- (MPRemoteCommandHandlerStatus)stepToPreviousChannelForRemoteCommand:(MPRemoteCommandEvent *)event;
- (void)openDiagnosticLog;
- (void)openDiagnosticLogForIdentifier:(nullable NSString *)identifier name:(nullable NSString *)name;
- (void)openPluginRunLogForIdentifier:(NSString *)identifier name:(NSString *)name run:(NSDictionary *)run;
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name;
- (void)openPluginResource:(NSString *)source;
- (void)openTVBoxCatalog:(NSString *)identifier;
- (void)subscribeLiveFromCatalog:(NSDictionary *)live catalogID:(NSString *)identifier;
- (void)installBundledMediaResourcesIfNeeded;
- (void)bulkImportTVBoxCatalog:(NSString *)identifier page:(nullable TVBoxCatalogViewController *)page;
- (void)importTVBoxSite:(NSDictionary *)site;
- (void)importTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport;
- (void)downloadPackageURL:(NSURL *)url headers:(nullable NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSDictionary *,NSError *))completion;
- (void)downloadPackageURL:(NSURL *)url headers:(nullable NSDictionary<NSString *,NSString *> *)headers runtimeHint:(nullable NSString *)runtimeHint completion:(void (^)(NSDictionary *,NSError *))completion;
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error autoBrowse:(BOOL)autoBrowse;
- (void)saveImportedMedia:(NSDictionary *)service autoBrowse:(BOOL)autoBrowse;
- (void)usePluginService:(NSDictionary *)service kind:(NSString *)kind;
- (void)continueRemotePlaybackForURL:(NSString *)url service:(NSDictionary *)service generation:(NSUInteger)generation;
- (NSDictionary *)localServiceForChannel:(NSDictionary *)channel URL:(NSURL *)url;
- (NSArray<NSString *> *)managedSubscriptionSourcesForService:(NSDictionary *)service excludingURL:(NSString *)url;
- (void)openServiceEditorForService:(NSDictionary *)service;
- (void)applyServiceConfigurationFrom:(NSDictionary *)previous to:(NSDictionary *)updated completion:(void (^)(NSError * _Nullable error))completion;
- (void)saveImportedMedia:(NSDictionary *)service;
- (void)toggleCatalogLayout;
- (void)toggleCatalogColumns;
- (NSArray<NSString *> *)currentCatalogGroupTitles;
- (void)syncGroupControlSegments;
- (NSString *)activeAirPlayDeviceName;
- (void)handleAudioRouteChange:(NSNotification *)notification;
- (void)showCastingCenter;
- (void)triggerSystemAirPlayPicker;
- (BOOL)switchToAirPlayCompatibleRouteIfPossible;
- (NSString *)castableStreamURLForCurrentChannel;
- (UIView *)buildCatalogEmptyBackgroundViewWithMessage:(NSString *)message;
- (void)enableNativeChannelsFromEmptyState;
- (void)resetCatalogFilterToAll;
- (void)shareDiagnosticLogAtURL:(NSURL *)source;
- (void)exportResource:(NSString *)source format:(NSString *)format;
- (void)exportCatalogSingleResource:(NSString *)source resource:(NSDictionary *)resource kind:(NSString *)kind index:(NSUInteger)index;
- (void)exportCatalogPackage:(NSString *)identifier token:(nullable NSString *)token;
- (NSDictionary *)resourceServiceForSource:(NSString *)source;
- (void)restartMediaService:(NSDictionary *)source completion:(void (^)(NSError *))completion;
- (void)refreshSubscriptionForProfile:(NSString *)source;
- (void)recheckProfileHealth:(NSString *)source;
- (void)rematchEPGForProfile:(NSString *)source;
- (void)refreshTVBoxCatalogProfile:(NSString *)source;
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
    self.navigationController.delegate=self;
    [self applyFontSizeOverride];
    HostStyleNavigation(self.navigationController);
    self.view.tintColor=HostAccent();
    NSUserDefaults *preferences=NSUserDefaults.standardUserDefaults;
    if(![preferences boolForKey:@"cctv.manualStartupLoadingMigration.v1"]){[preferences setBool:NO forKey:@"resumeLastChannel"];[preferences setBool:YES forKey:@"cctv.manualStartupLoadingMigration.v1"];}
    // 启动恢复可由设置页关闭：关闭后每次打开都从央视直播开始。
    BOOL restoreLastTab=CCTVBoolPreference(@"cctv.restoreLastTab.v1",YES);
    id savedTab=restoreLastTab?[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.lastBottomTab.v1"]:nil;
    if([savedTab respondsToSelector:@selector(integerValue)]&&[savedTab integerValue]>=0&&[savedTab integerValue]<=4){self.activeTab=[savedTab integerValue];self.initialTabRestorePending=self.activeTab!=0;}
    self.gridMode = [[NSUserDefaults standardUserDefaults] objectForKey:@"channelGridMode"] ? [[NSUserDefaults standardUserDefaults] boolForKey:@"channelGridMode"] : YES;
    self.channelSortMode = [[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.channelSortMode.v1"];
    id savedGridColumns=[preferences objectForKey:@"cctv.channelGridColumns.v1"];
    NSInteger gridColumns=[savedGridColumns respondsToSelector:@selector(integerValue)]?[savedGridColumns integerValue]:4;
    self.gridColumns=gridColumns==3?3:4;
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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadThemeAppearance) name:@"HostThemeDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioRouteChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    [self installBundledMediaResourcesIfNeeded];
}

- (void)installBundledMediaResourcesIfNeeded {
    NSUserDefaults *preferences=NSUserDefaults.standardUserDefaults;NSString *seedKey=@"cctv.bundledMediaResources.v4";
    if(self.bundledMediaSeedInProgress)return;
    BOOL alreadySeeded=[preferences boolForKey:seedKey];
    self.bundledMediaSeedInProgress=YES;
    NSArray *catalogSpecs=@[
        @{@"file":@"lytvs-ios",@"id":@"builtin-lytvs-ios",@"name":@"Hawk iOS 内部影视与 PY 聚合",@"kind":@"tvbox",@"url":@"https://sub.lytvs.top/get?token=__LYTVS_SUBSCRIPTION_TOKEN__&client=ios"},
        @{@"file":@"for-adm",@"id":@"builtin-for-adm",@"name":@"For-ADM CCTVHost 影视资源合集",@"kind":@"tvbox",@"url":@"https://raw.githubusercontent.com/joeshu/For-ADM/master/CCTVHost/For-ADM.json"}
    ];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        BOOL complete=YES,changed=NO;
        if(!alreadySeeded){
            for(NSString *retiredID in @[@"builtin-haoliang-live",@"builtin-haoliang-py",@"builtin-haoliang-tvbox"]){if([TVBoxCatalogStore catalogForID:retiredID]){[TVBoxCatalogStore removeCatalog:retiredID];changed=YES;}}
            for(NSDictionary *spec in catalogSpecs){
                NSString *identifier=spec[@"id"];if([TVBoxCatalogStore catalogForID:identifier])continue;
                NSString *catalogURL=[spec[@"url"] isKindOfClass:NSString.class]?spec[@"url"]:@"";BOOL alreadyImported=NO;
                if(catalogURL.length){NSURLComponents *expected=[NSURLComponents componentsWithString:catalogURL];for(NSDictionary *existing in [TVBoxCatalogStore catalogs]){NSString *existingURL=[existing[@"url"] isKindOfClass:NSString.class]?existing[@"url"]:@"";NSURLComponents *actual=[NSURLComponents componentsWithString:existingURL];BOOL sameLocation=expected.host.length&&[actual.host.lowercaseString isEqual:expected.host.lowercaseString]&&[actual.path isEqual:expected.path];BOOL sameForADM=[identifier isEqual:@"builtin-for-adm"]&&[existing[@"name"] isEqual:spec[@"name"]];if(sameLocation||sameForADM){alreadyImported=YES;break;}}}
                if(alreadyImported)continue;
                NSString *path=[NSBundle.mainBundle pathForResource:spec[@"file"] ofType:@"json" inDirectory:@"BuiltinMedia"];NSData *data=path?[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL]:nil;NSError *error=nil;NSDictionary *parsed=data?[TVBoxCatalogStore parseData:data sourceURL:nil error:&error]:nil;
                if(!parsed){complete=NO;[RuntimeDiagnostics.shared recordEvent:@"bundled_media_catalog_import_failed" category:@"resource_import" fields:@{@"resource_id":identifier?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@"bundle resource missing or invalid"}];continue;}
                NSMutableDictionary *catalog=[parsed mutableCopy];catalog[@"id"]=identifier;catalog[@"name"]=spec[@"name"];catalog[@"catalogKind"]=spec[@"kind"];catalog[@"bundledResourceID"]=identifier;if(catalogURL.length)catalog[@"url"]=catalogURL;[TVBoxCatalogStore saveCatalog:catalog];changed=YES;
            }
            NSString *pluginID=@"zen.keke.rex.stream";BOOL pluginFound=NO;for(NSDictionary *service in [ServiceStore services])if([service[@"bundledResourceID"] isEqual:pluginID]){pluginFound=YES;break;}
            if(!pluginFound){NSString *path=[NSBundle.mainBundle pathForResource:@"zen-keke-stream" ofType:@"js" inDirectory:@"BuiltinMedia"];NSError *error=nil;NSDictionary *imported=path?[MediaPackageImporter importFile:[NSURL fileURLWithPath:path] error:&error]:nil;if(!imported){complete=NO;[RuntimeDiagnostics.shared recordEvent:@"bundled_media_script_import_failed" category:@"resource_import" fields:@{@"resource_id":pluginID,@"error_code":@(error.code),@"error_message":error.localizedDescription?:@"bundle resource missing or invalid"}];}else{NSMutableDictionary *service=[imported mutableCopy];NSMutableDictionary *manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];service[@"name"]=@"可可影视播放源";service[@"bundledResourceID"]=pluginID;service[@"capabilities"]=@[@"search",@"detail",@"play"];manifest[@"name"]=@"可可影视播放源";manifest[@"capabilities"]=@[@"search",@"detail",@"play"];service[@"manifest"]=manifest;[ServiceStore save:service];changed=YES;}}
        }
        NSArray *scriptSpecs=@[
            @{@"file":@"hongguo-python",@"extension":@"py",@"runtime":@"python",@"id":@"builtin-hongguo-python",@"name":@"红果短剧 Python 版"},
            @{@"file":@"hongguo-node",@"extension":@"js",@"runtime":@"node",@"id":@"builtin-hongguo-node",@"name":@"红果短剧 JS 版"}
        ];
        NSArray *capabilities=@[@"home",@"category",@"search",@"detail",@"play",@"proxy"];
        for(NSDictionary *spec in scriptSpecs){
            NSString *identifier=spec[@"id"];NSDictionary *existingService=nil;
            for(NSDictionary *service in [ServiceStore services])if([service[@"bundledResourceID"] isEqual:identifier]){existingService=service;break;}
            NSString *path=[NSBundle.mainBundle pathForResource:spec[@"file"] ofType:spec[@"extension"] inDirectory:@"BuiltinMedia"];
            if(existingService){
                NSString *installedPath=[ServiceStore codePath:existingService];
                NSData *bundleData=path?[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL]:nil;
                NSData *installedData=installedPath.length?[NSData dataWithContentsOfFile:installedPath options:NSDataReadingMappedIfSafe error:NULL]:nil;
                BOOL codeUpdated=NO;
                if(bundleData.length&&installedPath.length&&![installedData isEqualToData:bundleData]){
                    [NSFileManager.defaultManager createDirectoryAtPath:installedPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
                    codeUpdated=[bundleData writeToFile:installedPath options:NSDataWritingAtomic error:NULL];
                }
                NSDictionary *manifest=[existingService[@"manifest"] isKindOfClass:NSDictionary.class]?existingService[@"manifest"]:@{};
                NSDictionary *opts=[manifest[@"options"] isKindOfClass:NSDictionary.class]?manifest[@"options"]:@{};
                BOOL metaNeedsUpdate=![existingService[@"capabilities"] isEqual:capabilities]||![manifest[@"capabilities"] isEqual:capabilities]||[opts[@"playTimeoutMs"] integerValue]<120000;
                if(codeUpdated||metaNeedsUpdate){
                    NSMutableDictionary *service=[existingService mutableCopy],*updatedManifest=[manifest mutableCopy]?:[NSMutableDictionary dictionary];
                    NSMutableDictionary *options=[opts mutableCopy]?:[NSMutableDictionary dictionary];options[@"playTimeoutMs"]=@120000;
                    service[@"capabilities"]=capabilities;updatedManifest[@"capabilities"]=capabilities;updatedManifest[@"options"]=options;
                    if(codeUpdated)service[@"updated"]=@(NSDate.date.timeIntervalSince1970);
                    service[@"manifest"]=updatedManifest;[ServiceStore save:service];changed=YES;
                }
                continue;
            }
            if(alreadySeeded)continue;
            NSError *error=nil;NSDictionary *imported=path?[MediaPackageImporter importFile:[NSURL fileURLWithPath:path] companionFiles:@{} runtimeHint:spec[@"runtime"] error:&error]:nil;
            if(!imported){complete=NO;[RuntimeDiagnostics.shared recordEvent:@"bundled_media_script_import_failed" category:@"resource_import" fields:@{@"resource_id":identifier,@"error_code":@(error.code),@"error_message":error.localizedDescription?:@"bundle resource missing or invalid"}];continue;}
            NSMutableDictionary *service=[imported mutableCopy],*manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];NSMutableDictionary *options=[manifest[@"options"] mutableCopy]?:[NSMutableDictionary dictionary];options[@"playTimeoutMs"]=@120000;
            service[@"name"]=spec[@"name"];service[@"bundledResourceID"]=identifier;service[@"capabilities"]=capabilities;manifest[@"name"]=spec[@"name"];manifest[@"capabilities"]=capabilities;manifest[@"options"]=options;service[@"manifest"]=manifest;[ServiceStore save:service];changed=YES;
        }
        if(complete&&!alreadySeeded)[preferences setBool:YES forKey:seedKey];
        NSString *weboxSeedKey=@"cctv.bundledWeBoxResources.v1";
        BOOL weboxAlreadySeeded=[preferences boolForKey:weboxSeedKey];
        if(!weboxAlreadySeeded){
            BOOL weboxComplete=YES;
            NSString *weboxCatalogID=@"builtin-webox-index";
            NSString *weboxCatalogURL=@"https://ddgksf2013.top/webox/index.json";
            if(![TVBoxCatalogStore catalogForID:weboxCatalogID]){
                NSString *wPath=[NSBundle.mainBundle pathForResource:@"webox-index" ofType:@"json" inDirectory:@"BuiltinMedia"];
                NSData *wData=wPath?[NSData dataWithContentsOfFile:wPath options:NSDataReadingMappedIfSafe error:NULL]:nil;
                NSError *wErr=nil;NSDictionary *wParsed=wData?[TVBoxCatalogStore parseData:wData sourceURL:weboxCatalogURL error:&wErr]:nil;
                if(wParsed){
                    NSMutableDictionary *wCat=[wParsed mutableCopy];wCat[@"id"]=weboxCatalogID;wCat[@"name"]=@"WeBox 影视源合集";wCat[@"catalogKind"]=@"tvbox";wCat[@"bundledResourceID"]=weboxCatalogID;wCat[@"url"]=weboxCatalogURL;
                    [TVBoxCatalogStore saveCatalog:wCat];changed=YES;
                }else weboxComplete=NO;
            }
            NSArray *weboxSpecs=@[
                @{@"file":@"webox-4kvm",@"id":@"builtin-webox-4kvm",@"name":@"4k影视",@"url":@"https://ddgksf2013.top/webox/4k%E5%BD%B1%E8%A7%86.webox.js",@"siteKey":@"webox-4kvm"},
                @{@"file":@"webox-hstream",@"id":@"builtin-webox-hstream",@"name":@"HStream",@"url":@"https://ddgksf2013.top/webox/HStream.webox.js",@"siteKey":@"webox-hstream"},
                @{@"file":@"webox-guazi",@"id":@"builtin-webox-guazi",@"name":@"瓜子",@"url":@"https://ddgksf2013.top/webox/%E7%93%9C%E5%AD%90.webox.js",@"siteKey":@"webox-guazi"},
                @{@"file":@"webox-rou",@"id":@"builtin-webox-rou",@"name":@"肉視頻",@"url":@"https://ddgksf2013.top/webox/%E8%82%89.webox.js",@"siteKey":@"webox-rou"},
                @{@"file":@"webox-one",@"id":@"builtin-webox-one",@"name":@"ONE · 一个",@"url":@"https://ddgksf2013.top/webox/one%E4%B8%80%E4%B8%AA.webox.js",@"siteKey":@"webox-one"}
            ];
            NSArray *weboxCaps=@[@"home",@"category",@"search",@"detail",@"play"];
            for(NSDictionary *wSpec in weboxSpecs){
                NSString *wID=wSpec[@"id"];BOOL wFound=NO;
                for(NSDictionary *svc in [ServiceStore services])if([svc[@"bundledResourceID"] isEqual:wID]||[svc[@"url"] isEqual:wSpec[@"url"]]){wFound=YES;break;}
                if(wFound)continue;
                NSString *wScriptPath=[NSBundle.mainBundle pathForResource:wSpec[@"file"] ofType:@"js" inDirectory:@"BuiltinMedia"];
                NSError *wImportErr=nil;NSDictionary *wImported=wScriptPath?[MediaPackageImporter importFile:[NSURL fileURLWithPath:wScriptPath] error:&wImportErr]:nil;
                if(!wImported){weboxComplete=NO;continue;}
                NSMutableDictionary *wService=[wImported mutableCopy],*wManifest=[wService[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];
                wService[@"name"]=wSpec[@"name"];wService[@"bundledResourceID"]=wID;wService[@"url"]=wSpec[@"url"];wService[@"capabilities"]=weboxCaps;
                wService[@"tvboxSiteKey"]=wSpec[@"siteKey"];wService[@"tvboxSiteKeys"]=@[wSpec[@"siteKey"]];
                wManifest[@"name"]=wSpec[@"name"];wManifest[@"capabilities"]=weboxCaps;wManifest[@"options"]=@{@"playTimeoutMs":@45000};
                wService[@"manifest"]=wManifest;[ServiceStore save:wService];changed=YES;
            }
            if(weboxComplete)[preferences setBool:YES forKey:weboxSeedKey];
        }
        dispatch_async(dispatch_get_main_queue(),^{self.bundledMediaSeedInProgress=NO;if(changed){[self refreshConfigurationPage];MediaBrowserViewController *browser=[self.tabPages[@2] isKindOfClass:MediaBrowserViewController.class]?self.tabPages[@2]:nil;[browser refreshSources];}if(!complete)[self log:@"内置影视资源注册未完成；下次启动会继续检查缺少的资源"];
        });
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(self.navigationController.delegate!=self)self.navigationController.delegate=self;
    if(!self.initialTabRestorePending)return;
    self.initialTabRestorePending=NO;
    NSInteger savedTab=self.activeTab;
    if(savedTab<0||savedTab>=self.bottomBar.arrangedSubviews.count)return;
    self.restoringLastTab=YES;
    [self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews[savedTab]];
    self.restoringLastTab=NO;
}

- (BOOL)shouldHideNavigationBarForVisibleController:(UIViewController *)visibleController {
    if(visibleController!=self)return NO;
    return self.fullscreen||[self hasVisibleExpandedLivePlayer]||self.activeTab==2||self.activeTab==3;
}

- (BOOL)hasVisibleExpandedLivePlayer {
    if(!self.playerExpanded||self.activeTab>=2||!self.channelID.length)return NO;
    BOOL playerMatchesTab=self.favoritesOnly||(self.subscriptionCatalog==([self.currentRemoteURL length]>0));
    return playerMatchesTab;
}

// 展开直播的唯一判定：非全屏且有可见的展开直播播放器。viewDidLayoutSubviews、
// configureCatalogNavigation 与 updateLiveResourceCapsule 共用此谓词，
// 避免三处各自拼写 !fullscreen && hasVisibleExpandedLivePlayer 时漂移。
- (BOOL)isExpandedLivePlayerVisible {
    return !self.fullscreen && [self hasVisibleExpandedLivePlayer];
}

// 播放器覆盖层顶边距：展开直播时贴顶 0，全屏时留出安全区顶边，其余 0。
// 与旧内联三元（expanded 0 / fullscreen safe.top / 其余 0）的取值完全一致。
- (CGFloat)playerOverlayTopInset {
    if ([self isExpandedLivePlayerVisible]) return 0;
    if (self.fullscreen) return self.view.safeAreaInsets.top;
    return 0;
}

// 播放器覆盖层边距：展开直播时上下均为 0，全屏时取全部安全区，其余为 0。
// 底边与旧规则 self.fullscreen ? safe.bottom : 0 的取值完全一致。
- (UIEdgeInsets)playerOverlayInsets {
    if ([self isExpandedLivePlayerVisible]) return UIEdgeInsetsZero;
    if (self.fullscreen) return self.view.safeAreaInsets;
    return UIEdgeInsetsZero;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if(self.fullscreen||[self hasVisibleExpandedLivePlayer])return UIStatusBarStyleLightContent;
    if(@available(iOS 13.0,*)){
        UIUserInterfaceStyle style=self.navigationController.overrideUserInterfaceStyle;
        if(style==UIUserInterfaceStyleUnspecified)style=self.traitCollection.userInterfaceStyle;
        return style==UIUserInterfaceStyleDark?UIStatusBarStyleLightContent:UIStatusBarStyleDarkContent;
    }
    return UIStatusBarStyleDefault;
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if(navigationController!=self.navigationController)return;
    if(viewController!=self&&navigationController.topViewController==self&&self.activeTab==2){
        MediaBrowserViewController *mediaPage=[self.tabPages[@2] isKindOfClass:MediaBrowserViewController.class]?self.tabPages[@2]:nil;
        [mediaPage prepareForNavigationTransition];
    }
    if(viewController!=self&&navigationController.topViewController==self&&self.activeTab==3){
        ConfigCenterViewController *resourcePage=[self.tabPages[@3] isKindOfClass:ConfigCenterViewController.class]?self.tabPages[@3]:nil;
        [resourcePage prepareForNavigationTransition];
    }
    // A push from a compact home/resource tab must reveal the navigation bar at
    // the beginning of the transition so the destination is never presented
    // with a hidden back affordance. Conversely, popping back to a compact tab
    // hides the navigation bar alongside the transition so the top safe area
    // never snaps by 44 pt after didShowViewController.
    BOOL shouldHide=[self shouldHideNavigationBarForVisibleController:viewController];
    if(viewController!=self&&navigationController.navigationBarHidden)[navigationController setNavigationBarHidden:NO animated:animated];
    else if(viewController==self&&navigationController.navigationBarHidden!=shouldHide)[navigationController setNavigationBarHidden:shouldHide animated:animated];
    if(viewController==self)return;
    [navigationController setOverrideTraitCollection:[self fontSizeOverrideTraitCollection] forChildViewController:viewController];
    if(self.activeTab<2)[self suspendLivePlaybackForReason:@"left_live_navigation_page"];
}

- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if(navigationController!=self.navigationController||navigationController.topViewController!=viewController)return;
    // Reconcile after the transition completes. During an interactive-pop that is
    // cancelled, UIKit reports the detail/player as the shown controller here, so
    // the home page cannot leave the navigation bar hidden underneath it.
    BOOL shouldHide=[self shouldHideNavigationBarForVisibleController:viewController];
    if(navigationController.navigationBarHidden!=shouldHide)[navigationController setNavigationBarHidden:shouldHide animated:NO];
    if(viewController==self)HostStyleNavigation(navigationController);
    if(viewController==self&&shouldHide)navigationController.navigationBar.prefersLargeTitles=NO;
    if(viewController==self&&self.activeTab==2){
        MediaBrowserViewController *mediaPage=[self.tabPages[@2] isKindOfClass:MediaBrowserViewController.class]?self.tabPages[@2]:nil;
        if(mediaPage){
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
            [mediaPage refreshHeaderAfterNavigationTransition];
        }
    }
    if(viewController==self&&self.activeTab==3){
        ConfigCenterViewController *resourcePage=[self.tabPages[@3] isKindOfClass:ConfigCenterViewController.class]?self.tabPages[@3]:nil;
        if(resourcePage){
            [self.view setNeedsLayout];
            [self.view layoutIfNeeded];
            [resourcePage refreshHeaderAfterNavigationTransition];
        }
    }
}

- (void)dealloc {
    // 先停播放再拆通知/定时器：stopPlayback 负责拆除 AVPlayerItem 的 status /
    // playbackLikelyToKeepUp 与 avLayer.readyForDisplay 的 KVO、currentPlayer
    // delegate 置 nil、销毁 cicadaPlayer；stopPreview 负责预览播放器与定时器。
    // 若只拆通知而不停播放，悬垂 KVO 会在 item 释放时崩溃。
    [self stopPlayback];
    [self stopPreview];
    MPRemoteCommandCenter *commandCenter = MPRemoteCommandCenter.sharedCommandCenter;
    [commandCenter.playCommand removeTarget:self];
    [commandCenter.pauseCommand removeTarget:self];
    [commandCenter.nextTrackCommand removeTarget:self];
    [commandCenter.previousTrackCommand removeTarget:self];
    [self.packageDownloader cancel];
    [self.tvboxCatalogBulkImporter cancel];
    [self.nativePreloader cancel];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.playbackReadiness cancel];
    for(LocalServiceReadiness *probe in self.subscriptionReadiness.allValues)[probe cancel];
    [self.watchdog invalidate];
    [self.epgTimer invalidate];
    [self.liveSleepTimer invalidate];
    [self.epgTask cancel];
    [self flushDiagnosticLog];
}

- (void)onBackground {
    [(MediaBrowserViewController *)self.tabPages[@2] pauseForBackground];
    BOOL livePageRemainsVisible=self.activeTab<2&&self.navigationController.topViewController==self&&self.presentedViewController==nil;
    [RuntimeDiagnostics.shared recordEvent:@"background_playback_policy" category:@"playback" fields:@{@"active_tab":@(self.activeTab),@"live_page_visible":@(livePageRemainsVisible),@"live_player_present":@(self.currentPlayer!=nil||self.avPlayer!=nil||self.cicadaPlayer!=nil),@"policy":livePageRemainsVisible?@"keep_live_playback":@"suspend_when_outside_live_page"}];
    if(!livePageRemainsVisible)[self suspendLivePlaybackForReason:@"app_background_outside_live_page"];
    [self.nativePreloader cancel];
    [[HostImageLoader shared] cancelPending];
    [self stopPreview];
    [self.epgTimer invalidate];self.epgTimer=nil;
    self.officialEPGRequestGeneration++;[self.epgTask cancel];self.epgTask=nil;
    [[XMLTVStore shared] setPaused:YES];
    // Some native player SDKs pause their stream on resignActive. Keep the
    // active live page eligible for background audio; pages covered by a
    // navigation push or modal were already suspended above.
    if(!livePageRemainsVisible)[self call:self.currentPlayer sel:@"resignActive"];
    if (CCTVBoolPreference(@"autoPiP",NO) && self.avLayer && AVPictureInPictureController.isPictureInPictureSupported && !self.pip.isPictureInPictureActive) {
        self.pip=[[AVPictureInPictureController alloc] initWithPlayerLayer:self.avLayer];
        [self.pip startPictureInPicture];
        [self log:@"后台自动进入画中画"];
    }
    [self log:@"进入后台"];
    [self flushDiagnosticLog];
}

- (void)onForeground {
    [PyHost refreshListenersAfterForeground];
    BOOL playbackPriority=CACurrentMediaTime()<self.playbackPriorityUntil;
    [[XMLTVStore shared] setPaused:playbackPriority];
    [self call:self.currentPlayer sel:@"becomeActive"];
    if(self.epgRefreshDesired&&!playbackPriority){[self restartEPGTimer];[self refreshNowNext];}
    if(self.activeTab<2 && CACurrentMediaTime()>=self.playbackPriorityUntil){[self.channelGrid reloadData];[self.table reloadData];}
    if(self.activeTab==2)[(MediaBrowserViewController *)self.tabPages[@2] resumeAfterForeground];
    [self log:@"回到前台"];
}
- (void)checkVisibleMediaAfterActivation {
    [PyHost refreshListenersAfterForeground];
    if(self.activeTab==2)[(MediaBrowserViewController *)self.tabPages[@2] resumeAfterForeground];
}

#pragma mark - 日志

- (void)restoreDiagnosticLog {
    // 日志文件可达 4 MiB，启动时在主线程同步读 + 脱敏会卡启动；移到后台读，
    // 只保留末尾 256 KiB（就近的崩溃上下文），再回主线程追加到日志缓冲。
    NSString *path=self.diagnosticLogPath;
    if(!path.length)return;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *error=nil;
        NSString *text=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if(text.length>256*1024){
            NSUInteger cut=text.length-256*1024;
            NSRange newline=[text rangeOfString:@"\n" options:0 range:NSMakeRange(cut,MIN(4096,text.length-cut))];
            text=[text substringFromIndex:newline.location!=NSNotFound?NSMaxRange(newline):cut];
        }
        text=[HostLogRedactor redactText:text?:@""];
        if(!text.length)return;
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;if(!owner)return;
            [owner.logBuffer appendString:@"—— 上次运行日志（崩溃/强制退出前）——\n"];
            [owner.logBuffer appendString:text];
            if (![text hasSuffix:@"\n"]) [owner.logBuffer appendString:@"\n"];
            [owner.logBuffer appendString:@"—— 本次启动 ——\n"];
            NSLog(@"[CCTVHost] 已恢复上次运行日志，%lu 字符",(unsigned long)text.length);
        });
    });
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
    if (@available(iOS 14.2, *)) { self.pip.canStartPictureInPictureAutomaticallyFromInline = CCTVBoolPreference(@"autoPiP", NO); }
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

    self.liveResourceCapsule=[UIButton buttonWithType:UIButtonTypeSystem];
    self.liveResourceCapsule.accessibilityIdentifier=@"live.resource.capsule";
    self.liveResourceCapsule.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    self.liveResourceCapsule.hidden=YES;
    [self.view addSubview:self.liveResourceCapsule];
    [self updateLiveResourceCapsule];

    self.playerTopScrim=[UIView new];self.playerTopScrim.userInteractionEnabled=NO;self.playerTopGradient=[CAGradientLayer layer];self.playerTopGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:.76].CGColor,(id)[UIColor colorWithWhite:0 alpha:.36].CGColor,(id)UIColor.clearColor.CGColor];self.playerTopGradient.locations=@[@0,@0.62,@1];self.playerTopGradient.startPoint=CGPointMake(.5,0);self.playerTopGradient.endPoint=CGPointMake(.5,1);[self.playerTopScrim.layer addSublayer:self.playerTopGradient];[self.playerBox addSubview:self.playerTopScrim];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w - 24, 20)];
    self.titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont boldSystemFontOfSize:13]];
    self.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.text = @"选择频道开始播放";
    [self.playerBox addSubview:self.titleLabel];

    self.infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 26, w - 24, 16)];
    self.infoLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    self.infoLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10]];
    self.infoLabel.adjustsFontForContentSizeCategory = YES;
    self.infoLabel.numberOfLines = 1;
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

    self.controlBar = [[UIStackView alloc] initWithFrame:CGRectMake(8, h - 52, w - 16, 44)];
    self.controlBar.axis = UILayoutConstraintAxisHorizontal;
    self.controlBar.distribution = UIStackViewDistributionFillEqually;
    self.controlBar.spacing = 5;
    self.playPauseBtn = [self barButton:@"暂停" action:@selector(togglePlayPause)];
    self.muteBtn = [self barButton:@"静音" action:@selector(toggleMute)];
    self.routeBtn = [self barButton:@"线路" action:@selector(showRoutes)];
    self.epgBtn = [self barButton:@"节目单" action:@selector(openEPG)];
    self.castBtn = [self barButton:@"投屏" action:@selector(showCastingCenter)];
    self.castBtn.accessibilityIdentifier = @"player.control.cast";
    self.moreBtn = [self barButton:@"更多" action:@selector(showMorePlaybackActions)];
    for (UIButton *b in @[self.playPauseBtn, self.muteBtn, self.routeBtn, self.epgBtn, self.castBtn, self.moreBtn]) {
        [self.controlBar addArrangedSubview:b];
    }
    self.hiddenRoutePicker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(-100, -100, 1, 1)];
    self.hiddenRoutePicker.prioritizesVideoDevices = YES;
    self.hiddenRoutePicker.alpha = 0.01;
    self.hiddenRoutePicker.userInteractionEnabled = NO;
    [self.playerBox addSubview:self.hiddenRoutePicker];
    self.playerBottomScrim=[UIView new];self.playerBottomScrim.userInteractionEnabled=NO;self.playerBottomGradient=[CAGradientLayer layer];self.playerBottomGradient.colors=@[(id)UIColor.clearColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:.48].CGColor,(id)[UIColor colorWithWhite:0 alpha:.84].CGColor];self.playerBottomGradient.locations=@[@0,@0.45,@1];self.playerBottomGradient.startPoint=CGPointMake(.5,0);self.playerBottomGradient.endPoint=CGPointMake(.5,1);[self.playerBottomScrim.layer addSublayer:self.playerBottomGradient];[self.playerBox addSubview:self.playerBottomScrim];
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
    NSDictionary<NSString *,NSString *> *symbols=@{@"暂停":@"pause.fill",@"播放":@"play.fill",@"继续播放":@"play.circle.fill",@"静音":@"speaker.wave.2.fill",@"线路":@"antenna.radiowaves.left.and.right",@"节目单":@"list.bullet.rectangle",@"投屏":@"airplayvideo",@"投屏中":@"tv.and.mediabox.fill",@"更多":@"ellipsis.circle"};
    NSString *symbol=symbols[title];
    if(symbol){UIImageSymbolConfiguration *sc=[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];[b setImage:[UIImage systemImageNamed:symbol withConfiguration:sc] forState:UIControlStateNormal];b.imageEdgeInsets=UIEdgeInsetsMake(0,-2,0,3);}
    b.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
    b.titleLabel.adjustsFontForContentSizeCategory = YES;
    // 大字体下 5 个等宽按钮放不下 12pt 放大标题：允许缩到 60% 而不是截断。
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.6;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:1 alpha:0.95];
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.42];
    b.layer.cornerRadius = 12;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 0.65;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    b.titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    b.titleLabel.layer.shadowOpacity = 0.72;
    b.titleLabel.layer.shadowRadius = 2.0;
    b.titleLabel.layer.shadowOffset = CGSizeMake(0, 1);
    HostInstallPressFeedback(b);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)toggleOverlay {
    BOOL nextHidden = !self.controlBar.hidden;
    self.controlBar.hidden = nextHidden;
    self.playerBottomScrim.hidden = nextHidden;
    self.playerTopScrim.hidden = nextHidden;
    self.titleLabel.hidden = nextHidden;
    self.infoLabel.hidden = nextHidden;
    if (!nextHidden && self.firstRender) {
        [self refreshNowNext];
        NSUInteger gen = self.playbackGeneration;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RootViewController *owner = weakSelf;
            if (!owner || owner.playbackGeneration != gen || !owner.firstRender || owner.nativeTimeShiftActive || owner.nativePlaybackFailed || owner.remotePlaybackFailed) return;
            owner.titleLabel.hidden = YES;
            owner.infoLabel.hidden = YES;
            owner.playerTopScrim.hidden = YES;
            owner.playerBottomScrim.hidden = YES;
        });
    }
}

#pragma mark - 列表

- (void)buildList {
    CGFloat y = CGRectGetMaxY(self.playerBox.frame);
    self.catalogTopImmersiveScrim = [UIView new];
    self.catalogTopImmersiveScrim.userInteractionEnabled = NO;
    self.catalogTopImmersiveScrim.accessibilityIdentifier = @"catalog.top.immersive.scrim";
    self.catalogTopImmersiveGradient = [CAGradientLayer layer];
    self.catalogTopImmersiveGradient.locations = @[@0.0, @0.68, @1.0];
    [self.catalogTopImmersiveScrim.layer addSublayer:self.catalogTopImmersiveGradient];
    [self.view addSubview:self.catalogTopImmersiveScrim];
    self.catalogGroupGlassCard = [UIView new];
    self.catalogGroupGlassCard.userInteractionEnabled = NO;
    HostStyleGlassCard(self.catalogGroupGlassCard, 14);
    [self.view addSubview:self.catalogGroupGlassCard];
    self.groupControl = [[UISegmentedControl alloc] initWithItems:[self currentCatalogGroupTitles]];
    self.groupControl.frame = CGRectMake(8, y + 6, self.view.bounds.size.width - 16, 32);
    self.groupControl.selectedSegmentIndex = 0;
    self.groupControl.tintColor = HostAccent();self.groupControl.selectedSegmentTintColor=HostAccent();NSDictionary *segmentNormal=@{NSForegroundColorAttributeName:HostMutedText(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium]]},*segmentSelected=@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]]};[self.groupControl setTitleTextAttributes:segmentNormal forState:UIControlStateNormal];[self.groupControl setTitleTextAttributes:segmentSelected forState:UIControlStateSelected];
    [self.groupControl addTarget:self action:@selector(onGroupChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.groupControl];
    self.playerTabs=[[UISegmentedControl alloc] initWithItems:@[@"分类",@"频道",@"节目",@"线路"]];self.playerTabs.selectedSegmentIndex=1;self.playerTabs.selectedSegmentTintColor=HostAccent();[self.playerTabs setTitleTextAttributes:segmentNormal forState:UIControlStateNormal];[self.playerTabs setTitleTextAttributes:segmentSelected forState:UIControlStateSelected];[self.playerTabs addTarget:self action:@selector(selectPlayerPanel) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.playerTabs];

    self.versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, y + 38, self.view.bounds.size.width - 16, 14)];
    self.versionLabel.textColor = HostSecondaryText();
    self.versionLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9]];
    self.versionLabel.adjustsFontForContentSizeCategory = YES;
    self.versionLabel.text = [NSString stringWithFormat:@"%@ · 点击自动播放 · 长按选线路", CCTVBuildTag()];
    [self.view addSubview:self.versionLabel];

    CGFloat ty = y + 54;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, ty, self.view.bounds.size.width, self.view.bounds.size.height - ty) style:UITableViewStylePlain];self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 66;
    self.table.estimatedSectionHeaderHeight = 0;
    self.table.sectionHeaderTopPadding = 0;
    self.table.backgroundColor = HostBackground();
    self.table.separatorColor = HostSeparator();
    [self.view addSubview:self.table];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(onPullRefresh) forControlEvents:UIControlEventValueChanged];
    self.table.refreshControl = rc;
    UILongPressGestureRecognizer *routePress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLongPress:)];
    [self.table addGestureRecognizer:routePress];
    UICollectionViewFlowLayout *flow=[UICollectionViewFlowLayout new]; flow.minimumInteritemSpacing=6; flow.minimumLineSpacing=8; flow.sectionInset=UIEdgeInsetsMake(8,10,16,10);
    self.channelGrid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:flow]; self.channelGrid.backgroundColor=HostBackground(); self.channelGrid.dataSource=self; self.channelGrid.delegate=self; self.channelGrid.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.channelGrid.accessibilityIdentifier=@"channel.grid";
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
- (NSString *)safeResourceExportName:(NSString *)name {
    NSString *value=[name isKindOfClass:NSString.class]?name:@"资源";NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r"];NSMutableString *safe=[NSMutableString string];[value enumerateSubstringsInRange:NSMakeRange(0,value.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring,NSRange substringRange,NSRange enclosingRange,BOOL *stop){[safe appendString:([substring rangeOfCharacterFromSet:invalid].location==NSNotFound&&[substring rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound)?substring:@"_"];if(safe.length>=64)*stop=YES;}];value=[safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!value.length)value=@"资源";return value;
}
- (NSURL *)writeResourceExportData:(NSData *)data name:(NSString *)name extension:(NSString *)extension error:(NSError **)error {
    if(!data.length){if(error)*error=[NSError errorWithDomain:@"CCTVHostExport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"资源文件内容为空"}];return nil;}NSString *filename=[NSString stringWithFormat:@"%@-%@.%@",[self safeResourceExportName:name],NSUUID.UUID.UUIDString.lowercaseString,extension];NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];if(![data writeToURL:url options:NSDataWritingAtomic error:error])return nil;return url;
}
- (void)exportCatalogSingleResource:(NSString *)source resource:(NSDictionary *)resource kind:(NSString *)kind index:(NSUInteger)index {
    NSString *identifier=[source hasPrefix:@"tvbox:"]?[source substringFromIndex:6]:@"";NSError *error=nil;NSData *data=[TVBoxCatalogStore exportSingleResourceForCatalogID:identifier kind:kind index:index error:&error];if(!data){[self showServiceError:error.localizedDescription?:@"单项资源导出失败"];return;}NSURL *url=[self writeResourceExportData:data name:resource[@"name"]?:@"资源" extension:@"json" error:&error];if(!url){[self showServiceError:error.localizedDescription?:@"单项资源文件写入失败"];return;}[self shareDiagnosticLogAtURL:url];
}
- (void)exportCatalogPackage:(NSString *)identifier token:(NSString *)token {
    if(self.tvboxCatalogPackageExporter){[self showServiceError:@"另一个资源 ZIP 正在生成，请稍后再试"];return;}NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集"];return;}
    TVBoxCatalogPackageExporter *exporter=[[TVBoxCatalogPackageExporter alloc] initWithCatalogID:identifier token:token];self.tvboxCatalogPackageExporter=exporter;NSUInteger total=0;for(NSDictionary *site in [catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[]){NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";NSString *path=[NSURL URLWithString:api].path.lowercaseString?:@"";if([path hasSuffix:@".md5"])path=[path stringByDeletingPathExtension];NSString *ext=path.pathExtension;if([@[@"py",@"js",@"mjs",@"cjs"] containsObject:ext])total++;}
    UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"正在收集合集内部 PY / JS" message:[NSString stringWithFormat:@"准备 0 / %lu",(unsigned long)total] preferredStyle:UIAlertControllerStyleAlert];self.tvboxCatalogExportProgressAlert=progress;__weak typeof(self) weakSelf=self;[progress addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[weakSelf.tvboxCatalogPackageExporter cancel];}]];[self presentViewController:progress animated:YES completion:nil];
    exporter.progressHandler=^(NSUInteger completed,NSUInteger count,NSString *currentName){RootViewController *owner=weakSelf;UIAlertController *active=owner.tvboxCatalogExportProgressAlert;if(active)active.message=[NSString stringWithFormat:@"已处理 %lu / %lu · %@",(unsigned long)completed,(unsigned long)total,currentName.length?currentName:@"准备打包"] ;};
    [exporter startWithCompletion:^(NSURL *url,NSUInteger failedCount,NSError *error){RootViewController *owner=weakSelf;owner.tvboxCatalogPackageExporter=nil;UIAlertController *active=owner.tvboxCatalogExportProgressAlert;owner.tvboxCatalogExportProgressAlert=nil;if(error.code==NSURLErrorCancelled)return;if(!url){if(active.presentingViewController)[active dismissViewControllerAnimated:YES completion:^{[owner showServiceError:error.localizedDescription?:@"资源 ZIP 生成失败"];}];else[owner showServiceError:error.localizedDescription?:@"资源 ZIP 生成失败"];return;}void(^share)(void)=^{if(failedCount)owner.navigationItem.prompt=[NSString stringWithFormat:@"ZIP 已生成 · %lu 个脚本未能获取，详见 source-manifest.json",(unsigned long)failedCount];[owner shareDiagnosticLogAtURL:url];};if(active.presentingViewController){[active dismissViewControllerAnimated:YES completion:^{if(failedCount){UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"资源 ZIP 已生成" message:[NSString stringWithFormat:@"可下载脚本已打包。%lu 项未能获取，具体原因列在 ZIP 内的 source-manifest.json。",(unsigned long)failedCount] preferredStyle:UIAlertControllerStyleAlert];[notice addAction:[UIAlertAction actionWithTitle:@"分享 ZIP" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){share();}]];[notice addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];[owner presentViewController:notice animated:YES completion:nil];}else share();}];}else share();}];
}
- (void)exportResource:(NSString *)source format:(NSString *)format {
    if([source hasPrefix:@"tvbox:"]){NSString *identifier=[source substringFromIndex:6];if([format isEqual:@"catalog-json"]){NSError *error=nil;NSData *data=[TVBoxCatalogStore exportDataForCatalogID:identifier error:&error];NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];NSURL *url=data?[self writeResourceExportData:data name:catalog[@"name"]?:@"资源合集" extension:@"json" error:&error]:nil;if(!url){[self showServiceError:error.localizedDescription?:@"资源合集 JSON 导出失败"];return;}[self shareDiagnosticLogAtURL:url];return;}if([format isEqual:@"catalog-zip"]){NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];BOOL needsToken=NO;for(NSDictionary *site in [catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[])if([[site[@"api"] description] containsString:CCTVTVBoxTokenPlaceholder]){needsToken=YES;break;}NSString *token=CCTVTVBoxStoredSubscriptionToken();if(needsToken&&!token.length){UIAlertController *credential=[UIAlertController alertControllerWithTitle:@"导出合集 ZIP" message:@"合集中的部分 PY / JS 文件需要订阅令牌。令牌只保存在本机钥匙串，并用于本次脚本下载；下载失败项会在清单中明确列出。" preferredStyle:UIAlertControllerStyleAlert];[credential addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"token 或完整订阅链接";field.secureTextEntry=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];[credential addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weakSelf=self;[credential addAction:[UIAlertAction actionWithTitle:@"保存并导出" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *entered=CCTVTVBoxTokenFromInput(credential.textFields.firstObject.text?:@"");if(!entered.length){[weakSelf showServiceError:@"请输入有效的订阅令牌或完整订阅链接"];return;}if(!CCTVTVBoxSaveSubscriptionToken(entered)){[weakSelf showServiceError:@"令牌未能保存到本机钥匙串"];return;}[weakSelf exportCatalogPackage:identifier token:entered];}]];[self presentViewController:credential animated:YES completion:nil];return;}[self exportCatalogPackage:identifier token:token];return;}
    }
    if([source hasPrefix:@"plugin:"]){NSDictionary *service=[self resourceServiceForSource:source];if(!service){[self showServiceError:@"找不到该脚本资源"];return;}NSString *path=[service[@"archivePath"] isKindOfClass:NSString.class]?service[@"archivePath"]:@"";if(!path.length||![NSFileManager.defaultManager fileExistsAtPath:path])path=[ServiceStore codePath:service];if(!path.length||![NSFileManager.defaultManager fileExistsAtPath:path]){[self showServiceError:@"此资源没有可导出的代码文件"];return;}[self shareDiagnosticLogAtURL:[NSURL fileURLWithPath:path]];return;}
    NSDictionary *metadata=source.length?[ProfileStore metadata:source]:@{};NSString *name=metadata[@"name"]?:([source hasPrefix:@"local-playlist:"]?@"本地播放列表":([NSURL URLWithString:source].host?:@"央视直播"));NSString *text=[metadata[@"text"] isKindOfClass:NSString.class]?metadata[@"text"]:@"";NSString *extension=([text containsString:@"#EXTM3U"]||[text containsString:@"#EXTINF"])?@"m3u":@"txt";
    if(!text.length){NSMutableArray *lines=[NSMutableArray arrayWithObject:@"#EXTM3U"];NSArray *channels=nil;if(source.length){NSArray *cached=[metadata[@"cachedChannels"] isKindOfClass:NSArray.class]?metadata[@"cachedChannels"]:@[];channels=cached.count?cached:[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *channel,NSDictionary *bindings){return [CCTVStringArrayValue(channel[@"subscriptionSources"]) containsObject:source];}]];}else channels=[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *channel,NSDictionary *bindings){return ![channel[@"remoteURL"] length];}]];
        for(NSDictionary *channel in channels){NSString *channelName=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"频道";NSString *(^attribute)(id)=^NSString *(id value){if(![value isKindOfClass:NSString.class])return @"";return [[(NSString *)value stringByReplacingOccurrencesOfString:@"\"" withString:@"'"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];};NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];NSArray *urls=routes.count?routes:@[@{@"url":channel[@"remoteURL"]?:channel[@"id"]?:@""}];for(NSDictionary *route in urls){NSString *url=[route[@"url"] isKindOfClass:NSString.class]?route[@"url"]:@"";if(![ProfileStore isHTTP:url])continue;NSString *group=attribute(channel[@"group"]),*logo=attribute(channel[@"logo"]),*epg=attribute(channel[@"epgID"]);NSMutableArray *attributes=[NSMutableArray array];if(epg.length)[attributes addObject:[NSString stringWithFormat:@"tvg-id=\"%@\"",epg]];if(logo.length)[attributes addObject:[NSString stringWithFormat:@"tvg-logo=\"%@\"",logo]];if(group.length)[attributes addObject:[NSString stringWithFormat:@"group-title=\"%@\"",group]];[lines addObject:[NSString stringWithFormat:@"#EXTINF:-1 %@,%@",[attributes componentsJoinedByString:@" "],attribute(channelName)]];NSDictionary *headers=[channel[@"headers"] isKindOfClass:NSDictionary.class]?channel[@"headers"]:@{};NSData *headerData=headers.count?[NSJSONSerialization dataWithJSONObject:headers options:0 error:NULL]:nil;NSString *headerJSON=headerData?[[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding]:nil;if(headerJSON.length)[lines addObject:[@"#EXTHTTP:" stringByAppendingString:headerJSON]];[lines addObject:url];}}
        if(lines.count==1&&source.length)[lines addObject:[NSString stringWithFormat:@"# Source URL: %@",source]];text=[lines componentsJoinedByString:@"\n"];extension=@"m3u";
    }
    NSError *error=nil;NSURL *url=[self writeResourceExportData:[text dataUsingEncoding:NSUTF8StringEncoding] name:name extension:extension error:&error];if(!url)[self showServiceError:error.localizedDescription?:@"资源文件导出失败"];else[self shareDiagnosticLogAtURL:url];
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
    NSMutableDictionary *unique=[NSMutableDictionary dictionary];NSMutableArray *dedup=[NSMutableArray array];for(id rawChannel in self.allChannels){if(![rawChannel isKindOfClass:NSDictionary.class])continue;NSDictionary *c=rawChannel;NSString *cid=[c[@"id"] isKindOfClass:NSString.class]?c[@"id"]:nil;if(!cid.length){[dedup addObject:c];continue;}NSNumber *index=unique[cid];if(index){NSMutableDictionary *existing=[dedup[index.unsignedIntegerValue] mutableCopy];NSMutableSet *owners=[NSMutableSet setWithArray:CCTVStringArrayValue(existing[@"subscriptionSources"])];[owners addObjectsFromArray:CCTVStringArrayValue(c[@"subscriptionSources"])];if(owners.count)existing[@"subscriptionSources"]=owners.allObjects;dedup[index.unsignedIntegerValue]=existing;}else{unique[cid]=@(dedup.count);[dedup addObject:c];}}self.allChannels=dedup;
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
    __weak typeof(self) weakSelf = self;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:label
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        RootViewController *owner = weakSelf;
        if (!owner) { done(NO); return; }
        if (fav) [owner.favorites removeObject:cid];
        else [owner.favorites addObject:cid];
        [[NSUserDefaults standardUserDefaults] setObject:owner.favorites forKey:@"favorites"];
        [owner applyFilter];
        done(YES);
    }];
    action.backgroundColor = fav ? HostRaisedSurface() : [UIColor systemOrangeColor];
    UIContextualAction *epgAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"节目单"
                                                                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        RootViewController *owner = weakSelf;
        if (owner) [owner openEPGforChannel:cid name:ch[@"name"] ?: cid];
        done(YES);
    }];
    epgAction.backgroundColor = HostAccent();
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray arrayWithObjects:action, epgAction, nil];
    if (self.recentsOnly) {
        UIContextualAction *removeRecent = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"移除记录"
                                                                                 handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            RootViewController *owner = weakSelf;
            if (!owner) { done(NO); return; }
            NSIndexSet *toRemove = [owner.recents indexesOfObjectsPassingTest:^BOOL(NSDictionary *r, NSUInteger idx, BOOL *stop) {
                return [r[@"id"] isEqualToString:cid];
            }];
            if (toRemove.count) [owner.recents removeObjectsAtIndexes:toRemove];
            [[NSUserDefaults standardUserDefaults] setObject:owner.recents forKey:@"recents"];
            [owner applyFilter];
            done(YES);
        }];
        [actions addObject:removeRecent];
    }
    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

- (NSArray<NSString *> *)currentCatalogGroupTitles {
    return self.subscriptionCatalog
        ? @[@"全部", @"央视", @"卫视", @"地方", @"其他", @"收藏", @"最近"]
        : @[@"全部", @"央视", @"卫视", @"地方", @"教育", @"收藏", @"最近"];
}

- (void)syncGroupControlSegments {
    if (!self.groupControl) return;
    NSArray<NSString *> *titles = [self currentCatalogGroupTitles];
    NSInteger previous = self.groupControl.selectedSegmentIndex;
    if (self.groupControl.numberOfSegments != (NSInteger)titles.count) {
        [self.groupControl removeAllSegments];
        for (NSUInteger i = 0; i < titles.count; i++) {
            [self.groupControl insertSegmentWithTitle:titles[i] atIndex:i animated:NO];
        }
    } else {
        for (NSUInteger i = 0; i < titles.count; i++) {
            if (![[self.groupControl titleForSegmentAtIndex:i] isEqualToString:titles[i]]) {
                [self.groupControl setTitle:titles[i] forSegmentAtIndex:i];
            }
        }
    }
    self.groupControl.selectedSegmentIndex = (previous >= 0 && previous < (NSInteger)titles.count) ? previous : 0;
}

- (void)onGroupChanged {
    NSInteger idx = self.groupControl.selectedSegmentIndex;
    NSArray<NSString *> *titles = [self currentCatalogGroupTitles];
    NSString *selectedTitle = (idx >= 0 && idx < (NSInteger)titles.count) ? titles[idx] : @"全部";
    self.favoritesOnly = [selectedTitle isEqualToString:@"收藏"];
    self.recentsOnly = [selectedTitle isEqualToString:@"最近"];
    [self updateBottomBarSelection];
    [self configureCatalogNavigation];[self applyFilter];
}

- (void)buildBottomBar {
    self.bottomBarBackdrop=[UIView new];self.bottomBarBackdrop.backgroundColor=UIColor.clearColor;self.bottomBarBackdrop.opaque=NO;self.bottomBarBackdrop.userInteractionEnabled=NO;self.bottomBarBackdrop.layer.cornerRadius=0;self.bottomBarBackdrop.clipsToBounds=NO;
    self.bottomDockFadeGradient=[CAGradientLayer layer];self.bottomDockFadeGradient.colors=@[(id)[HostBackground() colorWithAlphaComponent:0.0].CGColor,(id)[HostBackground() colorWithAlphaComponent:0.78].CGColor,(id)[HostBackground() colorWithAlphaComponent:0.96].CGColor];self.bottomDockFadeGradient.locations=@[@0,@0.42,@1];[self.bottomBarBackdrop.layer addSublayer:self.bottomDockFadeGradient];
    self.bottomDockGlass=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];self.bottomDockGlass.userInteractionEnabled=NO;self.bottomDockGlass.layer.cornerRadius=27;self.bottomDockGlass.layer.cornerCurve=kCACornerCurveContinuous;self.bottomDockGlass.clipsToBounds=YES;self.bottomDockGlass.layer.borderWidth=0.8;HostSetLayerBorderColor(self.bottomDockGlass,HostBorder());
    UIView *dockTint=[[UIView alloc] initWithFrame:self.bottomDockGlass.contentView.bounds];dockTint.backgroundColor=HostGlassTint();dockTint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;dockTint.userInteractionEnabled=NO;[self.bottomDockGlass.contentView addSubview:dockTint];
    [self.bottomBarBackdrop addSubview:self.bottomDockGlass];
    [self.view addSubview:self.bottomBarBackdrop];
    self.liveMiniPlayerBar=[UIView new];self.liveMiniPlayerBar.hidden=YES;self.liveMiniPlayerBar.accessibilityIdentifier=@"live.mini-player.bar";HostStyleGlassCard(self.liveMiniPlayerBar,20);
    self.liveMiniPlayerLabel=[UILabel new];self.liveMiniPlayerLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];self.liveMiniPlayerLabel.adjustsFontForContentSizeCategory=YES;self.liveMiniPlayerLabel.textColor=HostText();self.liveMiniPlayerLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.liveMiniPlayerBar addSubview:self.liveMiniPlayerLabel];
    self.liveMiniPlayerResumeButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.liveMiniPlayerResumeButton setTitle:@"继续直播" forState:UIControlStateNormal];HostStylePillButton(self.liveMiniPlayerResumeButton,YES);self.liveMiniPlayerResumeButton.layer.cornerRadius=14;self.liveMiniPlayerResumeButton.contentEdgeInsets=UIEdgeInsetsMake(5,12,5,12);self.liveMiniPlayerResumeButton.accessibilityIdentifier=@"live.mini-player.resume";[self.liveMiniPlayerResumeButton addTarget:self action:@selector(resumeSuspendedLiveFromMiniBar) forControlEvents:UIControlEventTouchUpInside];[self.liveMiniPlayerBar addSubview:self.liveMiniPlayerResumeButton];
    self.liveMiniPlayerCloseButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.liveMiniPlayerCloseButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];self.liveMiniPlayerCloseButton.tintColor=HostSecondaryText();self.liveMiniPlayerCloseButton.accessibilityIdentifier=@"live.mini-player.close";self.liveMiniPlayerCloseButton.accessibilityLabel=@"关闭直播挂起提示";[self.liveMiniPlayerCloseButton addTarget:self action:@selector(dismissSuspendedLiveMiniBar) forControlEvents:UIControlEventTouchUpInside];[self.liveMiniPlayerBar addSubview:self.liveMiniPlayerCloseButton];
    [self.view addSubview:self.liveMiniPlayerBar];
    self.bottomBar=[[UIStackView alloc] init]; self.bottomBar.axis=UILayoutConstraintAxisHorizontal; self.bottomBar.distribution=UIStackViewDistributionFillEqually; self.bottomBar.spacing=3; self.bottomBar.backgroundColor=UIColor.clearColor; self.bottomBar.layer.cornerRadius=27; self.bottomBar.layer.cornerCurve=kCACornerCurveContinuous; self.bottomBar.clipsToBounds=YES;
    NSArray *titles=@[@"CCTV",@"频道",@"影视库",@"资源",@"设置"];
    NSArray *icons=@[@"tv.fill",@"play.rectangle.on.rectangle",@"house.fill",@"externaldrive.fill",@"gearshape"];
    for (NSInteger i=0;i<titles.count;i++) {
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem]; b.tag=i;HostInstallPressFeedback(b);
        UIButtonConfiguration *cfg=[UIButtonConfiguration plainButtonConfiguration]; cfg.title=titles[i]; cfg.image=[UIImage systemImageNamed:icons[i]]; cfg.imagePlacement=NSDirectionalRectEdgeTop; cfg.imagePadding=3; cfg.cornerStyle=UIButtonConfigurationCornerStyleCapsule; cfg.contentInsets=NSDirectionalEdgeInsetsMake(6,3,6,3); cfg.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium]; cfg.baseForegroundColor=(i==0?HostOnAccent():HostMutedText()); cfg.background.backgroundColor=i==0?HostAccent():UIColor.clearColor; cfg.titleTextAttributesTransformer=^(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];return result;}; b.configuration=cfg;
        b.accessibilityLabel=titles[i]; b.accessibilityIdentifier=[NSString stringWithFormat:@"tab.%@",titles[i]];
        b.accessibilityHint=[NSString stringWithFormat:@"切换到%@页面",titles[i]];
        b.accessibilityTraits=UIAccessibilityTraitButton|(i==0?UIAccessibilityTraitSelected:0);b.accessibilityValue=i==0?@"已选中":@"未选中";
        [b addTarget:self action:@selector(bottomTabTapped:) forControlEvents:UIControlEventTouchUpInside]; [self.bottomBar addArrangedSubview:b];
    }
    [self.view addSubview:self.bottomBar];
    __weak typeof(self) weakSelf=self;
    self.resourceActionsButton=[UIButton buttonWithType:UIButtonTypeSystem];self.resourceActionsButton.accessibilityIdentifier=@"resource-floating-actions";self.resourceActionsButton.accessibilityLabel=@"脚本与服务及资源操作";
    UIButtonConfiguration *resourceButtonConfig=[UIButtonConfiguration plainButtonConfiguration];resourceButtonConfig.image=[UIImage systemImageNamed:@"slider.horizontal.3"];resourceButtonConfig.baseForegroundColor=HostText();resourceButtonConfig.background.backgroundColor=HostRaisedSurface();resourceButtonConfig.background.strokeColor=HostBorder();resourceButtonConfig.background.strokeWidth=.7;resourceButtonConfig.background.cornerRadius=29;resourceButtonConfig.contentInsets=NSDirectionalEdgeInsetsMake(12,12,12,12);self.resourceActionsButton.configuration=resourceButtonConfig;self.resourceActionsButton.hidden=YES;HostInstallPressFeedback(self.resourceActionsButton);
    UIAction *services=[UIAction actionWithTitle:@"脚本与服务" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){[weakSelf openServicesPage];}];
    UIAction *import=[UIAction actionWithTitle:@"添加资源" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *a){[weakSelf addSubscription];}];
    UIAction *refresh=[UIAction actionWithTitle:@"刷新资源" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){[(ConfigCenterViewController *)weakSelf.tabPages[@3] refreshProfiles];}];
    UIAction *home=[UIAction actionWithTitle:@"刷新当前媒体内容" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){ConfigCenterViewController *page=(ConfigCenterViewController *)weakSelf.tabPages[@3];if(page.onRefreshMediaHome)page.onRefreshMediaHome();}];
    self.resourceActionsButton.menu=[UIMenu menuWithChildren:@[services,import,refresh,home]];self.resourceActionsButton.showsMenuAsPrimaryAction=NO;[self.resourceActionsButton addTarget:self action:@selector(openServicesPage) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.resourceActionsButton];

    UIVisualEffectView *catalogControls=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];
    catalogControls.accessibilityIdentifier=@"channel.catalog.floating-controls";catalogControls.layer.cornerRadius=27;catalogControls.clipsToBounds=YES;catalogControls.layer.borderWidth=0.7;catalogControls.layer.borderColor=HostBorder().CGColor;
    UIView *catalogTint=[[UIView alloc] initWithFrame:catalogControls.contentView.bounds];catalogTint.backgroundColor=HostGlassTint();catalogTint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;catalogTint.userInteractionEnabled=NO;[catalogControls.contentView addSubview:catalogTint];
    self.catalogFloatingControls=catalogControls;
    self.catalogLayoutButton=[UIButton buttonWithType:UIButtonTypeSystem];self.catalogLayoutButton.accessibilityIdentifier=@"channel.catalog.layout.toggle";self.catalogLayoutButton.accessibilityLabel=self.gridMode?@"切换列表布局":@"切换网格布局";
    UIButtonConfiguration *layoutConfig=[UIButtonConfiguration plainButtonConfiguration];layoutConfig.image=[UIImage systemImageNamed:self.gridMode?@"list.bullet":@"square.grid.2x2"];layoutConfig.baseForegroundColor=HostText();layoutConfig.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];layoutConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);self.catalogLayoutButton.configuration=layoutConfig;HostInstallPressFeedback(self.catalogLayoutButton);[self.catalogLayoutButton addTarget:self action:@selector(toggleCatalogLayout) forControlEvents:UIControlEventTouchUpInside];
    self.catalogFloatingAirPlayPicker=[AVRoutePickerView new];self.catalogFloatingAirPlayPicker.tintColor=HostText();self.catalogFloatingAirPlayPicker.activeTintColor=HostAccent();self.catalogFloatingAirPlayPicker.prioritizesVideoDevices=YES;self.catalogFloatingAirPlayPicker.accessibilityIdentifier=@"channel.catalog.airplay";self.catalogFloatingAirPlayPicker.accessibilityLabel=@"投屏到 AirPlay 设备";
    self.catalogMoreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.catalogMoreButton.accessibilityIdentifier=@"channel.catalog.more";self.catalogMoreButton.accessibilityLabel=@"频道页面操作";
    UIButtonConfiguration *moreConfig=[UIButtonConfiguration plainButtonConfiguration];moreConfig.image=[UIImage systemImageNamed:@"ellipsis"];moreConfig.baseForegroundColor=HostText();moreConfig.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];moreConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);self.catalogMoreButton.configuration=moreConfig;self.catalogMoreButton.menu=[self catalogMenu];self.catalogMoreButton.showsMenuAsPrimaryAction=YES;HostInstallPressFeedback(self.catalogMoreButton);
    [catalogControls.contentView addSubview:self.catalogLayoutButton];[catalogControls.contentView addSubview:self.catalogFloatingAirPlayPicker];[catalogControls.contentView addSubview:self.catalogMoreButton];
    [self.view addSubview:catalogControls];
    [self updateBottomBarSelection];
}

- (void)bottomTabTapped:(UIButton *)sender {
    self.userInitiatedTabSelection=YES;
    [self selectBottomTab:sender];
    self.userInitiatedTabSelection=NO;
}

- (void)suspendLivePlaybackForReason:(NSString *)reason {
    BOOL hasLivePlayback=self.currentPlayer!=nil||self.avPlayer!=nil||self.cicadaPlayer!=nil||self.playbackReadiness!=nil||self.remotePlaybackWanted;
    BOOL hasActivePlayback=hasLivePlayback||self.moviePlayer!=nil;
    if(!hasActivePlayback)return;
    NSString *engine=self.avPlayer?@"avplayer":(self.cicadaPlayer?@"cicada":(self.currentPlayer?@"cnplayersdk":(self.moviePlayer?@"avplayer_controller":@"pending")));
    self.playbackGeneration++;
    self.livePlaybackSuspendedForNavigation=hasLivePlayback;
    NSString *previousOwner=hasLivePlayback?@"live":@"vod";
    [RuntimeDiagnostics.shared recordEvent:hasLivePlayback?@"live_playback_suspended":@"playback_owner_released" category:@"playback" fields:@{@"reason":reason?:@"navigation",@"previous_owner":previousOwner,@"next_owner":@"none",@"engine":engine,@"previous_tab":@(self.activeTab),@"playback_generation":@(self.playbackGeneration),@"correlation_id":self.currentPlaybackTraceID?:@"",@"background_live_exception":@NO}];
    [self log:hasLivePlayback?@"离开直播页面，已暂停直播播放（%@）":@"已停止上一段视频播放（%@）",reason?:@"navigation"];
    [self stopPlayback];
    if(!hasLivePlayback)return;
    [self.spinner stopAnimating];
    self.titleLabel.hidden=NO;
    self.titleLabel.text=@"直播已暂停 · 返回后点继续播放";
    self.infoLabel.hidden=NO;
    self.infoLabel.text=@"直播与点播不会同时播放";
    self.playPauseBtn.enabled=YES;
    [self.playPauseBtn setTitle:@"继续播放" forState:UIControlStateNormal];
    self.liveMiniPlayerLabel.text=[NSString stringWithFormat:@"直播已挂起 · %@",self.channelName.length?self.channelName:@"当前频道"];
    self.liveMiniPlayerBar.hidden=NO;
}

- (void)resumeSuspendedLiveFromMiniBar {
    self.liveMiniPlayerBar.hidden=YES;
    NSInteger targetTab=self.currentRemoteURL.length?1:0;
    if(targetTab<self.bottomBar.arrangedSubviews.count)[self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews[targetTab]];
    self.playerExpanded=YES;[self configureCatalogNavigation];[self.view setNeedsLayout];
    if(self.livePlaybackSuspendedForNavigation)[self togglePlayPause];
}

- (void)dismissSuspendedLiveMiniBar {
    self.livePlaybackSuspendedForNavigation=NO;
    self.liveMiniPlayerBar.hidden=YES;
}

- (void)configureLiveSleepTimerMinutes:(NSInteger)minutes {
    [self.liveSleepTimer invalidate];self.liveSleepTimer=nil;self.liveSleepMinutes=minutes;
    if(minutes<=0){[self log:@"已关闭直播睡眠定时"];return;}
    __weak typeof(self) weakSelf=self;
    self.liveSleepTimer=[NSTimer scheduledTimerWithTimeInterval:minutes*60.0 repeats:NO block:^(__unused NSTimer *timer){
        RootViewController *owner=weakSelf;if(!owner)return;owner.liveSleepTimer=nil;owner.liveSleepMinutes=0;
        [owner suspendLivePlaybackForReason:@"sleep_timer_expired"];
        owner.titleLabel.hidden=NO;owner.titleLabel.text=@"已按睡眠定时暂停直播";
    }];
    [self log:@"已开启直播睡眠定时：%ld 分钟",(long)minutes];
}

- (void)updateBottomBarSelection {
    for (UIButton *button in self.bottomBar.arrangedSubviews) {
        UIButtonConfiguration *configuration=button.configuration;
        BOOL selected=button.tag==self.activeTab;
        configuration.baseForegroundColor=selected?HostOnAccent():HostMutedText();
        configuration.background.backgroundColor=selected?HostAccent():UIColor.clearColor;
        configuration.background.strokeColor=selected?[HostAccent() colorWithAlphaComponent:0.35]:UIColor.clearColor;
        configuration.background.strokeWidth=selected?0.5:0;
        button.configuration=configuration;
        button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);
        button.accessibilityValue=selected?@"已选中":@"未选中";
    }
}

- (void)selectBottomTab:(UIButton *)sender {
    self.catalogSearchGeneration++;
    [self stopPreview];
    if(self.activeTab!=sender.tag&&self.activeTab<2&&sender.tag>=2)[self suspendLivePlaybackForReason:@"left_live_interface"];
    if(!self.restoringLastTab&&self.activeTab<2){NSDictionary *state=@{@"query":self.query?:@"",@"group":@(self.groupControl.selectedSegmentIndex),@"gridY":@(self.channelGrid.contentOffset.y),@"listY":@(self.table.contentOffset.y),@"immersiveTopVersion":@1};self.catalogStates[@(self.activeTab)]=state;[[NSUserDefaults standardUserDefaults] setObject:state forKey:[NSString stringWithFormat:@"cctv.catalogState.%ld",(long)self.activeTab]];}
    if(self.restoringLastTab)[RuntimeDiagnostics.shared recordEvent:@"ui_session_tab_restored" category:@"lifecycle" fields:@{@"tab_index":@(sender.tag),@"automatic_content_load":@NO}];
    self.activeTab=sender.tag;
    // Unify 2026 Spatial Glass theme across all 5 tabs.
    self.navigationController.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(sender.tag<2)self.liveMiniPlayerBar.hidden=YES;
    [[NSUserDefaults standardUserDefaults] setInteger:self.activeTab forKey:@"cctv.lastBottomTab.v1"];
    [self updateBottomBarSelection];
    if([self.tabPage isKindOfClass:MediaBrowserViewController.class])[(MediaBrowserViewController *)self.tabPage saveSessionState];
    if(self.tabPage){[self.tabPage willMoveToParentViewController:nil];[self.tabPage.view removeFromSuperview];[self.tabPage removeFromParentViewController];self.tabPage=nil;}
    if(sender.tag==2){ [self openMediaTab]; }
    else if(sender.tag==3){ [self openConfigurationTab]; }
    else if(sender.tag==4){ SettingsViewController *page=(SettingsViewController *)self.tabPages[@4];if(!page){page=[self makeSettingsPage];self.tabPages[@4]=page;}[self showTabPage:page title:@"设置"]; }
    else {self.favoritesOnly=NO;self.recentsOnly=NO;if(sender.tag<2)self.subscriptionCatalog=sender.tag==1;[self syncGroupControlSegments];self.activeSource=nil;self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];NSDictionary *state=self.catalogStates[@(sender.tag)];self.query=state[@"query"]?:@"";self.searchController.searchBar.text=self.query;NSInteger savedGroup=[state[@"group"] integerValue];self.groupControl.selectedSegmentIndex=(savedGroup>=0&&savedGroup<self.groupControl.numberOfSegments)?savedGroup:0;NSArray<NSString *> *titles=[self currentCatalogGroupTitles];NSString *segTitle=(self.groupControl.selectedSegmentIndex>=0&&self.groupControl.selectedSegmentIndex<(NSInteger)titles.count)?titles[self.groupControl.selectedSegmentIndex]:@"全部";self.favoritesOnly=[segTitle isEqualToString:@"收藏"];self.recentsOnly=[segTitle isEqualToString:@"最近"];[self configureCatalogNavigation];[self applyFilter];[self.view layoutIfNeeded];BOOL oldTopGeometry=[state[@"immersiveTopVersion"] integerValue]<1;CGFloat topInset=self.channelGrid.contentInset.top;CGFloat gridY=[state[@"gridY"] doubleValue],listY=[state[@"listY"] doubleValue];if(!state){gridY=-topInset;listY=-self.table.contentInset.top;}else if(oldTopGeometry){gridY-=topInset;listY-=self.table.contentInset.top;}self.channelGrid.contentOffset=CGPointMake(0,MAX(-topInset,gridY));self.table.contentOffset=CGPointMake(0,MAX(-self.table.contentInset.top,listY));
        if(sender.tag==1&&!self.channelID.length&&self.userInitiatedTabSelection&&!self.restoringLastTab)[self refreshSubscriptionsWhenIdle];}
    [self.view setNeedsLayout];
}

- (void)configureCatalogNavigation {
    [self syncGroupControlSegments];
    BOOL expandedLive=[self isExpandedLivePlayerVisible];
    self.title=expandedLive?(self.channelName?:@"直播"):(self.recentsOnly?@"最近观看":(self.favoritesOnly?@"收藏频道":(self.subscriptionCatalog?@"频道":@"CCTV")));
    self.navigationItem.largeTitleDisplayMode=expandedLive?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.searchController=self.searchController; self.navigationItem.hidesSearchBarWhenScrolling=NO;
    // Keep the live pages' transport and catalog controls independent of the
    // navigation bar so they remain visible when the top chrome collapses.
    self.navigationItem.leftBarButtonItem=nil;self.navigationItem.rightBarButtonItems=nil;
    BOOL hideNavigation=self.fullscreen||expandedLive;
    if(self.navigationController.topViewController==self){
        self.navigationController.navigationBar.prefersLargeTitles=!hideNavigation;
        if(self.navigationController.navigationBarHidden!=hideNavigation)
            [self.navigationController setNavigationBarHidden:hideNavigation animated:NO];
    }
    [self setNeedsStatusBarAppearanceUpdate];
    [self updateLiveResourceCapsule];
    if(self.catalogLayoutButton){self.catalogLayoutButton.accessibilityLabel=self.gridMode?@"切换列表布局":@"切换网格布局";UIButtonConfiguration *configuration=self.catalogLayoutButton.configuration;configuration.image=[UIImage systemImageNamed:self.gridMode?@"list.bullet":@"square.grid.2x2"];self.catalogLayoutButton.configuration=configuration;}
    self.catalogMoreButton.menu=[self catalogMenu];
    // Page actions live in the floating catalog controls (layout, AirPlay,
    // more menu) and never in the navigation bar — the bar items were
    // cleared above and stay cleared (ui-preview: 'CCTV catalog keeps page
    // actions out of the top navigation bar').
}
- (void)toggleCatalogLayout {
    CGPoint listOffset=self.table.contentOffset,gridOffset=self.channelGrid.contentOffset;
    self.gridMode=!self.gridMode;
    [NSUserDefaults.standardUserDefaults setBool:self.gridMode forKey:@"channelGridMode"];
    [self configureCatalogNavigation];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    self.table.contentOffset=listOffset;
    self.channelGrid.contentOffset=gridOffset;
}
- (void)toggleCatalogColumns {
    CGPoint gridOffset=self.channelGrid.contentOffset;
    self.gridColumns=self.gridColumns==4?3:4;
    [NSUserDefaults.standardUserDefaults setInteger:self.gridColumns forKey:@"cctv.channelGridColumns.v1"];
    [self.channelGrid.collectionViewLayout invalidateLayout];
    [self.channelGrid reloadData];
    [self configureCatalogNavigation];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    self.channelGrid.contentOffset=gridOffset;
}
- (void)toggleCurrentFavorite {
    if(!self.channelID.length)return;
    if([self.favorites containsObject:self.channelID])[self.favorites removeObject:self.channelID];
    else [self.favorites addObject:self.channelID];
    [NSUserDefaults.standardUserDefaults setObject:self.favorites forKey:@"favorites"];
    [self configureCatalogNavigation];[self applyFilter];
}
- (void)playAdjacentChannel:(NSInteger)direction {
    // 上 / 下一个频道：在当前可见列表内循环换台（到头绕回另一端），
    // 未选台时从第一条开始；列表为空时不操作。
    if(!self.shownChannels.count)return;
    NSInteger current=[self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *c,NSUInteger idx,BOOL *stop){return [c[@"id"] isEqualToString:self.channelID];}];
    NSInteger next=current==NSNotFound?0:(current+direction+(NSInteger)self.shownChannels.count)%(NSInteger)self.shownChannels.count;
    if(next<0||next>=(NSInteger)self.shownChannels.count)return;
    [self selectChannel:self.shownChannels[next]];
}
- (void)scrollCatalogToPlayingChannel {
    // 回到正在播放：把列表滚到当前频道所在行；未选台或频道不在当前列表时不操作。
    if(!self.channelID.length)return;
    NSIndexPath *ip=[self indexPathForChannelID:self.channelID];
    if(!ip)return;
    if(!self.gridMode&&self.table&&!self.table.hidden)[self.table scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    else if(self.gridMode&&self.channelGrid&&!self.channelGrid.hidden){NSInteger gridIndex=[self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *c,NSUInteger idx,BOOL *stop){return [c[@"id"] isEqualToString:self.channelID];}];if(gridIndex!=NSNotFound)[self.channelGrid scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:gridIndex inSection:0] atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:YES];}
}
- (UIMenu *)catalogMenu {
    __weak typeof(self) w=self;
    NSInteger groupIndex=self.groupControl.selectedSegmentIndex;NSString *groupName=groupIndex>=0&&groupIndex<self.groupControl.numberOfSegments?[self.groupControl titleForSegmentAtIndex:groupIndex]:@"全部";
    UIAction *search=[UIAction actionWithTitle:@"搜索频道" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:@"channel.catalog.search" handler:^(UIAction *a){[w showCatalogSearch];}];
    UIAction *group=[UIAction actionWithTitle:[NSString stringWithFormat:@"频道分组 · %@",groupName] image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(UIAction *a){[w showGroupMenu];}];
    NSInteger nextColumns=self.gridColumns==4?3:4;
    UIAction *columns=[UIAction actionWithTitle:[NSString stringWithFormat:@"每行 %ld 列 · 切换为 %ld 列",(long)self.gridColumns,(long)nextColumns] image:[UIImage systemImageNamed:@"square.grid.3x3"] identifier:@"channel.grid.columns.toggle" handler:^(UIAction *a){[w toggleCatalogColumns];}];
    UIAction *refresh=[UIAction actionWithTitle:self.subscriptionCatalog?@"刷新播放列表":@"刷新当前列表" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){[w onPullRefresh];}];
    UIAction *add=[UIAction actionWithTitle:@"添加订阅" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *a){[w addSubscription];}];
    UIAction *hide=[UIAction actionWithTitle:self.playerExpanded?@"收起播放器":@"展开播放器" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a){w.playerExpanded=!w.playerExpanded;[w configureCatalogNavigation];[w.view setNeedsLayout];}];
    UIAction *history=[UIAction actionWithTitle:@"最近观看" image:[UIImage systemImageNamed:@"clock"] identifier:nil handler:^(UIAction *a){[w showHistory];}];
    UIAction *playing=[UIAction actionWithTitle:@"返回正在播放" image:[UIImage systemImageNamed:@"play.circle"] identifier:nil handler:^(UIAction *a){if(!w.channelID.length)return;[w selectBottomTab:(id)w.bottomBar.arrangedSubviews[w.currentRemoteURL.length?1:0]];w.playerExpanded=YES;[w configureCatalogNavigation];[w.view setNeedsLayout];dispatch_async(dispatch_get_main_queue(),^{[w scrollCatalogToPlayingChannel];});}];
    UIAction *manage=[UIAction actionWithTitle:@"整理收藏" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){[w showFavoriteManager];}];
    UIAction *favorites=[UIAction actionWithTitle:self.favoritesOnly?@"显示全部频道":@"查看收藏频道" image:[UIImage systemImageNamed:@"heart.fill"] identifier:nil handler:^(UIAction *a){w.recentsOnly=NO;w.favoritesOnly=!w.favoritesOnly;w.groupControl.selectedSegmentIndex=w.favoritesOnly?5:0;[w configureCatalogNavigation];[w applyFilter];}];
    UIAction *castCenter=[UIAction actionWithTitle:@"投屏中心 · AirPlay / 电视投屏" image:[UIImage systemImageNamed:@"airplayvideo"] identifier:@"channel.catalog.cast.center" handler:^(UIAction *a){[w showCastingCenter];}];
    UIAction *sort=[UIAction actionWithTitle:self.channelSortMode==1?@"按默认顺序排列":@"按名称排序" image:[UIImage systemImageNamed:@"arrow.up.arrow.down"] identifier:nil handler:^(UIAction *a){w.channelSortMode=w.channelSortMode==1?0:1;[NSUserDefaults.standardUserDefaults setInteger:w.channelSortMode forKey:@"cctv.channelSortMode.v1"];[w applyFilter];}];
    NSMutableArray *actions=[NSMutableArray arrayWithObjects:search,group,columns,castCenter,refresh,hide,playing,history,favorites,manage,sort,nil];
    if(self.recentsOnly&&self.recents.count){UIAction *clearRecents=[UIAction actionWithTitle:@"清空最近观看记录" image:[UIImage systemImageNamed:@"trash"] identifier:@"channel.catalog.recents.clear" handler:^(UIAction *a){[w.recents removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"recents"];[w applyFilter];}];clearRecents.attributes=UIMenuElementAttributesDestructive;[actions insertObject:clearRecents atIndex:0];}
    if(self.subscriptionCatalog)[actions insertObject:add atIndex:2];
    if(self.channelID.length){BOOL favorite=[self.favorites containsObject:self.channelID];UIAction *currentFavorite=[UIAction actionWithTitle:favorite?@"取消收藏当前频道":@"收藏当前频道" image:[UIImage systemImageNamed:favorite?@"heart.fill":@"heart"] identifier:nil handler:^(UIAction *a){[w toggleCurrentFavorite];}];UIAction *playbackInfo=[UIAction actionWithTitle:@"播放信息" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a){[w showPlaybackInfo];}];[actions insertObjects:@[currentFavorite,playbackInfo] atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0,2)]];}
    return [UIMenu menuWithTitle:@"" children:actions];
}
- (void)showCatalogSearch {
    NSString *message=self.subscriptionCatalog?@"按频道名称或编号筛选订阅频道。":@"按频道名称或编号筛选 CCTV。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"搜索频道" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=self.query?:@"";field.placeholder=@"频道名称或编号";field.clearButtonMode=UITextFieldViewModeWhileEditing;field.returnKeyType=UIReturnKeySearch;}];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"搜索" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(!owner)return;owner.query=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";owner.searchController.searchBar.text=owner.query;[owner applyFilter];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showGroupMenu {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"频道分组" message:@"按频道类型筛选当前列表" preferredStyle:UIAlertControllerStyleActionSheet];NSInteger selected=self.groupControl.selectedSegmentIndex;
    for(NSUInteger i=0;i<self.groupControl.numberOfSegments;i++){NSString *group=[self.groupControl titleForSegmentAtIndex:i]?:@"全部";NSString *title=(NSInteger)i==selected?[NSString stringWithFormat:@"✓  %@",group]:group;[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.groupControl.selectedSegmentIndex=i;[self onGroupChanged];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];UIPopoverPresentationController *popover=a.popoverPresentationController;if(popover){if(self.catalogMoreButton){popover.sourceView=self.catalogMoreButton;popover.sourceRect=self.catalogMoreButton.bounds;}else{popover.sourceView=self.view;popover.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);}}[self presentViewController:a animated:YES completion:nil];
}
- (void)showTabPage:(UIViewController *)page title:(NSString *)title {
    BOOL media=[page isKindOfClass:MediaBrowserViewController.class];BOOL resource=[page isKindOfClass:ConfigCenterViewController.class];BOOL hideNavigation=media||resource;self.navigationItem.largeTitleDisplayMode=hideNavigation?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    if(self.navigationController.topViewController==self){
        self.navigationController.navigationBar.prefersLargeTitles=!hideNavigation;
        if(self.navigationController.navigationBarHidden!=hideNavigation)[self.navigationController setNavigationBarHidden:hideNavigation animated:NO];
    }
    CGFloat stableTop=HostStatusBarSafeTop(self.view,self.view.safeAreaInsets.top);
    if(resource)[(ConfigCenterViewController *)page setTopSafeAreaInset:stableTop];
    else if(media)[(MediaBrowserViewController *)page setTopSafeAreaInset:stableTop];
    page.view.frame=self.view.bounds;
    self.tabPage=page;if(page.parentViewController!=self){[self addChildViewController:page];[self.view addSubview:page.view];[page didMoveToParentViewController:self];}else if(page.view.superview!=self.view)[self.view addSubview:page.view];self.title=(media||resource)?@"":title;self.navigationItem.searchController=(media||resource)?nil:page.navigationItem.searchController;self.navigationItem.leftBarButtonItem=nil;
    self.navigationItem.rightBarButtonItems=(media||resource)?nil:page.navigationItem.rightBarButtonItems;self.resourceActionsButton.hidden=YES;[self.view bringSubviewToFront:self.bottomBarBackdrop];[self.view bringSubviewToFront:self.bottomBar];
}
- (MediaBrowserViewController *)mediaPageCreatingIfNeeded {
    MediaBrowserViewController *page=(MediaBrowserViewController *)self.tabPages[@2];
    if(!page){page=[MediaBrowserViewController new];__weak typeof(self) weakSelf=self;
        page.sourcesProvider=^{
            NSMutableArray *sources=[NSMutableArray array];
            for(NSDictionary *service in [ServiceStore services])if([ServiceStore isVODMediaService:service])[sources addObject:service];
            NSArray *storedFallbackKeys=[[NSUserDefaults standardUserDefaults] arrayForKey:@"cctv.nativeFallbackSiteKeys.v1"]?:@[];
            NSMutableArray *cleanedFallbackKeys=[NSMutableArray array];
            for(id k in storedFallbackKeys){if([k isKindOfClass:NSString.class]&&![(NSString *)k hasPrefix:@"joeshu."])[cleanedFallbackKeys addObject:k];}
            if(cleanedFallbackKeys.count!=storedFallbackKeys.count)[[NSUserDefaults standardUserDefaults] setObject:cleanedFallbackKeys.copy forKey:@"cctv.nativeFallbackSiteKeys.v1"];
            NSSet *fallbackSiteKeys=[NSSet setWithArray:cleanedFallbackKeys];
            for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){
                NSString *catalogID=catalog[@"id"]?:@"";
                NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];
                for(NSDictionary *site in sites){
                    NSString *apiKind=[site[@"apiKind"] isKindOfClass:NSString.class]?site[@"apiKind"]:@"";
                    NSString *siteKey=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"";
                    NSString *rawAPI=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
                    NSString *lowAPI=rawAPI.lowercaseString;
                    BOOL isForADM=[siteKey hasPrefix:@"joeshu."]||[lowAPI containsString:@"raw.githubusercontent.com/joeshu/for-adm/"];
                    BOOL isDrpyRunner=[lowAPI containsString:@"drpy2.min.js"]||[lowAPI containsString:@"3e7e0c8a023b624cec6bdcc200f06f02.js"];
                    BOOL useNativeFallback=(!isForADM&&[apiKind isEqual:@"script"]&&(isDrpyRunner||[fallbackSiteKeys containsObject:siteKey]));
                    if(useNativeFallback)apiKind=@"jar-bridge";
                    if(!([apiKind isEqual:@"tvbox-api"]||[apiKind isEqual:@"maccms-api"]||[apiKind isEqual:@"douban-index"]||[apiKind isEqual:@"jar-bridge"])||![site[@"supported"] boolValue])continue;
                    NSString *protocol=apiKind,*siteID=[NSString stringWithFormat:@"%@:%@:%@",protocol,catalogID,siteKey];
                    NSString *type=site[@"type"]?:@"1";
                    NSString *effectiveAPI=useNativeFallback?@"csp_AppRJ":(site[@"api"]?:@"");
                    NSString *engine=[apiKind isEqual:@"maccms-api"]?@"MacCMS JSON/XML API":([apiKind isEqual:@"douban-index"]?@"豆瓣影视索引 · 原生适配":([apiKind isEqual:@"jar-bridge"]?@"Android/JAR 适配引擎 · iOS 原生执行":[NSString stringWithFormat:@"TVBox type %@ JSON API",type]));
                    NSArray *capabilities=[apiKind isEqual:@"douban-index"]?@[@"home",@"category",@"search"]:@[@"home",@"category",@"search",@"detail",@"play"];
                    NSMutableDictionary *source=[@{@"id":siteID,@"name":site[@"name"]?:@"影视来源",@"engine":engine,@"protocol":protocol,@"tvboxType":@([type integerValue]),@"api":effectiveAPI,@"url":effectiveAPI,@"options":useNativeFallback?@"":(site[@"ext"]?:@""),@"header":site[@"header"]?:@{},@"playUrl":site[@"playUrl"]?:@"",@"status":site[@"status"]?:@"可直接访问",@"catalogID":catalogID,@"catalogName":catalog[@"name"]?:@"资源合集",@"capabilities":capabilities,@"tvboxSiteKey":siteKey,@"tvboxSiteKeys":siteKey.length?@[siteKey]:@[]} mutableCopy];
                    [sources addObject:source];
                }
            }
            return sources;
        };
        page.catalogsProvider=^{return [TVBoxCatalogStore catalogs];};
        page.onOpenTVBoxCatalog=^(NSString *identifier){RootViewController *owner=weakSelf;if(owner)[owner openTVBoxCatalog:identifier];};
        page.onImportCatalogSite=^(NSDictionary *site,NSString *identifier){RootViewController *owner=weakSelf;if(!owner)return;NSMutableDictionary *scoped=[site mutableCopy];scoped[@"tvboxCatalogID"]=identifier;[owner importTVBoxSite:scoped browseAfterImport:YES];};
        page.onSubscribeCatalogLive=^(NSDictionary *live,NSString *identifier){RootViewController *owner=weakSelf;if(owner)[owner subscribeLiveFromCatalog:live catalogID:identifier];};
        __weak MediaBrowserViewController *weakPage=page;page.onDisplayModeChanged=^(BOOL homeMode){(void)homeMode;RootViewController *owner=weakSelf;MediaBrowserViewController *mediaPage=weakPage;if(!owner||!mediaPage||owner.activeTab!=2||owner.tabPage!=mediaPage)return;owner.title=@"";owner.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;owner.navigationItem.searchController=nil;owner.navigationItem.leftBarButtonItem=nil;owner.navigationItem.rightBarButtonItems=nil;if(owner.navigationController.topViewController==owner&&!owner.navigationController.navigationBarHidden)[owner.navigationController setNavigationBarHidden:YES animated:YES];};
        page.onActivateService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf changeService:service enabled:YES completion:completion];};
        page.onRestartService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf restartMediaService:service completion:completion];};
        page.onPlaybackWillStart=^{RootViewController *owner=weakSelf;if(owner)[owner suspendLivePlaybackForReason:@"vod_playback_starting"];};
        page.startupErrorProvider=^NSError *{return PyHost.startupError;};
        page.startupErrorForService=^NSError *(NSDictionary *service){return [PyHost startupErrorForServiceIdentifier:service[@"id"]];};
        page.onResources=^{RootViewController *owner=weakSelf;if(owner)[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[3]];};
        page.onPlay=^(NSDictionary *result,NSDictionary *context){RootViewController *owner=weakSelf;if(!owner)return;MediaPlaybackViewController *player=[MediaPlaybackViewController new];player.onPlaybackWillStart=^{RootViewController *strongOwner=weakSelf;if(strongOwner)[strongOwner suspendLivePlaybackForReason:@"vod_playback_starting"];};player.result=result;player.context=context;[owner.navigationController pushViewController:player animated:YES];};
        page.onSubscribeLive=^(NSDictionary *service){RootViewController *owner=weakSelf;if(!owner)return;NSString *url=[ServiceStore subscriptionURLForService:service];if(!url.length)for(NSString *candidate in owner.subscriptionURLs){NSDictionary *provider=[owner localServiceForURL:[NSURL URLWithString:candidate]];if([provider[@"id"] isEqual:service[@"id"]]){url=candidate;break;}}if(!url.length){[owner openServiceEditorForService:service];return;}NSMutableDictionary *metadata=[@{@"managedServiceID":service[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:url][@"name"])[metadata addEntriesFromDictionary:@{@"name":service[@"name"]?:@"本机直播服务"}];[ProfileStore update:url values:metadata];if(![owner.subscriptionURLs containsObject:url]){[owner.subscriptionURLs addObject:url];[NSUserDefaults.standardUserDefaults setObject:owner.subscriptionURLs.allObjects forKey:@"subscriptions"];}[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[1]];owner.activeSource=url;owner.title=@"订阅直播";[owner fetchSubscription:url silent:NO];};
        self.tabPages[@2]=page;
    }
    return page;
}
- (void)openMediaTab {
    BOOL created=self.tabPages[@2]==nil;MediaBrowserViewController *page=[self mediaPageCreatingIfNeeded];
    [self showTabPage:page title:@""];
    if(page.onDisplayModeChanged)page.onDisplayModeChanged(page.isHomeMode);
    if(!created)[page refreshSources];
}
- (void)playerViewController:(AVPlayerViewController *)controller willEndFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(controller==self.movieController && !self.moviePiPActive)[self.moviePlayer pause];}];
}
- (void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController *)controller {if(controller==self.movieController)self.moviePiPActive=YES;}
- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController *)controller {if(controller==self.movieController){self.moviePiPActive=NO;if(!controller.presentingViewController)[self.moviePlayer pause];}}
- (void)openConfigurationTab {
    ConfigCenterViewController *page=(ConfigCenterViewController *)self.tabPages[@3];
    if(!page){page=[ConfigCenterViewController new];__weak typeof(self) w=self;
        page.profilesProvider=^{return [(id)w configurationProfiles];};page.onServices=^{[w openServicesPage];};page.onAdd=^{[w addSubscription];};page.importTaskSummaryProvider=^{return w.resourceImportWorkflow.taskSummary;};page.onRefresh=^{[w onPullRefresh];};page.onRefreshProfile=^(NSString *source){[w refreshSubscriptionForProfile:source];};page.onRecheckProfile=^(NSString *source){[w recheckProfileHealth:source];};page.onRematchEPGProfile=^(NSString *source){[w rematchEPGForProfile:source];};page.onRestartProfile=^(NSString *source){NSDictionary *service=[w resourceServiceForSource:source];if(!service)return;[w restartMediaService:service completion:^(NSError *error){if(error)[w showServiceError:error.localizedDescription];}];};page.onRefreshCatalogProfile=^(NSString *source){[w refreshTVBoxCatalogProfile:source];};
        page.onRefreshMediaHome=^{RootViewController *owner=w;if(!owner)return;[owner selectBottomTab:(UIButton *)owner.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser returnToHomeFromNavigation];dispatch_async(dispatch_get_main_queue(),^{if(![browser refreshHomeContentFromResourcePage])[owner showServiceError:@"没有可加载的影视资源。请先导入并启用一个影视来源。"] ;});};
        page.onToggleProfile=^(NSString *source,BOOL enabled){NSDictionary *service=[w resourceServiceForSource:source];if(service){[w toggleService:service enabled:enabled];return;}if(!source.length)[NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"nativeChannelsEnabled"];else{NSMutableArray *disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabled removeObject:source];if(!enabled)[disabled addObject:source];[NSUserDefaults.standardUserDefaults setObject:disabled forKey:@"disabledSubscriptions"];}[w applyFilter];[w updateLiveResourceCapsule];};
        page.onOpenResource=^(NSString *source){[w openPluginResource:source];};page.onOpenSubscription=^(NSString *source){[w openSubscriptionProfile:source editing:NO];};
        page.onUseResource=^(NSString *source,NSString *kind){NSDictionary *service=[w resourceServiceForSource:source];if(!service)return;if([kind isEqual:@"choose"]){UIAlertController *choice=[UIAlertController alertControllerWithTitle:service[@"name"]?:@"选择资源用途" message:@"这个资源同时提供影视与直播能力。" preferredStyle:UIAlertControllerStyleActionSheet];[choice addAction:[UIAlertAction actionWithTitle:@"进入影视" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[w usePluginService:service kind:@"vod"];}]];[choice addAction:[UIAlertAction actionWithTitle:@"添加直播频道" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[w usePluginService:service kind:@"live"];}]];[choice addAction:[UIAlertAction actionWithTitle:@"资源详情与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[w openPluginResource:source];}]];[choice addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];choice.popoverPresentationController.sourceView=w.view;choice.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(w.view.bounds),CGRectGetMidY(w.view.bounds),1,1);[w presentViewController:choice animated:YES completion:nil];return;}[w usePluginService:service kind:kind];};
        page.onOpenTVBoxCatalog=^(NSString *identifier){[w openTVBoxCatalog:identifier];};
        page.onExportResource=^(NSString *source,NSString *format){[w exportResource:source format:format];};
        page.onSelectProfile=^(NSString *source){UIButton *b=(UIButton *)w.bottomBar.arrangedSubviews[source.length?1:0];[w selectBottomTab:b];w.activeSource=source;w.title=source.length?@"订阅直播":@"央视直播";[w applyFilter];[w updateLiveResourceCapsule];};
        page.onEditProfile=^(NSString *source){NSDictionary *service=[w resourceServiceForSource:source];if(service)[w openServiceEditorForService:service];else[w editProfile:source];};
        page.onDeleteProfile=^(NSString *source){if([source hasPrefix:@"tvbox:"]){[TVBoxCatalogStore removeCatalog:[source substringFromIndex:6]];[w refreshConfigurationPage];return;}NSDictionary *service=[w resourceServiceForSource:source];if(service){if([PyHost isManagedServiceIdentifier:service[@"id"]]){[w showServiceError:@"该资源仍有运行或待清理会话，请先停止"];return;}[ServiceStore remove:service[@"id"]];}else[w deleteSubscription:source];};
        self.tabPages[@3]=page;
    }
    [self showTabPage:page title:@"资源"];
}
- (NSDictionary *)resourceServiceForSource:(NSString *)source {if(![source hasPrefix:@"plugin:"])return nil;NSString *identifier=[source substringFromIndex:7];for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:identifier])return service;return nil;}
- (NSArray *)configurationProfiles {
    NSMutableArray *rows=[NSMutableArray array];NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary dictionary];NSUInteger native=0;
    for(NSDictionary *channel in self.allChannels){if(![channel[@"remoteURL"] length])native++;for(NSString *source in [NSSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])])counts[source]=@([counts[source] unsignedIntegerValue]+1);}
    [rows addObject:@{@"name":@"央视直播 · 官方频道",@"source":@"",@"resourceKind":@"live",@"native":@YES,@"current":@(!self.activeSource.length),@"epgStatus":@"官方",@"count":@(native),@"enabled":@(CCTVBoolPreference(@"nativeChannelsEnabled",YES))}];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSString *selectedMedia=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"]?:@"";
    NSString *selectedMediaCatalog=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaCatalogID"]?:@"";
    NSMutableSet<NSString *> *catalogIDs=[NSMutableSet set];for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if([catalog[@"id"] isKindOfClass:NSString.class])[catalogIDs addObject:catalog[@"id"]];
    for(NSString *u in [ProfileStore orderedSources:self.subscriptionURLs.allObjects]){NSDictionary *metadata=[ProfileStore metadata:u];NSString *catalogID=[metadata[@"tvboxCatalogID"] isKindOfClass:NSString.class]?metadata[@"tvboxCatalogID"]:@"";if(catalogID.length&&[catalogIDs containsObject:catalogID])continue;NSMutableDictionary *row=[@{@"name":metadata[@"name"]?:[NSURL URLWithString:u].host?:@"本地播放列表",@"status":metadata[@"status"]?:@"等待刷新",@"resourceKind":@"live",@"current":@([self.activeSource isEqual:u]),@"epgStatus":(metadata[@"epgURL"]?:metadata[@"detectedEPGURL"])?@"已配置":@"自动匹配",@"source":u,@"count":counts[u]?:@0,@"enabled":@(![disabled containsObject:u])} mutableCopy];if(metadata[@"updatedAt"])row[@"updatedAt"]=metadata[@"updatedAt"];if(metadata[@"importSourceFilename"])row[@"sourceFilename"]=metadata[@"importSourceFilename"];if(metadata[@"importFingerprint"])row[@"fingerprint"]=metadata[@"importFingerprint"];[rows addObject:row];}
    for(NSDictionary *service in [ServiceStore services])if(![service[@"builtin"] boolValue]){
        NSString *catalogID=[service[@"tvboxCatalogID"] isKindOfClass:NSString.class]?service[@"tvboxCatalogID"]:@"";if(catalogID.length&&[catalogIDs containsObject:catalogID])continue;
        BOOL enabled=[PyHost isRunningServiceIdentifier:service[@"id"]];NSArray *caps=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:@[];
        NSString *subscriptionURL=[ServiceStore subscriptionURLForService:service]?:@"",*epgURL=[ServiceStore epgURLForService:service]?:@"";
        NSDictionary *playlistMetadata=subscriptionURL.length?[ProfileStore metadata:subscriptionURL]:@{};NSArray *cachedChannels=[playlistMetadata[@"cachedChannels"] isKindOfClass:NSArray.class]?playlistMetadata[@"cachedChannels"]:@[];
        NSString *kind=[ServiceStore resourceKindForService:service subscriptionURL:subscriptionURL];
        NSString *playlistStatus=[playlistMetadata[@"status"] isKindOfClass:NSString.class]?playlistMetadata[@"status"]:(subscriptionURL.length?(enabled?@"等待读取订阅清单":@"服务已停止 · 保留最近频道"):@"未配置播放列表");
        NSDictionary *health=[ServiceStore healthSnapshotForServiceIdentifier:service[@"id"]];NSMutableDictionary *profile=[@{@"name":service[@"name"]?:@"本机脚本",@"type":@"plugin",@"resourceKind":kind,@"capabilities":caps,@"engine":service[@"engine"]?:@"python",@"runtime":service[@"engine"]?:@"python",@"protocol":service[@"protocol"]?:@"未知协议",@"playlistPath":[ServiceStore playlistPathForService:service]?:@"",@"subscriptionURL":subscriptionURL,@"epgURL":epgURL,@"subscriptionStatus":playlistStatus,@"channelCount":@(cachedChannels.count),@"playlistUpdatedAt":playlistMetadata[@"updatedAt"]?:@0,@"updatedAt":service[@"updated"]?:@0,@"port":service[@"port"]?:@0,@"url":service[@"url"]?:@"",@"current":@([service[@"id"] isEqual:selectedMedia]),@"source":[@"plugin:" stringByAppendingString:service[@"id"]],@"status":[PyHost runtimeStatusDescriptionForServiceIdentifier:service[@"id"]],@"enabled":@(enabled)} mutableCopy];if(service[@"importSourceFilename"])profile[@"sourceFilename"]=service[@"importSourceFilename"];if(service[@"importFingerprint"])profile[@"fingerprint"]=service[@"importFingerprint"];if([health[@"result"] isKindOfClass:NSString.class])profile[@"healthResult"]=health[@"result"];if(health[@"checkedAt"])profile[@"healthCheckedAt"]=health[@"checkedAt"];if(health[@"httpStatus"])profile[@"healthHTTPStatus"]=health[@"httpStatus"];[rows addObject:profile];
    }
    for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){
        NSString *identifier=catalog[@"id"]?:@"";NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"";if(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])catalogName=@"资源合集";NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSUInteger supported=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])supported++;
        NSUInteger liveCount=[catalog[@"lives"] count];NSString *kind=supported&&liveCount?@"both":(supported?@"vod":(liveCount?@"live":@"unknown"));NSString *catalogKind=[catalog[@"catalogKind"] isKindOfClass:NSString.class]?catalog[@"catalogKind"]:@"tvbox";
        BOOL current=[selectedMediaCatalog isEqual:identifier]||[selectedMedia hasPrefix:[NSString stringWithFormat:@"tvbox-api:%@:",identifier]]||[selectedMedia hasPrefix:[NSString stringWithFormat:@"maccms-api:%@:",identifier]]||[selectedMedia hasPrefix:[NSString stringWithFormat:@"jar-bridge:%@:",identifier]];
        BOOL liveEnabled=NO;for(NSString *owner in self.subscriptionURLs){NSDictionary *ownerMetadata=[ProfileStore metadata:owner];if([ownerMetadata[@"tvboxCatalogID"] isEqual:identifier]&&![disabled containsObject:owner]&&[counts[owner] unsignedIntegerValue]){liveEnabled=YES;break;}}
        NSMutableDictionary *profile=[@{@"name":catalogName,@"type":@"tvbox",@"catalogKind":catalogKind,@"resourceKind":kind,@"source":[@"tvbox:" stringByAppendingString:identifier],@"url":catalog[@"url"]?:@"",@"updatedAt":catalog[@"updatedAt"]?:@0,@"siteCount":@(sites.count),@"supportedCount":@(supported),@"liveCount":@(liveCount),@"enabled":@(liveEnabled),@"current":@(current)} mutableCopy];if(catalog[@"importSourceFilename"])profile[@"sourceFilename"]=catalog[@"importSourceFilename"];if(catalog[@"importFingerprint"])profile[@"fingerprint"]=catalog[@"importFingerprint"];[rows addObject:profile];
    }
    NSArray *unifiedOrder=[NSUserDefaults.standardUserDefaults arrayForKey:@"resourceUnifiedOrder"];
    if([unifiedOrder isKindOfClass:NSArray.class]&&unifiedOrder.count){
        NSMutableDictionary<NSString *,NSNumber *> *orderMap=[NSMutableDictionary dictionaryWithCapacity:unifiedOrder.count];
        for(NSUInteger idx=0;idx<unifiedOrder.count;idx++){id key=unifiedOrder[idx];if([key isKindOfClass:NSString.class]&&!orderMap[key])orderMap[key]=@(idx);}
        [rows sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSString *ka=[a[@"source"] isKindOfClass:NSString.class]&&[a[@"source"] length]?a[@"source"]:([a[@"native"] boolValue]?@"__native_cctv__":@"");
            NSString *kb=[b[@"source"] isKindOfClass:NSString.class]&&[b[@"source"] length]?b[@"source"]:([b[@"native"] boolValue]?@"__native_cctv__":@"");
            NSNumber *ia=orderMap[ka],*ib=orderMap[kb];
            if(ia&&ib)return [ia compare:ib];
            if(ia)return NSOrderedAscending;
            if(ib)return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    return rows;
}
- (void)updateLiveResourceCapsule {
    UIButton *capsule=self.liveResourceCapsule;if(!capsule)return;
    BOOL visible=[self isExpandedLivePlayerVisible];capsule.hidden=!visible;
    if(!visible)return;
    NSString *title=self.activeTab==0?@"央视直播":@"全部直播资源";
    UIMenu *menu=nil;
    if(self.activeTab==1){
        __weak typeof(self) weakSelf=self;NSMutableArray<UIMenuElement *> *actions=[NSMutableArray array];
        BOOL allSelected=!self.activeSource.length;NSString *allTitle=allSelected?@"✓ 全部直播资源":@"全部直播资源";
        [actions addObject:[UIAction actionWithTitle:allTitle image:[UIImage systemImageNamed:allSelected?@"checkmark.circle.fill":@"dot.radiowaves.left.and.right"] identifier:@"live.resource.all" handler:^(UIAction *action){[weakSelf selectLiveResourceSource:nil];}]];
        NSString *selectedName=nil;
        for(NSDictionary *profile in [self configurationProfiles]){
            NSString *kind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"";
            if(!([kind isEqual:@"live"]||[kind isEqual:@"both"])||[profile[@"native"] boolValue]||(profile[@"enabled"]&&![profile[@"enabled"] boolValue]))continue;
            NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
            if(!source.length)continue;
            if([profile[@"type"] isEqual:@"tvbox"]&&![profile[@"liveCount"] unsignedIntegerValue])continue;
            if([profile[@"type"] isEqual:@"plugin"]&&![[profile[@"subscriptionURL"] description] length]&&![profile[@"channelCount"] unsignedIntegerValue])continue;
            NSString *name=[profile[@"name"] isKindOfClass:NSString.class]?profile[@"name"]:source;
            NSUInteger count=[profile[@"count"] unsignedIntegerValue];if(!count)count=[profile[@"channelCount"] unsignedIntegerValue];if(!count)count=[profile[@"liveCount"] unsignedIntegerValue];
            NSString *menuTitle=count?[NSString stringWithFormat:@"%@ · %lu",name,(unsigned long)count]:name;
            BOOL selected=[source isEqual:self.activeSource];if(selected){selectedName=name;menuTitle=[@"✓ " stringByAppendingString:menuTitle];}
            NSString *capturedSource=[source copy];
            [actions addObject:[UIAction actionWithTitle:menuTitle image:[UIImage systemImageNamed:selected?@"checkmark.circle.fill":@"dot.radiowaves.left.and.right"] identifier:nil handler:^(UIAction *action){[weakSelf selectLiveResourceSource:capturedSource];}]];
        }
        if(actions.count==1){UIAction *empty=[UIAction actionWithTitle:@"资源页暂无可选直播源" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *action){}];[actions addObject:empty];}
        if(selectedName.length)title=selectedName;
        title=[title stringByAppendingString:@"  ▾"];
        menu=[UIMenu menuWithTitle:@"选择直播资源" children:actions];
    }
    UIButtonConfiguration *configuration=[UIButtonConfiguration plainButtonConfiguration];configuration.title=title;configuration.image=[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"];configuration.imagePlacement=NSDirectionalRectEdgeLeading;configuration.imagePadding=7;configuration.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];configuration.baseForegroundColor=HostText();configuration.background.backgroundColor=HostGlassTint();configuration.background.strokeColor=HostBorder();configuration.background.strokeWidth=.7;configuration.background.cornerRadius=18;configuration.contentInsets=NSDirectionalEdgeInsetsMake(6,12,6,12);configuration.titleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes){NSMutableDictionary *result=[attributes mutableCopy];result[NSFontAttributeName]=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];return result;};capsule.configuration=configuration;capsule.menu=menu;capsule.showsMenuAsPrimaryAction=self.activeTab==1;capsule.accessibilityLabel=self.activeTab==1?([title stringByReplacingOccurrencesOfString:@"  ▾" withString:@""]):@"央视直播";capsule.accessibilityHint=self.activeTab==1?@"下拉切换资源页中的直播资源":@"当前为央视官方频道";
}
- (void)selectLiveResourceSource:(NSString *)source {
    self.activeSource=source.length?[source copy]:nil;self.favoritesOnly=NO;
    [self applyFilter];[self updateLiveResourceCapsule];
    CGFloat top=-self.channelGrid.contentInset.top;self.channelGrid.contentOffset=CGPointMake(0,top);self.table.contentOffset=CGPointMake(0,-self.table.contentInset.top);
    [self.view setNeedsLayout];
}
- (BOOL)subscriptionOwner:(NSString *)owner matchesLiveResourceSource:(NSString *)source {
    if(!source.length||[owner isEqual:source])return YES;
    NSDictionary *metadata=[ProfileStore metadata:owner]?:@{};
    if([source hasPrefix:@"tvbox:"]){
        NSString *catalogID=[source substringFromIndex:6];if([metadata[@"tvboxCatalogID"] isEqual:catalogID])return YES;
        NSDictionary *service=[self localServiceForURL:[NSURL URLWithString:owner]];return [service[@"tvboxCatalogID"] isEqual:catalogID];
    }
    if([source hasPrefix:@"plugin:"]){
        NSString *serviceID=[source substringFromIndex:7];if([metadata[@"managedServiceID"] isEqual:serviceID])return YES;
        NSDictionary *service=[self resourceServiceForSource:source];NSString *playlist=[ServiceStore subscriptionURLForService:service]?:@"";if(playlist.length&&[[self stableURLKey:playlist] isEqual:[self stableURLKey:owner]])return YES;
        NSDictionary *ownerService=[self localServiceForURL:[NSURL URLWithString:owner]];return [ownerService[@"id"] isEqual:serviceID];
    }
    return NO;
}
- (void)openPluginResource:(NSString *)source {
    if([source hasPrefix:@"tvbox:"]){[self openTVBoxCatalog:[source substringFromIndex:6]];return;}
    NSDictionary *service=[self resourceServiceForSource:source];if(!service)return;PluginResourceDetailViewController *page=[PluginResourceDetailViewController new];page.service=service;__weak typeof(self) weakSelf=self;
    page.onToggle=^(NSDictionary *item,BOOL enabled,void(^completion)(NSError *)){[weakSelf changeService:item enabled:enabled completion:completion];};
    page.onRestart=^(NSDictionary *item,void(^completion)(NSError *)){[weakSelf restartMediaService:item completion:completion];};
    page.onExport=^(NSDictionary *item){[weakSelf exportResource:[@"plugin:" stringByAppendingString:item[@"id"]?:@""] format:@"single"];};
    page.onPlaylistDiscovered=^(NSDictionary *item,NSString *url,NSUInteger channelCount){
        RootViewController *owner=weakSelf;if(!owner||![ProfileStore isHTTP:url])return;
        NSURLComponents *parts=[NSURLComponents componentsWithString:url];
        if(![parts.host.lowercaseString isEqual:@"127.0.0.1"]||parts.port.integerValue!=[item[@"port"] integerValue]||parts.query.length||parts.fragment.length)return;
        NSMutableDictionary *metadata=[@{@"managedServiceID":item[@"id"]?:@""} mutableCopy];
        if(![ProfileStore metadata:url][@"name"])metadata[@"name"]=item[@"name"]?:@"本机直播服务";
        [ProfileStore update:url values:metadata];
        if(!owner.subscriptionURLs)owner.subscriptionURLs=[NSMutableSet set];
        [owner.subscriptionURLs addObject:url];
        [NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:owner.subscriptionURLs.allObjects] forKey:@"subscriptions"];
        [NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:url];
        [owner logPluginLine:[NSString stringWithFormat:@"已验证节目单并加入订阅 · %@ · %lu 个频道",parts.path?:@"/",(unsigned long)channelCount] identifier:item[@"id"] name:item[@"name"]];
        [owner refreshConfigurationPage];
        [owner fetchSubscription:url silent:YES];
    };
    page.onUse=^(NSDictionary *item,NSString *kind){[weakSelf usePluginService:item kind:kind];};
    page.onLog=^(NSDictionary *item){[weakSelf openDiagnosticLogForIdentifier:item[@"id"] name:item[@"name"]];};page.onEdit=^(NSDictionary *item){[weakSelf openServiceEditorForService:item];};page.onRemove=^(NSDictionary *item){RootViewController *owner=weakSelf;if([PyHost isManagedServiceIdentifier:item[@"id"]]){[owner showServiceError:@"请先停止此资源服务，再移除代码和配置。"];return;}[ServiceStore remove:item[@"id"]];[owner.navigationController popViewControllerAnimated:YES];[owner refreshConfigurationPage];};
    page.onUpdate=^(NSDictionary *item){RootViewController *owner=weakSelf;[owner downloadPackageURL:[NSURL URLWithString:item[@"url"]] headers:item[@"importHeaders"] completion:^(NSDictionary *value,NSError *error){[weakSelf acceptImportedMedia:value error:error];}];};
    __weak PluginResourceDetailViewController *weakPage=page;
    page.onRollback=^(NSDictionary *item){RootViewController *owner=weakSelf;dispatch_block_t rollback=^{NSError *error=nil;NSDictionary *restored=[ServiceStore rollbackImportedService:item error:&error];if(!restored){[owner showServiceError:error.localizedDescription];return;}weakPage.service=restored;[weakPage.tableView reloadData];[owner refreshConfigurationPage];};if([PyHost isManagedServiceIdentifier:item[@"id"]])[owner changeService:item enabled:NO completion:^(NSError *error){if(error)[owner showServiceError:error.localizedDescription];else rollback();}];else rollback();};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)openServiceEditorForService:(NSDictionary *)service {
    ServiceEditorViewController *editor=[ServiceEditorViewController new];editor.service=service;__weak typeof(self) weakSelf=self;
    editor.onApplyService=^(NSDictionary *previous,NSDictionary *updated,void(^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner applyServiceConfigurationFrom:previous to:updated completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);};
    editor.onSave=^{[weakSelf refreshConfigurationPage];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
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
- (void)subscribeLiveFromCatalog:(NSDictionary *)live catalogID:(NSString *)identifier {
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];NSString *url=[self stableURLKey:live[@"url"]];
    if(!catalog||!url.length||![live[@"supported"] boolValue]){[self showServiceError:@"这条直播清单无法从该资源合集中加载"];return;}
    BOOL belongs=NO;for(NSDictionary *entry in [TVBoxCatalogStore liveSourcesInCatalog:catalog])if([[self stableURLKey:entry[@"url"]] isEqual:url]){belongs=YES;break;}
    if(!belongs){[self showServiceError:@"直播清单与所选资源合集不匹配"];return;}
    for(NSString *existingURL in self.subscriptionURLs.allObjects){if([existingURL isEqual:url])continue;NSDictionary *metadata=[ProfileStore metadata:existingURL];if([metadata[@"tvboxCatalogID"] isEqual:identifier])[self deleteSubscription:existingURL];}
    NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"直播合集";NSString *liveName=[live[@"name"] isKindOfClass:NSString.class]?live[@"name"]:@"直播列表";
    NSMutableDictionary *metadata=[@{@"name":[NSString stringWithFormat:@"%@ · %@",catalogName,liveName],@"tvboxCatalogID":identifier,@"tvboxLiveEntryName":liveName,@"userAgent":live[@"ua"]?:@""} mutableCopy];
    [ProfileStore update:url values:metadata];if(![self.subscriptionURLs containsObject:url])[self.subscriptionURLs addObject:url];
    [NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"selectedMediaCatalogID"];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaSource"];
    [NSUserDefaults.standardUserDefaults setObject:url forKey:[NSString stringWithFormat:@"tvboxLiveSelection.%@",identifier]];
    [self refreshConfigurationPage];if(self.navigationController.topViewController!=self)[self.navigationController popToViewController:self animated:NO];
    [self selectBottomTab:(id)self.bottomBar.arrangedSubviews[1]];self.activeSource=url;self.title=@"订阅直播";[self fetchSubscription:url silent:NO];
}
- (void)openTVBoxCatalog:(NSString *)identifier {
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    TVBoxCatalogViewController *page=[TVBoxCatalogViewController new];page.catalog=catalog;__weak typeof(self) weakSelf=self;
    page.serviceForSite=^NSDictionary *(NSDictionary *site){
        NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
        NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";
        NSDictionary *headers=[site[@"header"] isKindOfClass:NSDictionary.class]?site[@"header"]:@{};
        NSString *playURL=[site[@"playUrl"] isKindOfClass:NSString.class]?site[@"playUrl"]:@"";
        for(NSDictionary *service in [ServiceStore services]){
            NSString *serviceExt=[service[@"manifest"][@"options"] description]?:@"";
            NSDictionary *savedHeaders=service[@"tvboxSiteHeader"]?:service[@"importHeaders"]?:@{};
            NSString *savedPlayURL=[service[@"tvboxPlayURL"] isKindOfClass:NSString.class]?service[@"tvboxPlayURL"]:@"";
            if(api.length&&[service[@"url"] isEqual:api]&&[serviceExt isEqual:ext]&&[savedHeaders isEqual:headers]&&[savedPlayURL isEqual:playURL])return service;
        }
        return nil;
    };
    page.onUseImportedService=^(NSDictionary *service){RootViewController *owner=weakSelf;if(!owner)return;NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[owner usePluginService:service kind:kind];};
    page.onOpenImportedService=^(NSDictionary *service){RootViewController *owner=weakSelf;if(owner)[owner openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]?:@""]];};
    page.onImportSite=^(NSDictionary *site,BOOL browseAfterImport){NSMutableDictionary *scoped=[site mutableCopy];scoped[@"tvboxCatalogID"]=identifier;[weakSelf importTVBoxSite:scoped browseAfterImport:browseAfterImport];};
    __weak TVBoxCatalogViewController *weakPage=page;page.onImportCompatibleContents=^{[weakSelf bulkImportTVBoxCatalog:identifier page:weakPage];};
     page.onUseNativeSite=^(NSDictionary *site){RootViewController *owner=weakSelf;if(!owner)return;NSString *apiKind=site[@"apiKind"]?:@"",*protocol=[apiKind isEqual:@"maccms-api"]?@"maccms-api":([apiKind isEqual:@"douban-index"]?@"douban-index":([apiKind isEqual:@"jar-bridge"]?@"jar-bridge":@"tvbox-api"));NSString *sourceID=[NSString stringWithFormat:@"%@:%@:%@",protocol,catalog[@"id"]?:@"",site[@"key"]?:@""];[NSUserDefaults.standardUserDefaults setObject:sourceID forKey:@"selectedMediaSource"];[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[2]];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser openSourceIdentifier:sourceID];};
    page.onExportCatalog=^(NSString *format){RootViewController *owner=weakSelf;if(owner)[owner exportResource:[@"tvbox:" stringByAppendingString:identifier] format:[format isEqual:@"zip"]?@"catalog-zip":@"catalog-json"];};
    page.onExportSingleResource=^(NSDictionary *resource,NSString *kind,NSUInteger index){RootViewController *owner=weakSelf;if(!owner)return;NSString *scope=[@"tvbox:" stringByAppendingString:identifier];[owner exportCatalogSingleResource:scope resource:resource kind:kind index:index];};
    page.onSubscribeLive=^(NSDictionary *live){RootViewController *owner=weakSelf;if(owner)[owner subscribeLiveFromCatalog:live catalogID:identifier];};
    page.onRemove=^{RootViewController *owner=weakSelf;[TVBoxCatalogStore removeCatalog:identifier];[owner.navigationController popViewControllerAnimated:YES];[owner refreshConfigurationPage];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)bulkImportTVBoxCatalog:(NSString *)identifier page:(TVBoxCatalogViewController *)page {
    if(self.tvboxCatalogBulkImporter){[self showServiceError:@"这份合集的批量导入仍在进行中"];return;}
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];
    NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];
    NSMutableArray *pending=[NSMutableArray array];NSUInteger alreadyImported=0,nativeCount=0;
    NSArray *services=[ServiceStore services];
    for(NSDictionary *site in sites){
        if(![site[@"supported"] boolValue])continue;
        if([site[@"apiKind"] isEqual:@"tvbox-api"]||[site[@"apiKind"] isEqual:@"maccms-api"]||[site[@"apiKind"] isEqual:@"douban-index"]||[site[@"apiKind"] isEqual:@"jar-bridge"]){nativeCount++;continue;}
        if(![site[@"apiKind"] isEqual:@"script"])continue;
        NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"",*ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";
        BOOL exists=NO;
        for(NSDictionary *service in services){NSString *serviceExt=[service[@"manifest"][@"options"] description]?:@"";NSDictionary *siteHeaders=[site[@"header"] isKindOfClass:NSDictionary.class]?site[@"header"]:@{},*savedHeaders=service[@"tvboxSiteHeader"]?:service[@"importHeaders"]?:@{};NSString *playURL=[site[@"playUrl"] isKindOfClass:NSString.class]?site[@"playUrl"]:@"";if(api.length&&[service[@"url"] isEqual:api]&&[serviceExt isEqual:ext]&&[savedHeaders isEqual:siteHeaders]&&[(service[@"tvboxPlayURL"]?:@"") isEqual:playURL]){exists=YES;break;}}
        if(exists)alreadyImported++;else[pending addObject:site];
    }
    NSUInteger supportedLiveCount=0;for(NSDictionary *live in lives)if([live[@"supported"] boolValue])supportedLiveCount++;
     if(!pending.count){[self refreshConfigurationPage];[(MediaBrowserViewController *)self.tabPages[@2] refreshSources];if(page)[page.tableView reloadData];UIAlertController *done=[UIAlertController alertControllerWithTitle:@"合集内容已就绪" message:[NSString stringWithFormat:@"原生接口与索引：%lu 个可按需浏览\n已保存的脚本站点：%lu 个\n直播清单：%lu 个，仍留在合集内，按需选择后才加载",(unsigned long)nativeCount,(unsigned long)alreadyImported,(unsigned long)supportedLiveCount] preferredStyle:UIAlertControllerStyleAlert];[done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:done animated:YES completion:nil];return;}
    TVBoxCatalogBulkImporter *importer=[TVBoxCatalogBulkImporter new];self.tvboxCatalogBulkImporter=importer;
    NSUInteger total=pending.count;UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"正在整包导入影视站点" message:[NSString stringWithFormat:@"准备检查 %lu 个站点…\n%lu 个直播清单保留在合集内，不会整包订阅。导入不会启动脚本。",(unsigned long)total,(unsigned long)supportedLiveCount] preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf=self;__weak UIAlertController *weakProgress=progress;__weak TVBoxCatalogViewController *weakPage=page;
    [progress addAction:[UIAlertAction actionWithTitle:@"取消批量导入" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(owner.tvboxCatalogBulkImporter==importer)[importer cancel];weakProgress.message=@"正在停止当前下载并保留已完成项目…";}]];
    importer.onProgress=^(NSUInteger completed,NSUInteger totalCount,NSUInteger succeeded,NSUInteger failed,NSString *current){if(!weakProgress)return;if(importer.downloadLimitReached){weakProgress.message=@"累计下载达到 512 MiB 上限，正在停止并保存已完成项目…";return;}weakProgress.message=[NSString stringWithFormat:@"%lu / %lu · 已识别 %lu · 失败 %lu\n当前：%@\n导入不会执行脚本。",(unsigned long)completed,(unsigned long)totalCount,(unsigned long)succeeded,(unsigned long)failed,current?:@"准备中"];};
    [self presentViewController:progress animated:YES completion:^{
        [importer importSites:pending catalogID:identifier completion:^(NSArray<NSDictionary *> *imported,NSArray<NSDictionary *> *failures,BOOL cancelled){
            RootViewController *owner=weakSelf;if(!owner)return;owner.tvboxCatalogBulkImporter=nil;
            NSMutableSet *ports=[NSMutableSet set];for(NSDictionary *service in [ServiceStore services]){NSInteger port=[service[@"port"] integerValue];if(port>0)[ports addObject:@(port)];}
            NSInteger nextPort=18780;
            for(NSDictionary *service in imported){NSMutableDictionary *saved=[service mutableCopy];while([ports containsObject:@(nextPort)]&&nextPort<65535)nextPort++;if(nextPort<65535){saved[@"port"]=@(nextPort);[ports addObject:@(nextPort)];nextPort++;}[ServiceStore save:saved];}
            [owner refreshConfigurationPage];MediaBrowserViewController *browser=(MediaBrowserViewController *)owner.tabPages[@2];[browser refreshSources];if(weakPage)[weakPage.tableView reloadData];
            NSUInteger native=nativeCount,skipped=alreadyImported;
             NSMutableString *message=[NSMutableString stringWithFormat:@"原生接口与索引：%lu 个可按需浏览\n脚本站点加入：%lu 个\n已存在脚本：%lu 个\n直播清单：%lu 个继续保留在合集内，点选后才加载",(unsigned long)native,(unsigned long)imported.count,(unsigned long)skipped,(unsigned long)supportedLiveCount];
            if(failures.count)[message appendFormat:@"\n未识别或下载失败：%lu 个，仍保留在合集中。",(unsigned long)failures.count];
            if(cancelled)[message appendString:@"\n批量导入已取消；已经完成的项目已保存。"];
            if(importer.downloadLimitReached)[message appendString:@"\n累计下载达到 512 MiB 安全上限；已经完成的项目已保存。"];
            NSString *summaryTitle=importer.downloadLimitReached?@"已达到批量下载上限":(cancelled?@"批量导入已停止":@"整包内容已加入");
            UIAlertController *summary=[UIAlertController alertControllerWithTitle:summaryTitle message:message preferredStyle:UIAlertControllerStyleAlert];[summary addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            if(owner.presentedViewController==weakProgress)[weakProgress dismissViewControllerAnimated:YES completion:^{[owner presentViewController:summary animated:YES completion:nil];}];else[owner presentViewController:summary animated:YES completion:nil];
        }];
    }];
}
- (void)deleteSubscription:(NSString *)source {
    [self.subscriptionTasks[source] cancel];[self.subscriptionTasks removeObjectForKey:source];[self.subscriptionTraceIDs removeObjectForKey:source];[ProfileStore remove:source];
    [self.subscriptionURLs removeObject:source];self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];[NSUserDefaults.standardUserDefaults setObject:self.subscriptionURLs.allObjects forKey:@"subscriptions"];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.shownChannels.count;}
- (CGFloat)catalogTextHeight:(NSString *)text font:(UIFont *)font width:(CGFloat)width maximumLines:(NSUInteger)maximumLines {
    if(!text.length||width<=0)return ceil(font.lineHeight);
    CGFloat maximumHeight=ceil(font.lineHeight*MAX(1,maximumLines));
    CGRect measured=[text boundingRectWithSize:CGSizeMake(width,maximumHeight) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:font} context:nil];
    return MIN(maximumHeight,MAX(ceil(font.lineHeight),ceil(measured.size.height)));
}
- (NSString *)catalogSubtitleForChannel:(NSDictionary *)channel {
    NSString *cached=self.epgCache[channel[@"id"]][@"now"];
    return [cached isKindOfClass:NSString.class]&&cached.length?cached:([channel[@"group"] isKindOfClass:NSString.class]?channel[@"group"]:@"");
}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewFlowLayout *flow=[layout isKindOfClass:UICollectionViewFlowLayout.class]?(id)layout:nil;
    NSInteger columns=self.gridColumns==3?3:4;
    UIEdgeInsets inset=flow?flow.sectionInset:UIEdgeInsetsZero;
    CGFloat spacing=flow?flow.minimumInteritemSpacing:6;
    CGFloat itemWidth=floor(MAX(1,(collectionView.bounds.size.width-inset.left-inset.right-(columns-1)*spacing)/columns));
    UIFont *titleFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];
    UIFont *subtitleFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9] compatibleWithTraitCollection:self.traitCollection];
    NSDictionary *channel=ip.item>=0&&ip.item<self.shownChannels.count?self.shownChannels[ip.item]:@{};
    NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:([channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"");
    if([self.favorites containsObject:channel[@"id"]])name=[@"♥ " stringByAppendingString:name];
    CGFloat labelWidth=MAX(1,itemWidth-4);
    CGFloat titleHeight=[self catalogTextHeight:name font:titleFont width:labelWidth maximumLines:2];
    CGFloat subtitleHeight=[self catalogTextHeight:[self catalogSubtitleForChannel:channel] font:subtitleFont width:labelWidth maximumLines:2];
    CGFloat posterHeight=MIN(78,MAX(44,floor(itemWidth*.68)));
    CGFloat height=posterHeight+5+titleHeight+1+subtitleHeight+4;
    return CGSizeMake(itemWidth,height);
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"channel.card" forIndexPath:ip];
    if(ip.item<0||ip.item>=(NSInteger)self.shownChannels.count)return cell;
    NSDictionary *ch=self.shownChannels[ip.item];
    HostStyleGlassCard(cell.contentView,11);
    const NSInteger posterTag=4101,logoTag=4102,brandTag=4103,numberTag=4104,titleTag=4105,subtitleTag=4106,selectedTag=4107;
    UIView *poster=[cell.contentView viewWithTag:posterTag];UIImageView *logo=(UIImageView *)[cell.contentView viewWithTag:logoTag];UILabel *brand=(UILabel *)[cell.contentView viewWithTag:brandTag];UILabel *number=(UILabel *)[cell.contentView viewWithTag:numberTag];UILabel *title=(UILabel *)[cell.contentView viewWithTag:titleTag];UILabel *subtitle=(UILabel *)[cell.contentView viewWithTag:subtitleTag];UIImageView *selectedMark=(UIImageView *)[cell.contentView viewWithTag:selectedTag];
    if(!poster){poster=[[UIView alloc] initWithFrame:CGRectZero];poster.tag=posterTag;poster.autoresizingMask=UIViewAutoresizingFlexibleWidth;poster.backgroundColor=HostCard();poster.layer.cornerRadius=8;[cell.contentView addSubview:poster];
        logo=[UIImageView new];logo.tag=logoTag;logo.autoresizingMask=UIViewAutoresizingFlexibleWidth;logo.contentMode=UIViewContentModeScaleAspectFit;[poster addSubview:logo];
        brand=[UILabel new];brand.tag=brandTag;brand.textAlignment=NSTextAlignmentCenter;brand.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont italicSystemFontOfSize:14]];brand.adjustsFontForContentSizeCategory=YES;brand.textColor=HostText();brand.autoresizingMask=UIViewAutoresizingFlexibleWidth;brand.numberOfLines=2;[poster addSubview:brand];
        number=[UILabel new];number.tag=numberTag;number.font=[UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];number.textColor=HostSecondaryText();[poster addSubview:number];
        title=[UILabel new];title.tag=titleTag;title.autoresizingMask=UIViewAutoresizingFlexibleWidth;title.adjustsFontForContentSizeCategory=YES;title.numberOfLines=2;title.lineBreakMode=NSLineBreakByTruncatingTail;[cell.contentView addSubview:title];
        subtitle=[UILabel new];subtitle.tag=subtitleTag;subtitle.autoresizingMask=UIViewAutoresizingFlexibleWidth;subtitle.adjustsFontForContentSizeCategory=YES;subtitle.numberOfLines=2;subtitle.lineBreakMode=NSLineBreakByTruncatingTail;subtitle.textColor=HostSecondaryText();[cell.contentView addSubview:subtitle];
        selectedMark=[UIImageView new];selectedMark.tag=selectedTag;selectedMark.contentMode=UIViewContentModeScaleAspectFit;selectedMark.image=[UIImage systemImageNamed:@"checkmark.circle.fill"];selectedMark.tintColor=HostAccent();selectedMark.backgroundColor=[UIColor colorWithWhite:0 alpha:.42];selectedMark.layer.cornerRadius=9;selectedMark.clipsToBounds=YES;[poster addSubview:selectedMark];}
    title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];subtitle.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:9] compatibleWithTraitCollection:self.traitCollection];
    CGFloat width=cell.contentView.bounds.size.width;
    CGFloat posterHeight=MIN(78,MAX(44,floor(width*.68)));
    NSString *channelID=[ch[@"id"] isKindOfClass:NSString.class]?ch[@"id"]:@"";
    NSString *name=[ch[@"name"] isKindOfClass:NSString.class]?ch[@"name"]:([ch[@"id"] isKindOfClass:NSString.class]?ch[@"id"]:@"");
    BOOL selected=[channelID isEqualToString:self.channelID];
    NSString *titleText=[NSString stringWithFormat:@"%@%@",[self.favorites containsObject:channelID]?@"♥ ":@"",name];
    title.text=titleText;subtitle.text=[self catalogSubtitleForChannel:ch];
    CGFloat labelWidth=MAX(1,width-4),titleHeight=[self catalogTextHeight:titleText font:title.font width:labelWidth maximumLines:2],subtitleHeight=[self catalogTextHeight:subtitle.text font:subtitle.font width:labelWidth maximumLines:2];
    CGFloat titleTop=posterHeight+5,subtitleTop=titleTop+titleHeight+1;
    poster.frame=CGRectMake(0,0,width,posterHeight);poster.layer.borderWidth=selected?1.8:.5;HostSetLayerBorderColor(poster,selected?HostAccent():HostBorder());
    CGFloat logoInset=MAX(8,floor(width*.15)),logoHeight=MIN(30,MAX(20,floor(posterHeight*.44)));logo.frame=CGRectMake(logoInset,floor((posterHeight-logoHeight)/2),MAX(1,width-logoInset*2),logoHeight);brand.frame=CGRectMake(5,MAX(4,floor((posterHeight-34)/2)),MAX(1,width-10),34);number.frame=CGRectMake(6,posterHeight-15,62,12);selectedMark.frame=CGRectMake(MAX(2,width-22),5,16,16);selectedMark.hidden=!selected;
    title.frame=CGRectMake(2,titleTop,labelWidth,titleHeight);subtitle.frame=CGRectMake(2,subtitleTop,labelWidth,subtitleHeight);
    NSString *logoURL=[ch[@"logo"] isKindOfClass:NSString.class]?ch[@"logo"]:@"";logo.hidden=NO;brand.hidden=YES;brand.text=name;
    if(logoURL.length){logo.image=nil;logo.backgroundColor=UIColor.clearColor;logo.layer.cornerRadius=0;logo.clipsToBounds=NO;[self loadLogo:logoURL into:logo];}
    else{logo.image=CCTVChannelLogoImage(ch);logo.accessibilityIdentifier=[@"channel-logo:" stringByAppendingString:channelID];BOOL dark=CCTVChannelLogoNeedsDarkBacking(channelID);logo.backgroundColor=dark?[UIColor colorWithWhite:.10 alpha:1]:UIColor.clearColor;logo.layer.cornerRadius=dark?5:0;logo.clipsToBounds=dark;}
    number.text=[NSString stringWithFormat:@"%03lu",(unsigned long)ip.item+1];title.textColor=selected?HostAccent():HostText();cell.contentView.backgroundColor=selected?HostSelectedSurface():UIColor.clearColor;
    cell.accessibilityIdentifier=[@"channel-card-" stringByAppendingString:channelID];cell.accessibilityLabel=name;cell.accessibilityValue=selected?@"正在播放":@"频道";cell.accessibilityHint=@"轻点播放，长按选择线路与节目单";
    NSString *xmlSource=[ProfileStore epgSourceForChannel:ch];if(xmlSource.length && !self.epgCache[ch[@"id"]])[self cacheXMLRows:[[XMLTVStore shared] cachedRowsForSource:xmlSource channel:[ProfileStore epgIDForChannel:ch]] channel:ch[@"id"]];subtitle.text=[self catalogSubtitleForChannel:ch];return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip { if(ip.item<0||ip.item>=(NSInteger)self.shownChannels.count)return;HostAnimateSelection([collectionView cellForItemAtIndexPath:ip]);[self selectChannel:self.shownChannels[ip.item]]; }
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(ip.item<0||ip.item>=(NSInteger)self.shownChannels.count)return nil;
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
        self.selectionVersion++;self.playerTabs.selectedSegmentIndex=1;[self selectPlayerPanel];self.playerExpanded=YES;[self configureCatalogNavigation];[self.view setNeedsLayout];return;
    }
    // Coalesce rapid taps without the previous fixed 80 ms delay.
    NSTimeInterval selectedAt=CACurrentMediaTime();NSUInteger selection=++self.selectionVersion;NSString *selectionTraceID=NSUUID.UUID.UUIDString.lowercaseString;self.currentPlaybackTraceID=selectionTraceID;self.playbackIntentVersion++;[self.playbackReadiness cancel];[self stopPreview];
    BOOL remote=[ch[@"remoteURL"] length]||[ProfileStore isHTTP:ch[@"id"]];
    NSMutableDictionary *selectionFields=[@{@"input_type":remote?@"subscription":@"cctv", @"selection_generation":@(selection), @"channel_id_kind":remote?@"http_url":@"sdk_channel_id", @"correlation_id":selectionTraceID} mutableCopy];
    if(remote)[selectionFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:ch[@"remoteURL"]?:ch[@"id"]?:@""])];
    else if([ch[@"id"] isKindOfClass:NSString.class]&&[ch[@"id"] length]<=128)selectionFields[@"sdk_channel_id"]=ch[@"id"];
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

- (NSArray *)visibleRecents {NSSet *ids=[NSSet setWithArray:[self.allChannels valueForKey:@"id"]?:@[]];return [self.recents filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r,NSDictionary *b){return [ids containsObject:r[@"id"]];}]];}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    (void)t;
    return 1;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    (void)t; (void)s;
    return nil;
}
- (void)tableView:(UITableView *)t willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s {
    HostStyleSectionHeaderView(view);
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    (void)t; (void)s;
    return (NSInteger)self.shownChannels.count;
}

- (NSArray<NSDictionary *> *)channelsForSection:(NSInteger)section tableView:(UITableView *)t {
    (void)section; (void)t;
    return self.shownChannels;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *reuse = @"channel.list";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[CCTVChannelListCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
        cell.backgroundColor = HostCard();
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=1;cell.textLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=2;cell.detailTextLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        cell.detailTextLabel.textColor = HostSecondaryText();
        cell.imageView.contentMode=UIViewContentModeScaleAspectFit;cell.separatorInset=UIEdgeInsetsMake(0,80,0,0);cell.preservesSuperviewLayoutMargins=NO;
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
    cell.backgroundColor=playing?HostSelectedSurface():HostCard();
    cell.layer.cornerRadius=13; cell.layer.cornerCurve=kCACornerCurveContinuous; cell.clipsToBounds=YES;
    cell.layer.borderWidth=playing?1.1:0.6; HostSetLayerBorderColor(cell,playing?HostAccent():HostBorder());
    if(playing){UIImageView *check=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];check.tintColor=HostAccent();check.accessibilityLabel=@"正在播放";cell.accessoryView=check;cell.accessoryType=UITableViewCellAccessoryNone;}
    else {cell.accessoryView=nil;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    cell.accessibilityIdentifier=[@"channel-row-" stringByAppendingString:cid];
    cell.accessibilityLabel=[ch[@"name"] isKindOfClass:NSString.class]?ch[@"name"]:cid;
    cell.accessibilityValue=playing?@"正在播放":@"频道";
    cell.accessibilityHint=@"轻点播放，长按选择线路与节目单";
    NSString *logo = [ch[@"logo"] isKindOfClass:NSString.class] ? ch[@"logo"] : @"";
    if (logo.length) {cell.imageView.image=nil;cell.imageView.backgroundColor=UIColor.clearColor;cell.imageView.layer.cornerRadius=0;cell.imageView.clipsToBounds=NO;[self loadLogo:logo into:cell.imageView];}
    else {cell.imageView.image=CCTVChannelLogoImage(ch);cell.imageView.accessibilityIdentifier=[@"channel-logo:" stringByAppendingString:cid];BOOL dark=CCTVChannelLogoNeedsDarkBacking(cid);cell.imageView.backgroundColor=dark?[UIColor colorWithWhite:.10 alpha:1]:UIColor.clearColor;cell.imageView.layer.cornerRadius=dark?5:0;cell.imageView.clipsToBounds=dark;}
    cell.imageView.tintColor=HostAccent();
    NSDictionary *epg = self.epgCache[cid];
    NSString *nowTitle = [epg[@"now"] isKindOfClass:NSString.class] && [epg[@"now"] length] ? epg[@"now"] : nil;
    NSString *nextTitle = [epg[@"next"] isKindOfClass:NSString.class] && [epg[@"next"] length] ? epg[@"next"] : nil;
    if (nowTitle) {
        cell.detailTextLabel.text = nextTitle ? [NSString stringWithFormat:@"正在播：%@ · 稍后：%@", nowTitle, nextTitle] : [NSString stringWithFormat:@"正在播：%@", nowTitle];
    } else if ([ch[@"remoteURL"] length]) {
        NSString *groupName=[ch[@"group"] isKindOfClass:NSString.class]&&[ch[@"group"] length]?ch[@"group"]:@"订阅源";
        cell.detailTextLabel.text = [groupName isEqualToString:@"订阅"] ? @"订阅源" : [NSString stringWithFormat:@"%@ · 订阅源", groupName];
    } else {
        NSUInteger routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? [ch[@"routes"] count] : 0;
        NSString *groupName=[ch[@"group"] isKindOfClass:NSString.class]?ch[@"group"]:@"直播";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu 线路", groupName, (unsigned long)routes];
    }
    if (self.recentsOnly) {
        for (NSDictionary *rec in self.recents) {
            if ([rec[@"id"] isEqualToString:cid] && [rec[@"watchedAt"] respondsToSelector:@selector(doubleValue)]) {
                NSTimeInterval elapsed = MAX(0, NSDate.date.timeIntervalSince1970 - [rec[@"watchedAt"] doubleValue]);
                NSString *timeTag = elapsed < 60 ? @"刚刚观看" : (elapsed < 3600 ? [NSString stringWithFormat:@"%.0f 分钟前观看", floor(elapsed / 60.0)] : (elapsed < 86400 ? [NSString stringWithFormat:@"%.0f 小时前观看", floor(elapsed / 3600.0)] : @"最近观看"));
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", timeTag, cell.detailTextLabel.text ?: @""];
                break;
            }
        }
    }
    [self loadEPGForChannel:cid channel:ch section:ip];
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
    // Keep the SDK's per-core license defaults. Cicada and IJK use distinct
    // endpoints; do not replace Cicada's license URL with IJK's.
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
    self.livePlaybackSuspendedForNavigation=NO;
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
    [self.channelGrid reloadData];[self.table reloadData];
    self.routeName = route ? [NSString stringWithFormat:@"%@ · 自选地址", [route[@"provider"] uppercaseString]] : @"自动";
    if(self.playerTabs.selectedSegmentIndex!=3)self.playerTabs.selectedSegmentIndex=1;
    [self updatePlayerChannelLogoForChannel:ch];
    [self selectPlayerPanel];
    self.firstRender = NO;
    self.stallReported = NO;
    self.nativeStartupRecoveryUsed = NO;
    self.nativeSafeStartupActive = NO;
    self.nativeAttemptStartedAt = 0;
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
        if(CCTVRouteRequiresSDK(route)){
            [self log:@"所选线路标记为 UDRM / SDK 流，跳过普通 HLS 探测并交给 CNPlayer"];
            [self playViaSDKURL:selectedURL channelID:cid title:self.channelName];return;
        }
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

// Starts a new native SDK session: bumps the session ID and installs a fresh
// session delegate as the SDK delegate for this playback. Every native play
// start goes through here so no callback can ever be attributed to an older
// session, even when the legacy path reuses the same CNPlayer instance.
- (CNPlayerSessionDelegate *)beginNativeSession {
    self.nativeSessionID++;
    self.nativeSessionDelegate=[[CNPlayerSessionDelegate alloc] initWithOwner:self sessionID:self.nativeSessionID];
    return self.nativeSessionDelegate;
}

- (void)rebuildTimeshiftController {
    // 控制器与播放器一一对应：每次起播（或起播失败换实例）都重建，
    // 旧控制器的回调随之丢弃，不串台；回调弱引用宿主，避免循环引用。
    if(!self.currentPlayer){self.timeshiftController=nil;return;}
    self.timeshiftController=[[CCTVTimeshiftController alloc] initWithPlayer:self.currentPlayer];
    __weak typeof(self) weakSelf=self;
    self.timeshiftController.onFailure=^(NSError *error){[weakSelf displayNativePlaybackFailure:@"时移 / 回看失败" error:error];};
    self.timeshiftController.onReturnToLiveFallback=^{[weakSelf playSelectedNativeRouteOrChannel];};
    self.timeshiftController.onProgress=^(NSTimeInterval behindLive,NSTimeInterval position){weakSelf.infoLabel.hidden=NO;weakSelf.infoLabel.text=[NSString stringWithFormat:@"回看中 · 距直播 %.0f 分钟",behindLive/60.0];};
}
- (void)playViaSDKURL:(NSString *)url channelID:(NSString *)cid title:(NSString *)title {
    [CNPlayerCrashGuard install];
    if(!url.length||!cid.length){[self displayNativePlaybackFailure:@"所选线路参数缺失" error:nil];return;}
    NSMutableDictionary *traceFields=[@{@"route_type":@"user_selected", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@""} mutableCopy];[traceFields addEntriesFromDictionary:CCTVDiagnosticURLFields([NSURL URLWithString:url])];[RuntimeDiagnostics.shared recordEvent:@"native_playback_start_requested" category:@"playback" fields:traceFields];
    [self beginPlaybackPriority];
    self.nativeRetryPending=NO;self.nativePlaybackFailed=NO;[self.remoteAttemptedURLs removeAllObjects];self.remoteRetryCount=0;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",title?:cid];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"所选地址交给央视 SDK 播放";[self.spinner startAnimating];
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    [self.nativePreloader cancel];self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
    Class cls=NSClassFromString(@"CNPlayer");SEL selector=NSSelectorFromString(@"playLIVEWithUrl:delegate:configOptions:");
    id player=nil;@try{player=[[cls alloc] init];}@catch(NSException *exception){[self log:@"创建 SDK 播放器异常 %@",exception.reason];}
    NSMethodSignature *signature=[player methodSignatureForSelector:selector];
    BOOL supported=player&&[player respondsToSelector:selector]&&signature&&signature.numberOfArguments==5&&signature.methodReturnType[0]=='B'&&strcmp([signature getArgumentTypeAtIndex:2],"@")==0&&strcmp([signature getArgumentTypeAtIndex:3],"@")==0&&strcmp([signature getArgumentTypeAtIndex:4],"@")==0;
    if(!supported){[self displayNativePlaybackFailure:@"SDK 不支持自选地址起播" error:nil];return;}
    self.currentPlayer=player;self.cicadaPlayer=nil;self.nativePlaybackFailed=NO;
    [self rebuildTimeshiftController];
    @try{[player setValue:@YES forKey:@"autoPlay"];}@catch(NSException *exception){}
    self.nativeStartupTuner=CCTVBoolPreference(@"fastNativeStartup",YES)?[NativeStartupTuner new]:nil;
    NSMutableDictionary *options=[@{kOptTitle:title?:cid,kOptURLChannelIDForStats:cid} mutableCopy];
    id dataManager=[self call:player sel:@"dataManager"];
    id userID=[self call:dataManager sel:@"userID"];
    if([userID isKindOfClass:NSString.class]&&[userID length])options[kOptUserID]=userID;
    [self log:@"CNPlayer URL 起播 %@ · %@",cid,[NSURL URLWithString:url].host?:@"未知主机"];
    CNPlayerSessionDelegate *session=[self beginNativeSession];
    id accepted=[self invokeTarget:player selector:selector args:@[url,session,options]];
    [self recordStartupStage:@"configure"];
    if(![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        self.nativeSessionDelegate=nil;self.currentPlayer=nil;@try{[player setValue:nil forKey:@"delegate"];}@catch(NSException *exception){}[self call:player sel:@"stop"];
        [self log:@"CNPlayer 未接受所选地址；保留线路选择，不回退自动"];
        [self displayNativePlaybackFailure:@"SDK 拒绝所选地址" error:nil];return;
    }
    if(![CNPlayerCrashGuard install])[self log:@"未能安装播放器缩略图异常保护"];
    [self attachVideoView];[self call:player sel:@"prepareToPlay"];[self recordStartupStage:@"prepareCall"];[self startWatchdog];
    [self updateLiveScreenAwakeState];
}

- (void)playViaSDK:(NSString *)cid title:(NSString *)title {
    // Some SDK builds load their IJK core lazily; install the guard again
    // before prepareToPlay can enter its asynchronous decoder/error path.
    [CNPlayerCrashGuard install];
    NSMutableDictionary *startFields=[@{@"route_type":@"sdk_auto", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"channel_id_kind":([ProfileStore isHTTP:cid]?@"http_url":@"sdk_channel_id"), @"startup_mode":self.nativeSafeStartupActive?@"default_recovery":@"normal"} mutableCopy];
    if(![ProfileStore isHTTP:cid]&&cid.length<=128)startFields[@"sdk_channel_id"]=cid;
    [RuntimeDiagnostics.shared recordEvent:@"native_playback_start_requested" category:@"playback" fields:startFields];
    if([ProfileStore isHTTP:cid]){[self playRemote:@{@"id":cid,@"name":title?:cid,@"remoteURL":cid}];return;}
    [self beginPlaybackPriority];
    self.nativeRetryPending=NO;self.nativePlaybackFailed=NO;[self.remoteAttemptedURLs removeAllObjects];self.remoteRetryCount=0;self.playPauseBtn.enabled=YES;[self.playPauseBtn setTitle:@"暂停" forState:UIControlStateNormal];self.titleLabel.text=[NSString stringWithFormat:@"%@ · 连接中",title?:cid];self.titleLabel.hidden=NO;self.infoLabel.hidden=NO;self.infoLabel.text=@"";[self.spinner startAnimating];
    // Default matches v0.12: stop the old playback, reset the retained wrapper,
    // then playLIVEWithChannelID + prepareToPlay. Fresh wrappers remain an A/B option.
    if(self.currentPlayer){[self stopPlayback];[self recordStartupStage:@"teardown"];}
    Class cls=NSClassFromString(@"CNPlayer");SEL playSel=NSSelectorFromString(@"playLIVEWithChannelID:delegate:configOptions:");
    BOOL legacy=!self.nativeSafeStartupActive && CCTVBoolPreference(@"legacyNativePlayback",YES);
    id prepared=(!self.nativeSafeStartupActive && !self.directNativeRouteActive && CCTVBoolPreference(@"preloadNativeChannel",YES))?[self.nativePreloader takeChannel:cid]:nil;
    [self.nativePreloader cancel];
    id inst=prepared?:self.sdkPlayer;
    if(prepared && self.sdkPlayer && prepared!=self.sdkPlayer)[self call:self.sdkPlayer sel:@"reset"];
    if(!prepared && !legacy&&self.sdkPlayerUsed)inst=nil;
    if(!prepared && legacy&&inst&&self.sdkPlayerUsed)[self call:inst sel:@"reset"];
    self.sdkPlayer=nil;
    if(!inst){@try{inst=[[cls alloc] init];}@catch(NSException *e){[self log:@"创建播放器异常 %@",e.reason];}}
    if(!inst||![inst respondsToSelector:playSel]){[self displayNativePlaybackFailure:@"SDK 接口不可用" error:nil];return;}
    self.currentPlayer=inst;self.cicadaPlayer=nil;self.sdkPlayer=legacy?inst:nil;self.sdkPlayerUsed=YES;
    [self rebuildTimeshiftController];
    CNPlayerSessionDelegate *session=[self beginNativeSession];
    @try{[inst setValue:@YES forKey:@"autoPlay"];}@catch(NSException *e){}
    self.nativePlaybackFailed=NO;
    self.nativeStartupTuner=!self.nativeSafeStartupActive && CCTVBoolPreference(@"fastNativeStartup",YES)?[NativeStartupTuner new]:nil;
    NSDictionary *options=@{kOptTitle:title?:cid};
    [self log:@"原生起播 %@ · %@",cid,self.nativeSafeStartupActive?@"SDK 默认配置恢复":(legacy?@"0.12 兼容复用":@"独立实例对比")];
    id accepted=@YES;
    if(prepared){
        @try{[inst setValue:session forKey:@"delegate"];}@catch(NSException *e){prepared=nil;}
        if(prepared){[self recordStartupStage:@"preloadedVDN"];[self log:@"命中原生预解析 %@，保留播放信息直接 prepare",cid];}
    }
    if(!prepared)accepted=[self invokeTarget:inst selector:playSel args:@[cid,session,options]];
    if(![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        id previous=inst;self.currentPlayer=nil;self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
        @try{[previous setValue:nil forKey:@"delegate"];}@catch(NSException *e){}
        [self call:previous sel:@"stop"];
        [self log:@"SDK 实例未确认起播，使用全新实例重试一次"];
        @try{inst=[[cls alloc] init];}@catch(NSException *e){inst=nil;}
        if(inst){self.currentPlayer=inst;self.sdkPlayer=legacy?inst:nil;self.sdkPlayerUsed=YES;self.nativePlaybackFailed=NO;self.nativeRetryPending=NO;[self rebuildTimeshiftController];@try{[inst setValue:@YES forKey:@"autoPlay"];}@catch(NSException *e){}accepted=[self invokeTarget:inst selector:playSel args:@[cid,session,options]];}
    }
    [self recordStartupStage:@"configure"];
    if(!inst||![accepted isKindOfClass:NSNumber.class]||![accepted boolValue]){
        self.currentPlayer=nil;self.sdkPlayer=nil;self.sdkPlayerUsed=NO;
        [self.nativeStartupTuner restore];self.nativeStartupTuner=nil;
        @try{[inst setValue:nil forKey:@"delegate"];}@catch(NSException *e){}
        [self call:inst sel:@"stop"];
        [self log:@"SDK 未确认接受起播，停止本次尝试"];[self displayNativePlaybackFailure:@"起播被拒绝" error:nil];return;
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
    // Invalidate the native session first: any callback still in flight to the
    // old session delegate is dropped by its session check, and bumping the ID
    // keeps even a delegate retained by the SDK from forwarding again.
    self.nativeSessionDelegate=nil;self.nativeSessionID++;
    [self.nativeRouteProbe cancel];self.nativeRouteProbe=nil;
    self.nativeRetryPending=NO;
    self.moviePiPActive=NO;
    [self.moviePlayer pause];self.movieController.player=nil;self.moviePlayer=nil;self.movieController=nil;
    [self.nativeTimeshift cancel];self.nativeTimeshift=nil;self.nativeTransitionKind=nil;self.nativeTimeShiftActive=NO;
    [self.nativeStartupTuner restore];
    self.nativeStartupTuner=nil; // Restore before the retained SDK wrapper is stopped or reused.
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
        if (v == self.titleLabel || v == self.infoLabel || v == self.spinner || v == self.controlBar || v == self.playerChannelLogo || v == self.playerTopScrim || v == self.playerBottomScrim) continue;
        [v removeFromSuperview];
    }
    [self updateLiveScreenAwakeState];
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
    if(self.livePlaybackSuspendedForNavigation){
        self.livePlaybackSuspendedForNavigation=NO;
        if(self.activeTab==1&&self.currentRemoteURL.length){[self playRemote:@{@"id":self.channelID?:self.currentRemoteURL,@"name":self.channelName?:@"直播",@"remoteURL":self.currentRemoteURL,@"headers":self.currentRemoteHeaders?:@{}}];return;}
        NSDictionary *channel=[self channelWithID:self.channelID];
        if(!channel&&self.channelID.length)channel=@{@"id":self.channelID,@"name":self.channelName?:self.channelID};
        if(channel){self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:self.requestedNativeRoute];}
        return;
    }
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
    BOOL expandedLive=[self isExpandedLivePlayerVisible];
    if (self.fullscreen) {
        self.playerBox.frame = self.view.bounds;
        self.liveResourceCapsule.hidden=YES;
        self.bottomBar.hidden = YES;
        self.bottomBarBackdrop.hidden = YES;
        self.resourceActionsButton.hidden=YES;
        self.catalogFloatingControls.hidden=YES;
        self.channelGrid.hidden=YES;
        self.playerTabs.hidden=YES;
        self.playbackPanel.view.hidden=YES;
        self.tabPage.view.hidden=YES;
    } else {
        BOOL catalog=self.activeTab<2;
        CGFloat capsuleRowHeight=expandedLive?44:0;
        CGFloat playerTop=expandedLive?top+capsuleRowHeight:0;
        CGFloat ph=expandedLive?MIN(w*9.0/16.0,MAX(120,(height-safe.bottom-playerTop)*0.50)):0;
        self.playerBox.frame=CGRectMake(0,playerTop,w,ph);self.playerBox.hidden=!catalog||!expandedLive;
        self.liveResourceCapsule.hidden=!catalog||!expandedLive;
        if(!self.liveResourceCapsule.hidden){CGFloat maximumWidth=MAX(0,w-safe.left-safe.right-28);CGFloat naturalWidth=[self.liveResourceCapsule sizeThatFits:CGSizeMake(maximumWidth,36)].width;CGFloat capsuleWidth=MIN(maximumWidth,MIN(270,MAX(150,naturalWidth)));self.liveResourceCapsule.frame=CGRectMake(safe.left+14,top+4,capsuleWidth,36);}
        CGFloat playerBottom=expandedLive?playerTop+ph:top;
        CGFloat y=playerBottom;
        // 大字体下分段标题行高会超过 32pt 固定高度而被裁：按缩放后行高给高度。
        UIFont *segmentFont=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];
        CGFloat segmentHeight=MAX(32,ceil(segmentFont.lineHeight)+14);
        self.groupControl.frame=CGRectMake(12,y+6,w-24,segmentHeight);self.groupControl.hidden=!catalog||expandedLive;self.playerTabs.frame=CGRectMake(12,y+6,w-24,segmentHeight);self.playerTabs.hidden=!catalog||!expandedLive;
        self.versionLabel.hidden=YES;
        CGFloat tabHeight=58,tabWidth=MIN(w,560),tabY=MAX(0,height-safe.bottom-tabHeight),tabContentInset=MAX(8,height-tabY+8);self.bottomBar.frame=CGRectMake(MAX(0,(w-tabWidth)/2),tabY,tabWidth,tabHeight);self.bottomBarBackdrop.frame=CGRectMake(0,tabY,w,MAX(tabHeight,height-tabY));self.bottomDockFadeGradient.frame=self.bottomBarBackdrop.bounds;self.bottomDockGlass.frame=CGRectMake(MAX(10,(w-MIN(w-20,540))/2),2,MIN(w-20,540),tabHeight-4);self.bottomBar.hidden=NO;self.bottomBarBackdrop.hidden=NO;
        BOOL showMiniBar=self.livePlaybackSuspendedForNavigation&&self.channelID.length&&self.activeTab>=2;self.liveMiniPlayerBar.hidden=!showMiniBar;if(showMiniBar){CGFloat miniW=MIN(w-28,520),miniH=42;self.liveMiniPlayerBar.frame=CGRectMake((w-miniW)/2,MAX(top+8,tabY-miniH-8),miniW,miniH);self.liveMiniPlayerCloseButton.frame=CGRectMake(miniW-38,5,32,32);self.liveMiniPlayerResumeButton.frame=CGRectMake(miniW-130,5,88,32);self.liveMiniPlayerLabel.frame=CGRectMake(14,0,MAX(0,miniW-150),miniH);[self.view bringSubviewToFront:self.liveMiniPlayerBar];}
        CGFloat contentY=y+6+segmentHeight+4;CGFloat contentBottom=height;CGFloat catalogBottomInset=tabContentInset+62;
        CGRect frame=CGRectMake(0,0,w,MAX(0,contentBottom));UIEdgeInsets catalogInsets=UIEdgeInsetsMake(contentY,0,catalogBottomInset,0);CCTVApplyImmersiveScrollGeometry(self.table,frame,catalogInsets);CCTVApplyImmersiveScrollGeometry(self.channelGrid,frame,catalogInsets);
        self.table.hidden=!catalog||self.gridMode||self.playbackPanel!=nil;self.channelGrid.hidden=!catalog||!self.gridMode||self.playbackPanel!=nil;self.playbackPanel.view.frame=[self.playbackPanel isKindOfClass:CCTVPlaybackListPanelController.class]?frame:CGRectMake(0,contentY,w,MAX(0,contentBottom-contentY));self.playbackPanel.view.hidden=!catalog;if([self.playbackPanel isKindOfClass:CCTVPlaybackListPanelController.class]){UITableView *panelTable=((CCTVPlaybackListPanelController *)self.playbackPanel).tableView;CCTVApplyImmersiveScrollGeometry(panelTable,panelTable.frame,catalogInsets);}else if([self.playbackPanel isKindOfClass:EPGViewController.class]){UITableView *epgTable=[self.playbackPanel valueForKey:@"table"];if([epgTable isKindOfClass:UITableView.class])epgTable.contentInset=UIEdgeInsetsMake(0,0,catalogBottomInset,0);}
        // Every tab page owns the full root bounds. Child controls use their
        // safe-area guides, while their backgrounds and scroll views can pass
        // behind the status and navigation bars.
        BOOL resourcePage=[self.tabPage isKindOfClass:ConfigCenterViewController.class];CGFloat pageTop=0;self.tabPage.view.frame=CGRectMake(0,pageTop,w,MAX(0,contentBottom-pageTop));if(resourcePage){[(ConfigCenterViewController *)self.tabPage setTopSafeAreaInset:top];[(ConfigCenterViewController *)self.tabPage setBottomOverlayInset:tabContentInset];}else if([self.tabPage isKindOfClass:MediaBrowserViewController.class]){[(MediaBrowserViewController *)self.tabPage setTopSafeAreaInset:top];[(MediaBrowserViewController *)self.tabPage setBottomOverlayInset:tabContentInset];}else if([self.tabPage isKindOfClass:SettingsViewController.class])[(SettingsViewController *)self.tabPage setBottomOverlayInset:tabContentInset];
        self.catalogTopImmersiveScrim.hidden=!catalog||expandedLive;
        self.catalogGroupGlassCard.hidden=!catalog||expandedLive;
        if(!self.catalogTopImmersiveScrim.hidden){
            UIScrollView *activeScroll=self.gridMode?(UIScrollView *)self.channelGrid:(UIScrollView *)self.table;
            CGFloat scrollProgress=MIN(1.0,MAX(0.0,(activeScroll.contentOffset.y+contentY)/96.0));
            HostUpdateImmersiveTopScrim(self.catalogTopImmersiveScrim,self.catalogTopImmersiveGradient,CGRectMake(0,0,w,contentY+14),scrollProgress,NO);
            self.catalogGroupGlassCard.frame=CGRectInset(self.groupControl.frame,-2,-2);
        }
        self.playerTopScrim.frame=CGRectMake(0,0,w,MIN(CGRectGetHeight(self.playerBox.bounds),expandedLive?48:top+24));self.playerTopGradient.frame=self.playerTopScrim.bounds;
        [self.view bringSubviewToFront:self.catalogTopImmersiveScrim];[self.view bringSubviewToFront:self.catalogGroupGlassCard];[self.view bringSubviewToFront:self.playerBox];[self.view bringSubviewToFront:self.liveResourceCapsule];[self.view bringSubviewToFront:self.groupControl];[self.view bringSubviewToFront:self.playerTabs];[self.view bringSubviewToFront:self.bottomBarBackdrop];[self.view bringSubviewToFront:self.bottomBar];
        self.resourceActionsButton.hidden=YES;self.resourceActionsButton.frame=CGRectMake(w-safe.right-18-58,CGRectGetMinY(self.bottomBar.frame)-12-58,58,58);
        self.catalogFloatingControls.hidden=!catalog;CGFloat controlsWidth=164,controlsHeight=54;self.catalogFloatingControls.frame=CGRectMake(MAX(12,w-safe.right-controlsWidth-14),MAX(top+8,tabY-controlsHeight-12),controlsWidth,controlsHeight);self.catalogLayoutButton.frame=CGRectMake(4,3,48,48);self.catalogFloatingAirPlayPicker.frame=CGRectMake(58,3,48,48);self.catalogMoreButton.frame=CGRectMake(112,3,48,48);[self.view bringSubviewToFront:self.catalogFloatingControls];
    }
    UIEdgeInsets overlayInsets=[self playerOverlayInsets];
    CGFloat overlayTop=overlayInsets.top;
    CGFloat playerTitleHeight = ceil(self.titleLabel.font.lineHeight);
    CGFloat playerInfoHeight = ceil(self.infoLabel.font.lineHeight);
    self.titleLabel.frame = CGRectMake(12 + safe.left, overlayTop + 8, MAX(0, w - safe.left - safe.right - 80), playerTitleHeight);
    self.infoLabel.frame = CGRectMake(12 + safe.left, overlayTop + 8 + playerTitleHeight + 2, MAX(0, w - safe.left - safe.right - 24), playerInfoHeight);
    self.playerChannelLogo.frame=CGRectMake(MAX(safe.left+12,w-safe.right-60),overlayTop+8,48,27);
    CGFloat bottom = overlayInsets.bottom;
    CGFloat bottomScrimH = MIN(CGRectGetHeight(self.playerBox.bounds), bottom + 68);
    self.playerBottomScrim.frame = CGRectMake(0, MAX(0, CGRectGetHeight(self.playerBox.bounds) - bottomScrimH), w, bottomScrimH);
    self.playerBottomGradient.frame = self.playerBottomScrim.bounds;
    self.controlBar.frame = CGRectMake(8 + safe.left, CGRectGetHeight(self.playerBox.bounds) - bottom - 52,
                                      MAX(0, w - safe.left - safe.right - 16), 44);
    self.spinner.center=CGPointMake(CGRectGetMidX(self.playerBox.bounds),CGRectGetMidY(self.playerBox.bounds));
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
        [self applyFontSizeOverride];
        [self.channelGrid.collectionViewLayout invalidateLayout];
        [self.channelGrid reloadData];
        [self.table reloadData];
        [self.view setNeedsLayout];
    }
}

- (void)toggleFullscreen {
    self.fullscreen = !self.fullscreen;
    if (self.fullscreen) {
        // 防御：播放器可能在非展开态被隐藏，全屏时必须可见；具体布局由
        // viewDidLayoutSubviews 接管（全屏分支给 playerBox 全屏 frame）。
        self.playerBox.hidden=NO;
    } else {
        self.tabPage.view.hidden=NO;
    }
    [self configureCatalogNavigation];
    [self setNeedsStatusBarAppearanceUpdate];
    [self.view setNeedsLayout];
    [self relayoutPlayer];
    [self attachVideoView];
    self.avLayer.frame = self.playerBox.bounds;
}

- (void)relayoutPlayer {
    // 标题/信息/controlBar 的 frame 由 viewDidLayoutSubviews 在 overlayTop/
    // overlayInsets 算出后统一写，这里只保留 spinner 居中（toggleFullscreen
    // 路径下 setNeedsLayout 尚未执行时也需要它）。
    CGRect b = self.playerBox.bounds;
    self.spinner.center = CGPointMake(b.size.width / 2, b.size.height / 2);
}

#pragma mark - 订阅管理

- (void)manageSubscriptions {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"订阅源" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (!self.subscriptionURLs.count) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"暂无订阅" style:UIAlertActionStyleDefault handler:nil]];
    }
    for (NSString *u in self.subscriptionURLs.allObjects) {
        NSString *sourceName=[ProfileStore metadata:u][@"name"];
        if(![sourceName isKindOfClass:NSString.class]||!sourceName.length)sourceName=[NSURL URLWithString:u].host;
        NSString *title = sourceName.length?sourceName:(u.length > 42 ? [[u substringToIndex:42] stringByAppendingString:@"…"] : u);
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
    page.onOpenResource=^(NSDictionary *service){[weakSelf openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]?:@""]];};
    page.onToggleService=^(NSDictionary *service,BOOL enabled){[weakSelf toggleService:service enabled:enabled];};
    page.onChangeService=^(NSDictionary *service,BOOL enabled,void (^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner changeService:service enabled:enabled completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{NSLocalizedDescriptionKey:@"页面已关闭"}]);};
    page.onRestartService=^(NSDictionary *service,void (^completion)(NSError *)){[weakSelf restartMediaService:service completion:completion];};
    page.onApplyService=^(NSDictionary *previousService,NSDictionary *updatedService,void (^completion)(NSError * _Nullable)){RootViewController *owner=weakSelf;if(owner)[owner applyServiceConfigurationFrom:previousService to:updatedService completion:completion];else if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{@"NSLocalizedDescriptionKey":@"服务页面已关闭，端口更改未应用。"}]);};
    page.onBrowseService=^(NSDictionary *service){[NSUserDefaults.standardUserDefaults setObject:service[@"id"] forKey:@"selectedMediaSource"];[weakSelf.navigationController popToViewController:weakSelf animated:NO];[weakSelf selectBottomTab:(id)weakSelf.bottomBar.arrangedSubviews[2]];};
    page.onImportResource=^{[weakSelf addSubscription];};
    page.onOpenLog=^(NSDictionary *service){if(service)[weakSelf openDiagnosticLogForIdentifier:service[@"id"] name:service[@"name"]];else[weakSelf openDiagnosticLog];};
    page.onSubscribe=^(NSString *url){RootViewController *owner=weakSelf;NSString *key=[owner stableURLKey:url];if(!owner||!key.length)return;NSDictionary *service=[owner localServiceForURL:[NSURL URLWithString:key]];if(service){NSMutableDictionary *metadata=[@{@"managedServiceID":service[@"id"]?:@""} mutableCopy];if(![ProfileStore metadata:key][@"name"])[metadata addEntriesFromDictionary:@{@"name":service[@"name"]?:@"本机直播服务"}];[ProfileStore update:key values:metadata];}if(![owner.subscriptionURLs containsObject:key]){[owner.subscriptionURLs addObject:key];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:owner.subscriptionURLs.allObjects] forKey:@"subscriptions"];}if(service&&![PyHost isRunningServiceIdentifier:service[@"id"]]){[owner changeService:service enabled:YES completion:^(NSError *error){if(error){[owner showServiceError:error.localizedDescription];return;}[owner fetchSubscription:key silent:NO];}];}else[owner fetchSubscription:key silent:NO];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];
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
    page.onRestart=^(void (^completion)(NSError *)){RootViewController *owner=weakSelf;if(!owner){if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:10 userInfo:@{NSLocalizedDescriptionKey:@"服务页面已关闭，重启未完成。"}]);return;}NSDictionary *current=nil;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:builtinID]){current=service;break;}if(!current){if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:1 userInfo:@{NSLocalizedDescriptionKey:@"找不到 YSP Live 服务，请从资源页重新导入。"}]);return;}[owner restartMediaService:current completion:completion];};
    page.subscriptionCountProvider=^{return weakSelf.subscriptionURLs.count;};
    [page updateRunning:[PyHost isRunningServiceIdentifier:builtinID] subscriptionCount:self.subscriptionURLs.count];
    [self.navigationController pushViewController:page animated:YES];
}

- (void)openSettingsPage {
    [self.navigationController pushViewController:[self makeSettingsPage] animated:YES];
}

// 应用内字号：以系统字号为基准上调 0/1/2 档。覆盖写在 RootViewController 上后，
// 以系统字号为基准上调 0/1/2 档。基准必须取自未被覆盖的字号：
// window 自身的 trait 不受本控制器上写的覆盖影响；viewDidLoad 时
// view 尚未进 window，取启动时快照的系统档位。切忌用 self.traitCollection
// 作基准——它已被上次覆盖改写，每次重算都在已上调的档位上再上调，
// “大”和“特大”都会顶到最大档。超出范围时按最大档截断。
- (UITraitCollection *)fontSizeOverrideTraitCollection {
    NSInteger offset=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.appFontSize.v1"]?[[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.appFontSize.v1"]:0;
    if(offset<=0)return nil;
    NSArray<NSString *> *ordered=@[UIContentSizeCategoryExtraSmall,UIContentSizeCategorySmall,UIContentSizeCategoryMedium,UIContentSizeCategoryLarge,UIContentSizeCategoryExtraLarge,UIContentSizeCategoryExtraExtraLarge,UIContentSizeCategoryExtraExtraExtraLarge];
    // 基准取 iOS 系统字号（屏幕 trait，不受本控制器覆盖影响，且 view 未进
    // window 时也能取到）；不能取 self.traitCollection（已被覆盖）或
    // self.view.window（view 未进 window 时为 nil）。
    NSString *baseCategory=[UIScreen mainScreen].traitCollection.preferredContentSizeCategory;
    if(!baseCategory.length)return nil;
    NSInteger index=[ordered indexOfObject:baseCategory];
    if(index==NSNotFound)return nil;
    NSInteger stepped=MIN((NSInteger)ordered.count-1,index+offset);
    return [UITraitCollection traitCollectionWithPreferredContentSizeCategory:ordered[stepped]];
}
- (void)applyFontSizeOverride {
    UITraitCollection *override=[self fontSizeOverrideTraitCollection];
    if(self.navigationController)[self.navigationController setOverrideTraitCollection:override forChildViewController:self];
    UIViewController *top=self.navigationController.topViewController;
    if(top&&top!=self)[self.navigationController setOverrideTraitCollection:override forChildViewController:top];
    for(UIViewController *child in self.childViewControllers){[self setOverrideTraitCollection:override forChildViewController:child];}
    for(UIViewController *page in self.tabPages.allValues){if(page.parentViewController==self)[self setOverrideTraitCollection:override forChildViewController:page];}
    [self.table reloadData];[self.channelGrid reloadData];
}
- (void)updateLiveScreenAwakeState {
    BOOL isPlaying=self.currentPlayer!=nil||self.avPlayer!=nil||self.cicadaPlayer!=nil;
    BOOL keepAwake=isPlaying && CCTVBoolPreference(@"cctv.mediaKeepScreenAwake",YES);
    if(self.activeTab<2){
        UIApplication.sharedApplication.idleTimerDisabled=keepAwake;
    }
}
- (void)reloadThemeAppearance {
    self.view.backgroundColor=HostBackground();
    self.view.tintColor=HostAccent();
    self.bottomBar.tintColor=HostAccent();
    self.bottomBarBackdrop.backgroundColor=UIColor.clearColor;
    self.bottomDockFadeGradient.colors=@[(id)[HostBackground() colorWithAlphaComponent:0.0].CGColor,(id)[HostBackground() colorWithAlphaComponent:0.78].CGColor,(id)[HostBackground() colorWithAlphaComponent:0.96].CGColor];
    self.bottomDockGlass.effect=HostGlassBlur();
    HostSetLayerBorderColor(self.bottomDockGlass,HostBorder());
    self.catalogFloatingAirPlayPicker.activeTintColor=HostAccent();
    self.groupControl.tintColor=HostAccent();
    self.groupControl.selectedSegmentTintColor=HostAccent();
    self.playerTabs.selectedSegmentTintColor=HostAccent();
    [self updateLiveResourceCapsule];
    for(NSInteger i=0;i<self.bottomBar.arrangedSubviews.count;i++){
        UIButton *b=(UIButton *)self.bottomBar.arrangedSubviews[i];
        BOOL selected=i==self.activeTab;
        b.selected=selected;
        UIButtonConfiguration *cfg=b.configuration;
        cfg.baseForegroundColor=selected?HostOnAccent():HostMutedText();
        cfg.background.backgroundColor=selected?HostAccent():UIColor.clearColor;
        cfg.background.strokeColor=selected?[HostAccent() colorWithAlphaComponent:0.35]:UIColor.clearColor;
        b.configuration=cfg;
    }
    HostStyleNavigation(self.navigationController);
    [self.table reloadData];
    [self.channelGrid reloadData];
    [self.view setNeedsLayout];
    UIWindow *window=self.view.window;
    if(window)HostRefreshAppearanceLayers(window);
    for(UIViewController *child in self.childViewControllers){
        if([child respondsToSelector:@selector(reloadThemeAppearance)]){
            ((void (*)(id, SEL))[child methodForSelector:@selector(reloadThemeAppearance)])(child, @selector(reloadThemeAppearance));
        }
    }
    for(UIViewController *page in self.tabPages.allValues){
        if((page.parentViewController==self || page.isViewLoaded) && [page respondsToSelector:@selector(reloadThemeAppearance)]){
            ((void (*)(id, SEL))[page methodForSelector:@selector(reloadThemeAppearance)])(page, @selector(reloadThemeAppearance));
        }
    }
    for(UIViewController *vc in self.navigationController.viewControllers){
        if(vc!=self && vc.isViewLoaded && [vc respondsToSelector:@selector(reloadThemeAppearance)]){
            ((void (*)(id, SEL))[vc methodForSelector:@selector(reloadThemeAppearance)])(vc, @selector(reloadThemeAppearance));
        }
    }
    if(self.resourceImportWorkflow && self.resourceImportWorkflow.isViewLoaded && [self.resourceImportWorkflow respondsToSelector:@selector(reloadThemeAppearance)]){
        [self.resourceImportWorkflow reloadThemeAppearance];
    }
}
- (SettingsViewController *)makeSettingsPage {
    SettingsViewController *page=[SettingsViewController new];
    __weak typeof(self) weakSelf=self;
    page.onExportData=^{[weakSelf exportLocalConfiguration];};page.onImportData=^{[weakSelf importLocalConfiguration];};page.onOpenLog=^{[weakSelf openDiagnosticLog];};
    page.onOpenDiagnostics=^{[weakSelf.navigationController pushViewController:[[RuntimeDiagnosticsViewController alloc] initWithSessionID:nil] animated:YES];};
    page.onMediaDisplaySettings=^{RootViewController *owner=weakSelf;if(!owner)return;MediaBrowserViewController *browser=[owner mediaPageCreatingIfNeeded];UIViewController *configuration=[browser mediaDisplaySettingsViewController];if(configuration)[owner.navigationController pushViewController:configuration animated:YES];};
    page.onClearEPG=^{ [[XMLTVStore shared] clear];[weakSelf.epgCache removeAllObjects]; [weakSelf saveEPGCache]; [weakSelf.table reloadData]; };
    page.onClearWatchHistory=^{[weakSelf.recents removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"recents"];[weakSelf applyFilter];};
    page.onClearFavorites=^{[weakSelf.favorites removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"favorites"];[weakSelf configureCatalogNavigation];[weakSelf applyFilter];};
    page.onOpenTab=^(NSInteger tab){if(tab<0||tab>=weakSelf.bottomBar.arrangedSubviews.count)return;[weakSelf selectBottomTab:(UIButton *)weakSelf.bottomBar.arrangedSubviews[tab]];};
    page.onOpenServices=^{[weakSelf openServicesPage];};
    page.onIntegerPreferenceChanged=^(NSString *key, NSInteger value){
        if([key isEqualToString:@"cctv.channelGridColumns.v1"]){weakSelf.gridColumns=value==3?3:4;[weakSelf configureCatalogNavigation];[weakSelf.channelGrid.collectionViewLayout invalidateLayout];[weakSelf.channelGrid reloadData];[weakSelf.view setNeedsLayout];}
        if([key isEqualToString:@"cctv.channelSortMode.v1"]){weakSelf.channelSortMode=value==1?1:0;[weakSelf configureCatalogNavigation];[weakSelf applyFilter];}
        if([key isEqualToString:@"cctv.mediaGridColumns.v1"]){MediaBrowserViewController *browser=(MediaBrowserViewController *)weakSelf.tabPages[@2];if(browser)[browser reloadMediaDisplayConfigurationIfLoaded];}
        if([key isEqualToString:@"cctv.appFontSize.v1"]){[weakSelf applyFontSizeOverride];}
    };
    page.onPreferenceChanged=^(NSString *key, BOOL value){
        if([key isEqualToString:HostDarkThemePreferenceKey]||[key isEqualToString:HostThemeModePreferenceKey]||[key isEqualToString:HostThemePaletteIdentifierPreferenceKey]){
            UIWindow *window=weakSelf.view.window;
            HostApplyThemeToWindow(window);
            [weakSelf reloadThemeAppearance];
            dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostStyleNavigation(weakSelf.navigationController);HostRefreshAppearanceLayers(window);});
        }
        if ([key isEqualToString:@"runtimeDiagnosticsEnabled"]) [RuntimeDiagnostics.shared setEnabled:value];
        if ([key isEqualToString:@"nativeSDKVerboseLogs"]) [weakSelf configureSDKLogging];
        if ([key isEqualToString:@"preloadNativeChannel"] && !value) [weakSelf.nativePreloader cancel];
        if ([key isEqualToString:@"allowBackgroundAudio"]) [weakSelf activateAudioSession];
        if ([key isEqualToString:@"autoLoadEPG"]) { [weakSelf.epgTimer invalidate]; weakSelf.epgTimer=nil; weakSelf.epgRefreshDesired=value;if(value) [weakSelf restartEPGTimer]; else weakSelf.infoLabel.text=@"节目单自动获取已关闭"; }
        if ([key isEqualToString:@"nativeChannelsEnabled"]) { [weakSelf configureCatalogNavigation]; [weakSelf applyFilter]; [weakSelf updateLiveResourceCapsule]; }
        if ([key isEqualToString:@"channelGridMode"]) { weakSelf.gridMode=value; [weakSelf configureCatalogNavigation]; }
        if ([key isEqualToString:@"channelGridMode"]) { [weakSelf.channelGrid.collectionViewLayout invalidateLayout]; [weakSelf.channelGrid reloadData]; [weakSelf.view setNeedsLayout]; }
        if ([key isEqualToString:@"cctv.mediaKeepScreenAwake"]) { [weakSelf updateLiveScreenAwakeState]; }
        if ([key isEqualToString:@"autoPiP"]) { if (@available(iOS 14.2, *)) { weakSelf.pip.canStartPictureInPictureAutomaticallyFromInline = value; } }
        if ([key isEqualToString:@"cctv.mediaVideoGravity"]) {
            NSString *gravity=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
            if(weakSelf.avLayer)weakSelf.avLayer.videoGravity=gravity;
        }
        if ([key isEqualToString:@"resetDefaultPreferences"]) {
            weakSelf.gridMode=CCTVBoolPreference(@"channelGridMode",YES);
            weakSelf.gridColumns=4;
            weakSelf.channelSortMode=0;
            [RuntimeDiagnostics.shared setEnabled:NO];
            [weakSelf configureSDKLogging];
            [weakSelf activateAudioSession];
            [weakSelf applyFontSizeOverride];
            [weakSelf reloadThemeAppearance];
            [weakSelf configureCatalogNavigation];
            [weakSelf applyFilter];
            [weakSelf updateLiveScreenAwakeState];
            [weakSelf updateLiveResourceCapsule];
        }
    };
    return page;
}

- (void)exportLocalConfiguration {
    NSData *data=[NSJSONSerialization dataWithJSONObject:[HostBackup snapshot] options:NSJSONWritingPrettyPrinted error:NULL];NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"CCTVHost-configuration.json"];[data writeToFile:path atomically:YES];UIActivityViewController *v=[[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];v.popoverPresentationController.sourceView=self.bottomBar;v.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:v animated:YES completion:nil];
}
- (void)importLocalConfiguration {UIDocumentPickerViewController *v=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];v.delegate=self;[self presentViewController:v animated:YES completion:nil];}
- (void)downloadPackageURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    [self downloadPackageURL:url headers:nil runtimeHint:nil completion:completion];
}
- (void)downloadPackageURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSDictionary *,NSError *))completion {
    [self downloadPackageURL:url headers:headers runtimeHint:nil completion:completion];
}
- (void)downloadPackageURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers runtimeHint:(NSString *)runtimeHint completion:(void (^)(NSDictionary *,NSError *))completion {
    [self.packageDownloader cancel];MediaPackageDownloader *downloader=[MediaPackageDownloader new];self.packageDownloader=downloader;
    NSString *title=[runtimeHint isEqual:@"node"]?@"导入 Node.js Mobile 资源":([runtimeHint isEqual:@"python"]?@"导入 Python Spider":@"导入影视 / 插件资源");UIAlertController *progress=[UIAlertController alertControllerWithTitle:title message:@"准备下载…" preferredStyle:UIAlertControllerStyleAlert];
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
                [failure addAction:[UIAlertAction actionWithTitle:@"重新下载并校验" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner downloadPackageURL:url headers:headers runtimeHint:runtimeHint completion:completion];}]];
                [owner presentViewController:failure animated:YES completion:nil];return;
            }
            if(completion)completion(service,error);
        };
        if(owner.presentedViewController==weakProgress)[weakProgress dismissViewControllerAnimated:YES completion:done];else done();
    };
    [progress addAction:[UIAlertAction actionWithTitle:@"取消下载" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){[downloader cancel];finish(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
    downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){if(delivered||weakSelf.packageDownloader!=downloader)return;if(![lastStage isEqual:stage]){lastStage=stage;[RuntimeDiagnostics.shared recordEvent:@"resource_import_stage" category:@"import" fields:@{@"correlation_id":traceID, @"stage":stage, @"received_bytes":@(received), @"expected_bytes":@(expected)}];}NSString *amount=expected>0?[NSString stringWithFormat:@"%.2f / %.2f MB · %ld%%",received/1048576.0,expected/1048576.0,(long)MIN(100,received*100/expected)]:[NSString stringWithFormat:@"已接收 %.2f MB",received/1048576.0];weakProgress.message=[NSString stringWithFormat:@"%@\n%@\n导入完成后可选择启动，当前不会执行脚本。",stage,amount];};
    dispatch_block_t show=^{RootViewController *owner=weakSelf;if(!owner||owner.packageDownloader!=downloader||delivered)return;[owner presentViewController:progress animated:YES completion:^{if(!delivered)[downloader importURL:url headers:headers runtimeHint:runtimeHint completion:finish];}];};
    if(self.presentedViewController)[self.presentedViewController dismissViewControllerAnimated:YES completion:show];else show();
}
- (void)activateNativeFallbackForTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport {
    NSString *siteKey=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"";
    NSString *catalogID=[site[@"tvboxCatalogID"] isKindOfClass:NSString.class]?site[@"tvboxCatalogID"]:@"builtin-lytvs-ios";
    if(siteKey.length){
        NSMutableArray *keys=[([[NSUserDefaults standardUserDefaults] arrayForKey:@"cctv.nativeFallbackSiteKeys.v1"]?:@[]) mutableCopy];
        if(![keys containsObject:siteKey]){[keys addObject:siteKey];[[NSUserDefaults standardUserDefaults] setObject:keys.copy forKey:@"cctv.nativeFallbackSiteKeys.v1"];}
    }
    MediaBrowserViewController *mediaPage=[self mediaPageCreatingIfNeeded];
    [mediaPage refreshSources];
    if(browseAfterImport){
        NSString *targetID=[NSString stringWithFormat:@"jar-bridge:%@:%@",catalogID,siteKey];
        [NSUserDefaults.standardUserDefaults setObject:catalogID forKey:@"selectedMediaCatalogID"];
        [NSUserDefaults.standardUserDefaults setObject:targetID forKey:@"selectedMediaSource"];
        [self selectBottomTab:(id)self.bottomBar.arrangedSubviews[2]];
        [mediaPage refreshSources];
        for(NSDictionary *src in (mediaPage.sourcesProvider?mediaPage.sourcesProvider():@[])){
            if([src[@"id"] isEqual:targetID]){
                [mediaPage activate:src keepingHome:YES];
                break;
            }
        }
    }
}
- (void)importTVBoxSite:(NSDictionary *)site { [self importTVBoxSite:site browseAfterImport:NO]; }
- (void)importTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport {
    NSString *siteKey=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"";
    NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
    if(browseAfterImport&&(siteKey.length||api.length)){
        for(NSDictionary *existing in [ServiceStore services]){
            if(![ServiceStore isVODMediaService:existing])continue;
            NSArray *keys=[existing[@"tvboxSiteKeys"] isKindOfClass:NSArray.class]?existing[@"tvboxSiteKeys"]:@[];
            BOOL matchesKey=siteKey.length&&([existing[@"tvboxSiteKey"] isEqual:siteKey]||[keys containsObject:siteKey]);
            BOOL matchesURL=api.length&&[existing[@"url"] isKindOfClass:NSString.class]&&[existing[@"url"] isEqual:api];
            if(matchesKey||matchesURL){
                [self usePluginService:existing kind:@"vod"];
                return;
            }
        }
    }
    NSString *lowAPI=api.lowercaseString;
    if([lowAPI containsString:@"drpy2.min.js"]||[lowAPI containsString:@"3e7e0c8a023b624cec6bdcc200f06f02.js"]){
        [self activateNativeFallbackForTVBoxSite:site browseAfterImport:browseAfterImport];
        return;
    }
    if([api containsString:CCTVTVBoxTokenPlaceholder]){
        NSString *token=CCTVTVBoxStoredSubscriptionToken();
        if(!token.length){
            if(browseAfterImport){
                [self activateNativeFallbackForTVBoxSite:site browseAfterImport:YES];
                return;
            }
            UIAlertController *credential=[UIAlertController alertControllerWithTitle:@"Hawk iOS 资源访问令牌" message:@"此合集的内部站点需要订阅令牌。粘贴 token，或粘贴原始订阅链接；令牌会保存到本机钥匙串供后续站点使用。" preferredStyle:UIAlertControllerStyleAlert];
            [credential addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"token 或完整订阅链接";field.secureTextEntry=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.clearButtonMode=UITextFieldViewModeWhileEditing;}];
            [credential addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            __weak typeof(self) weakSelf=self;
            [credential addAction:[UIAlertAction actionWithTitle:@"直接原生加载（免令牌）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(owner)[owner activateNativeFallbackForTVBoxSite:site browseAfterImport:YES];}]];
            [credential addAction:[UIAlertAction actionWithTitle:@"保存并继续" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(!owner)return;NSString *entered=CCTVTVBoxTokenFromInput(credential.textFields.firstObject.text?:@"");if(!entered.length){[owner showServiceError:@"请输入有效的订阅令牌或完整订阅链接"];return;}if(!CCTVTVBoxSaveSubscriptionToken(entered)){[owner showServiceError:@"令牌未能保存到本机钥匙串，请检查设备设置后重试"];return;}NSString *resolvedURL=CCTVTVBoxURLByResolvingToken(api,entered);if(!resolvedURL.length){[owner showServiceError:@"无法将订阅令牌应用到此站点地址"];return;}NSMutableDictionary *resolvedSite=[site mutableCopy];resolvedSite[@"api"]=resolvedURL;dispatch_async(dispatch_get_main_queue(),^{[owner importTVBoxSite:resolvedSite browseAfterImport:browseAfterImport];});}]];
            [self presentViewController:credential animated:YES completion:nil];return;
        }
        api=CCTVTVBoxURLByResolvingToken(api,token);if(!api.length){[self activateNativeFallbackForTVBoxSite:site browseAfterImport:browseAfterImport];return;}NSMutableDictionary *resolvedSite=[site mutableCopy];resolvedSite[@"api"]=api;site=resolvedSite;
    }
    if(!api.length){[self showServiceError:@"此 TVBox 站点没有可导入的脚本地址"];return;}
    NSURL *downloadURL=CCTVURLFromPossiblyUnescapedString(api);
    if(!downloadURL){[self activateNativeFallbackForTVBoxSite:site browseAfterImport:browseAfterImport];return;}
    self.pendingTVBoxExt=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";self.pendingTVBoxSiteName=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"";
    __weak typeof(self) weakSelf=self;
    NSString *runtimeHint=[[downloadURL pathExtension].lowercaseString isEqual:@"py"]?@"python":nil;
    [self downloadPackageURL:downloadURL headers:site[@"header"] runtimeHint:runtimeHint completion:^(NSDictionary *service,NSError *error){RootViewController *owner=weakSelf;owner.navigationItem.prompt=nil;if(error){owner.pendingTVBoxExt=nil;owner.pendingTVBoxSiteName=nil;if(browseAfterImport||error.code!=NSURLErrorCancelled)[owner activateNativeFallbackForTVBoxSite:site browseAfterImport:browseAfterImport];return;}if(!service){[owner activateNativeFallbackForTVBoxSite:site browseAfterImport:browseAfterImport];return;}NSMutableDictionary *updated=[service mutableCopy];NSMutableDictionary *manifest=[service[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"",*name=[site[@"name"] isKindOfClass:NSString.class]?site[@"name"]:@"";if(ext.length)manifest[@"options"]=ext;if(name.length){manifest[@"name"]=name;updated[@"name"]=name;}updated[@"manifest"]=manifest;updated[@"tvboxSiteKey"]=site[@"key"]?:@"";updated[@"tvboxSiteKeys"]=@[site[@"key"]?:@""];if(site[@"tvboxCatalogID"])updated[@"tvboxCatalogID"]=site[@"tvboxCatalogID"];if(site[@"playUrl"])updated[@"tvboxPlayURL"]=site[@"playUrl"];if(site[@"header"])updated[@"tvboxSiteHeader"]=site[@"header"];owner.pendingTVBoxExt=nil;owner.pendingTVBoxSiteName=nil;[owner acceptImportedMedia:updated error:nil autoBrowse:browseAfterImport];}];
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
    NSDictionary *manifest=[service[@"manifest"] isKindOfClass:NSDictionary.class]?service[@"manifest"]:@{};NSString *runtime=[manifest[@"runtime"] isKindOfClass:NSString.class]?manifest[@"runtime"]:([service[@"engine"] isKindOfClass:NSString.class]?service[@"engine"]:@"");NSString *protocol=[manifest[@"protocol"] isKindOfClass:NSString.class]?manifest[@"protocol"]:([service[@"protocol"] isKindOfClass:NSString.class]?service[@"protocol"]:@"");NSArray *capabilities=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:([manifest[@"capabilities"] isKindOfClass:NSArray.class]?manifest[@"capabilities"]:@[]);NSString *capabilityStatus=capabilities.count?[NSString stringWithFormat:@"声明能力：%@",[capabilities componentsJoinedByString:@"、"]]:@"能力待测：启动后查询插件的 capabilities()，导入阶段不会执行代码。";NSString *kind=([ServiceStore isVODMediaService:service]?@"影视":([ServiceStore subscriptionURLForService:service].length||[ServiceStore isLiveMediaService:service]?@"直播":@"待启动探测资源类型"));
    NSString *message=[NSString stringWithFormat:@"已检查并导入 %@。\n识别类型：%@ · %@\n资源分类：%@\n%@\n%@",service[@"name"],CCTVImportRuntimeLabel(runtime),CCTVImportProtocolLabel(protocol),kind,capabilityStatus,verification];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"资源已导入" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"启动并浏览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSString *kind=[ServiceStore isVODMediaService:service]?@"vod":([ServiceStore subscriptionURLForService:service].length?@"live":@"configuration");[self usePluginService:service kind:kind];}]];
    [alert addAction:[UIAlertAction actionWithTitle:@"查看能力与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self openPluginResource:[@"plugin:" stringByAppendingString:service[@"id"]]];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject;if(!url)return;
    BOOL scoped=[url startAccessingSecurityScopedResource];self.navigationItem.prompt=@"正在读取本机配置…";__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *readError=nil;NSData *data=nil;NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:&readError];
        @try{if(file)data=[file readDataUpToLength:32*1024*1024+1 error:&readError];}
        @catch(NSException *exception){readError=[NSError errorWithDomain:@"CCTVHostBackup" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法读取所选配置文件"}];}
        @finally{[file closeAndReturnError:NULL];if(scoped)[url stopAccessingSecurityScopedResource];}
        if(data.length>32*1024*1024){data=nil;readError=[NSError errorWithDomain:@"CCTVHostBackup" code:2 userInfo:@{NSLocalizedDescriptionKey:@"配置文件超过 32 MiB 上限"}];}
        dispatch_async(dispatch_get_main_queue(),^{RootViewController *owner=weakSelf;if(!owner)return;owner.navigationItem.prompt=nil;if(readError)[owner showServiceError:readError.localizedDescription];else[owner finishConfigurationImport:data];});
    });
}
- (void)finishConfigurationImport:(NSData *)data {
    NSError *error=nil;NSDictionary *backup=[HostBackup validatedBackup:data error:&error];if(!backup){[self showServiceError:error.localizedDescription];return;}
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"导入本机配置" message:@"将替换本机订阅、收藏和偏好。Python 服务代码单独导入，不受影响。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"导入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        for(NSString *source in self.subscriptionURLs.allObjects){self.subscriptionRequestVersions[source]=@([self.subscriptionRequestVersions[source] unsignedIntegerValue]+1);[self removeSubscriptionSource:source];}
        [HostBackup restore:backup];self.subscriptionURLs=[NSMutableSet setWithArray:backup[@"subscriptions"]];self.favorites=[backup[@"favorites"] mutableCopy];self.recents=[[NSUserDefaults.standardUserDefaults arrayForKey:@"recents"] mutableCopy];self.activeSource=nil;self.gridMode=CCTVBoolPreference(@"channelGridMode",YES);for(NSString *source in self.subscriptionURLs)[self fetchSubscription:source silent:YES];[self activateAudioSession];[self applyFilter];[self selectBottomTab:(UIButton *)self.bottomBar.arrangedSubviews.firstObject];
        // 备份里的主题与字号刚恢复：立即应用到窗口并重刷可见页面，
        // 否则要等下次启动才生效。
        UIWindow *window=self.view.window;if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);HostRefreshAppearanceLayers(window);}[self applyFontSizeOverride];[self.table reloadData];[self.view setNeedsLayout];
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
    NSArray *groups=[self currentCatalogGroupTitles];
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSSet *favoriteIDs=[NSSet setWithArray:self.favorites?:@[]];
    NSSet *recentIDs=[NSSet setWithArray:[self.recents valueForKey:@"id"]?:@[]];
    NSMutableDictionary<NSString *,NSNumber *> *counts=[NSMutableDictionary dictionary];
    for(NSDictionary *channel in self.allChannels){
        BOOL remote=[channel[@"remoteURL"] length]>0;
        if(!remote&&(!CCTVBoolPreference(@"nativeChannelsEnabled",YES)||self.activeSource.length))continue;
        if(remote){NSMutableSet *owners=[NSMutableSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])];[owners minusSet:disabled];if(!owners.count||(self.activeSource.length&&![owners containsObject:self.activeSource]))continue;}
        NSString *cid=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
        if([favoriteIDs containsObject:cid])counts[@"收藏"]=@([counts[@"收藏"] unsignedIntegerValue]+1);
        if([recentIDs containsObject:cid])counts[@"最近"]=@([counts[@"最近"] unsignedIntegerValue]+1);
        if(remote!=self.subscriptionCatalog)continue;
        NSString *query=self.query.lowercaseString;NSString *name=[channel[@"name"] isKindOfClass:NSString.class]?channel[@"name"]:@"";
        if(query.length && ![name.lowercaseString containsString:query] && ![cid.lowercaseString containsString:query])continue;
        counts[@"全部"]=@([counts[@"全部"] unsignedIntegerValue]+1);
        NSString *group=[channel[@"group"] isKindOfClass:NSString.class]?channel[@"group"]:@"其他";
        if([group isEqualToString:@"熊猫"])group=@"央视";
        if(self.subscriptionCatalog&&![@[@"央视",@"卫视",@"地方"] containsObject:group])group=@"其他";
        counts[group]=@([counts[group] unsignedIntegerValue]+1);
    }
    NSDictionary<NSString *,NSString *> *groupIcons=@{@"全部":@"square.grid.2x2",@"央视":@"tv.fill",@"卫视":@"sparkles.tv",@"地方":@"map.fill",@"教育":@"book.fill",@"其他":@"rectangle.stack.fill",@"收藏":@"heart.fill",@"最近":@"clock.arrow.circlepath"};
    NSMutableArray *rows=[NSMutableArray array];for(NSUInteger i=0;i<groups.count;i++){NSString *group=groups[i];[rows addObject:@{@"index":@(i),@"title":group,@"detail":[NSString stringWithFormat:@"%lu 个频道",(unsigned long)[counts[group] unsignedIntegerValue]],@"selected":@(self.groupControl.selectedSegmentIndex==(NSInteger)i),@"symbol":groupIcons[group]?:@"folder"}];}return rows;
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
    NSString *logo=[channel[@"logo"] isKindOfClass:NSString.class]?channel[@"logo"]:@"";NSString *identifier=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";self.playerChannelLogo.hidden=channel==nil;
    if(logo.length){self.playerChannelLogo.image=nil;self.playerChannelLogo.accessibilityIdentifier=logo;self.playerChannelLogo.backgroundColor=UIColor.clearColor;self.playerChannelLogo.layer.cornerRadius=0;self.playerChannelLogo.clipsToBounds=NO;}
    else{self.playerChannelLogo.image=channel?CCTVChannelLogoImage(channel):nil;self.playerChannelLogo.accessibilityIdentifier=identifier.length?[@"channel-logo:" stringByAppendingString:identifier]:@"";BOOL dark=CCTVChannelLogoNeedsDarkBacking(identifier);self.playerChannelLogo.backgroundColor=dark?[UIColor colorWithWhite:.10 alpha:1]:UIColor.clearColor;self.playerChannelLogo.layer.cornerRadius=dark?5:0;self.playerChannelLogo.clipsToBounds=dark;}
}
- (void)loadPlayerChannelLogoAfterFirstFrame {
    NSString *url=self.playerChannelLogo.accessibilityIdentifier;if([NSURL URLWithString:url].host.length&&self.firstRender)[[HostImageLoader shared] loadURL:url intoImageView:self.playerChannelLogo];
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
    for(NSString *source in [ProfileStore orderedSources:CCTVStringArrayValue(channel[@"subscriptionSources"])]){NSString *identifier=[ProfileStore metadata:source][@"managedServiceID"];if(![identifier isKindOfClass:NSString.class]||!identifier.length)continue;for(NSDictionary *service in [ServiceStore services])if([service[@"id"] isEqual:identifier]&&[service[@"port"] integerValue]==port)owners[identifier]=service;}
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
    if([ServiceStore isMediaService:service]){
        BOOL portBusy=NO;NSMutableSet *usedPorts=[NSMutableSet setWithObjects:@8767,@18770,nil];
        for(NSDictionary *other in [ServiceStore services]){if([other[@"id"] isEqual:serviceID])continue;NSInteger otherPort=[other[@"port"] integerValue];if(otherPort>0)[usedPorts addObject:@(otherPort)];if(otherPort==port)portBusy=YES;}
        if(portBusy||HostLocalPortState((int)port)==1){
            NSInteger nextPort=18780;while(([usedPorts containsObject:@(nextPort)]||HostLocalPortState((int)nextPort)==1)&&nextPort<65535)nextPort++;
            NSMutableDictionary *reassigned=[service mutableCopy];reassigned[@"port"]=@(nextPort);[ServiceStore save:reassigned];service=[ServiceStore resolvedService:reassigned];port=nextPort;
        }
    }
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
        if(![newMetadata[@"epgURL"] isKindOfClass:NSString.class]||![newMetadata[@"epgURL"] length])for(NSString *oldSource in previousSources){id configured=[ProfileStore metadata:oldSource][@"epgURL"];if([ProfileStore isHTTP:configured]){sourceMetadata[@"epgURL"]=[ServiceStore rewrittenLoopbackURL:configured forService:service];break;}}if(![newMetadata[@"detectedEPGURL"] isKindOfClass:NSString.class]||![newMetadata[@"detectedEPGURL"] length])for(NSString *oldSource in previousSources){id detected=[ProfileStore metadata:oldSource][@"detectedEPGURL"];if([ProfileStore isHTTP:detected]){sourceMetadata[@"detectedEPGURL"]=[ServiceStore rewrittenLoopbackURL:detected forService:service];break;}}
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
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        __block NSError *error=nil;BOOL stopped=[PyHost stopServiceIdentifier:identifier error:&error];
        int portState=stopped?HostLocalPortState([snapshot[@"port"] intValue]):-1;
        if(stopped&&portState!=0)error=failure(portState==1?@"旧服务停止后端口仍可访问，已阻止重复启动。请检查是否有其他服务占用该端口。":@"无法确认旧端口已释放，已阻止重复启动。请稍后重试。 ");
        if(!stopped&&!error)error=failure(@"服务停止未确认，已取消重新启动。请查看该服务日志。 ");
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;
            if(!owner){if(completion)completion(error?:failure(@"页面已关闭，重启未完成。"));return;}
            BOOL unchanged=NO;for(NSDictionary *candidate in ServiceStore.services)if([candidate[@"id"] isEqual:identifier]){unchanged=[candidate isEqualToDictionary:snapshot];break;}
            if(stopped){[owner logPluginLine:@"重启前旧服务已停止" identifier:identifier name:snapshot[@"name"]?:identifier];[PluginLogStore.shared finishRunForIdentifier:identifier status:@"重启前已停止"];}
            if(!error&&!unchanged)error=failure(@"重启期间资源配置已变更，已取消启动。请重新选择来源。 ");
            if(!error){[owner clearServiceLogHandlers:identifier];NSError *startError=nil;if(![owner startService:snapshot error:&startError])error=startError?:failure(@"重新启动请求失败，请查看服务日志。 ");}
            [owner.serviceOperations removeObject:identifier];
            [RuntimeDiagnostics.shared recordEvent:@"service_recovery_finished" category:@"service" fields:@{@"service_id":identifier,@"phase":@"start_request_finished",@"http_health_verified":@NO,@"stop_confirmed":@(stopped),@"port_released":@(stopped&&portState==0),@"start_accepted":@(!error),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];
            [owner refreshConfigurationPage];if(completion)completion(error);
        });
    });
}
- (void)changeService:(NSDictionary *)service enabled:(BOOL)enabled completion:(void (^)(NSError *))completion {
    NSString *serviceID=service[@"id"]?:@"";if(!self.serviceOperations)self.serviceOperations=[NSMutableSet set];
    if([self.serviceOperations containsObject:serviceID]){if(completion)completion([NSError errorWithDomain:@"CCTVHostService" code:4 userInfo:@{NSLocalizedDescriptionKey:@"该服务正在启停，请稍候。"}]);return;}
    if(enabled && [PyHost isRunningServiceIdentifier:serviceID]){
        int port=[service[@"port"] intValue];
        if(port>0 && HostLocalPortState(port)==0){
            [PyHost refreshListenersAfterForeground];
            [NSThread sleepForTimeInterval:0.12];
            if(HostLocalPortState(port)==0){
                [self restartMediaService:service completion:completion];
                return;
            }
        }
        [self refreshConfigurationPage];if(completion)completion(nil);return;
    }
    if(enabled){
        if(![PyHost isRunningServiceIdentifier:serviceID] && [PyHost isManagedServiceIdentifier:serviceID]){
            [self restartMediaService:service completion:completion];
            return;
        }
        NSError *error=nil;BOOL started=[self startService:service error:&error];
        [RuntimeDiagnostics.shared recordEvent:started?@"service_start_accepted":@"service_start_failed" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0, @"start_phase":started?@"request_accepted":@"rejected", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];
        [self refreshConfigurationPage];if(completion)completion(error);return;
    }
    [self.serviceOperations addObject:serviceID];
    [RuntimeDiagnostics.shared recordEvent:@"service_stop_requested" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0}];
    [self log:@"正在停止服务 %@",service[@"name"]];
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *stopError=nil;BOOL stopped=[PyHost stopServiceIdentifier:serviceID error:&stopError];
        dispatch_async(dispatch_get_main_queue(),^{
            RootViewController *owner=weakSelf;
            if(!owner){if(completion)completion(stopped?nil:stopError);return;}
            [owner.serviceOperations removeObject:serviceID];[RuntimeDiagnostics.shared recordEvent:stopped?@"service_stopped":@"service_stop_failed" category:@"service" fields:@{@"service_id":serviceID, @"service_name":service[@"name"]?:@"", @"engine":service[@"engine"]?:@"python", @"port":service[@"port"]?:@0, @"error_domain":stopError.domain?:@"", @"error_code":@(stopError.code), @"error_message":stopError.localizedDescription?:@""}];if(!stopped){if(completion)completion(stopError);[owner refreshConfigurationPage];return;}
            [owner completeServiceStopForIdentifier:serviceID];[owner refreshConfigurationPage];if(completion)completion(nil);
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
        self.titleLabel.hidden = NO;
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (![self.titleLabel.text isEqualToString:self.channelName]) return;
            if (self.firstRender && !self.nativeTimeShiftActive && !self.nativePlaybackFailed && !self.remotePlaybackFailed) {
                self.titleLabel.hidden = YES;
                self.infoLabel.hidden = YES;
                self.playerTopScrim.hidden = YES;
                self.playerBottomScrim.hidden = YES;
            } else {
                self.controlBar.hidden = NO;
            }
        });
    }
}

- (void)setupRemoteCommands {
    // 用 target-action 而不用 addTargetWithHandler:：后者的 block 会被
    // MPRemoteCommandCenter 单例强引用，进而永久强引用 self，使 dealloc
    // 永远走不到、dealloc 里的 KVO 拆除也永远执行不了。target-action 配合
    // dealloc 中的 removeTarget: 才能正常释放。
    // 注意：MPRemoteCommand 的 action 只接受两种签名——返回
    // MPRemoteCommandHandlerStatus，或第二个参数为 completion handler。
    // void 无参的 togglePlayPause 会在 addTarget 时直接抛
    // NSInternalInconsistencyException（“Unsupported action method
    // signature”）导致启动即崩溃，故用下面的薄包装转发。
    MPRemoteCommandCenter *c = MPRemoteCommandCenter.sharedCommandCenter;
    [c.playCommand removeTarget:self];
    [c.pauseCommand removeTarget:self];
    [c.nextTrackCommand removeTarget:self];
    [c.previousTrackCommand removeTarget:self];
    [c.playCommand addTarget:self action:@selector(togglePlayPauseForRemoteCommand:)];
    [c.pauseCommand addTarget:self action:@selector(togglePlayPauseForRemoteCommand:)];
    [c.nextTrackCommand addTarget:self action:@selector(stepToNextChannelForRemoteCommand:)];
    [c.previousTrackCommand addTarget:self action:@selector(stepToPreviousChannelForRemoteCommand:)];
}

- (MPRemoteCommandHandlerStatus)togglePlayPauseForRemoteCommand:(MPRemoteCommandEvent *)event {
    [self togglePlayPause];
    return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)stepToNextChannelForRemoteCommand:(MPRemoteCommandEvent *)event {
    // 锁屏 / 耳机 / 车载的下一首即下一个频道；与播放暂停用同一签名要求。
    [self playAdjacentChannel:1];
    return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)stepToPreviousChannelForRemoteCommand:(MPRemoteCommandEvent *)event {
    [self playAdjacentChannel:-1];
    return MPRemoteCommandHandlerStatusSuccess;
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
    [self trimEPGCache];
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
    NSUInteger row = [self.shownChannels indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"id"] isEqualToString:cid ?: @""]; }];
    if (row == NSNotFound) return nil;
    return [NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
}

#pragma mark - 台标

- (void)loadLogo:(NSString *)url into:(UIImageView *)iv {
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

- (void)enableNativeChannelsFromEmptyState {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"nativeChannelsEnabled"];
    self.activeSource = nil;
    self.favoritesOnly = NO;
    self.recentsOnly = NO;
    self.groupControl.selectedSegmentIndex = 0;
    [self configureCatalogNavigation];
    [self applyFilter];
    [self updateLiveResourceCapsule];
}

- (void)resetCatalogFilterToAll {
    self.favoritesOnly = NO;
    self.recentsOnly = NO;
    self.query = @"";
    self.searchController.searchBar.text = @"";
    self.groupControl.selectedSegmentIndex = 0;
    [self configureCatalogNavigation];
    [self applyFilter];
}

- (UIView *)buildCatalogEmptyBackgroundViewWithMessage:(NSString *)message {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 260)];
    container.backgroundColor = UIColor.clearColor;
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-12],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:28],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-28]
    ]];
    NSString *symbolName = self.query.length ? @"magnifyingglass" : (self.recentsOnly ? @"clock.arrow.circlepath" : (self.favoritesOnly ? @"heart.slash" : (self.subscriptionCatalog ? @"dot.radiowaves.left.and.right" : @"tv.slash")));
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium]]];
    iconView.tintColor = HostMutedText();
    [stack addArrangedSubview:iconView];
    UILabel *hint = [UILabel new];
    hint.text = message;
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.textColor = HostSecondaryText();
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    hint.adjustsFontForContentSizeCategory = YES;
    [stack addArrangedSubview:hint];
    UIButton *actionButton = nil;
    if (!self.subscriptionCatalog && !CCTVBoolPreference(@"nativeChannelsEnabled", YES)) {
        actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"  立即启用官方频道  " forState:UIControlStateNormal];
        HostStylePillButton(actionButton, YES);
        actionButton.accessibilityIdentifier = @"catalog.empty.enable-native";
        [actionButton addTarget:self action:@selector(enableNativeChannelsFromEmptyState) forControlEvents:UIControlEventTouchUpInside];
    } else if (self.favoritesOnly || self.recentsOnly || self.query.length || self.groupControl.selectedSegmentIndex > 0) {
        actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"  查看全部频道  " forState:UIControlStateNormal];
        HostStylePillButton(actionButton, NO);
        actionButton.accessibilityIdentifier = @"catalog.empty.reset-filter";
        [actionButton addTarget:self action:@selector(resetCatalogFilterToAll) forControlEvents:UIControlEventTouchUpInside];
    } else if (self.subscriptionCatalog) {
        actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [actionButton setTitle:@"  添加直播订阅  " forState:UIControlStateNormal];
        HostStylePillButton(actionButton, YES);
        actionButton.accessibilityIdentifier = @"catalog.empty.add-subscription";
        [actionButton addTarget:self action:@selector(addSubscription) forControlEvents:UIControlEventTouchUpInside];
    }
    if (actionButton) {
        [actionButton.heightAnchor constraintGreaterThanOrEqualToConstant:38].active = YES;
        [stack addArrangedSubview:actionButton];
    }
    return container;
}

- (void)applyFilter {
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    NSArray *groups = [self currentCatalogGroupTitles];
    NSInteger idx = self.groupControl.selectedSegmentIndex;
    NSString *selectedGroup = (idx >= 0 && idx < (NSInteger)groups.count) ? groups[idx] : @"全部";
    BOOL isRecentsSegment = self.recentsOnly || [selectedGroup isEqualToString:@"最近"];
    BOOL isFavoritesSegment = !isRecentsSegment && (self.favoritesOnly || [selectedGroup isEqualToString:@"收藏"]);
    NSArray *base=[self.allChannels filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *bindings){
        BOOL remote=[c[@"remoteURL"] length]>0;
        if(!self.favoritesOnly && !isFavoritesSegment && !isRecentsSegment && remote!=self.subscriptionCatalog)return NO;
        if(!remote)return CCTVBoolPreference(@"nativeChannelsEnabled",YES) && (!self.activeSource || !self.activeSource.length);
        NSSet *owners=[NSSet setWithArray:CCTVStringArrayValue(c[@"subscriptionSources"])];NSMutableSet *enabled=[owners mutableCopy];[enabled minusSet:disabled];
        if(!enabled.count)return NO;
        if(!self.activeSource.length)return YES;
        for(NSString *owner in enabled)if([self subscriptionOwner:owner matchesLiveResourceSource:self.activeSource])return YES;
        return NO;
    }]];
    if (self.favoritesOnly) {
        NSSet *ids=[NSSet setWithArray:self.favorites ?: @[]];
        base=[base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b){ return [ids containsObject:o[@"id"] ?: @""]; }]];
    } else if (isRecentsSegment) {
        NSMutableDictionary<NSString *, NSDictionary *> *byID = [NSMutableDictionary dictionary];
        for (NSDictionary *ch in base) {
            NSString *cid = [ch[@"id"] isKindOfClass:NSString.class] ? ch[@"id"] : @"";
            if (cid.length && !byID[cid]) byID[cid] = ch;
        }
        NSMutableArray<NSDictionary *> *orderedRecents = [NSMutableArray array];
        for (NSDictionary *r in self.recents) {
            NSString *rid = [r[@"id"] isKindOfClass:NSString.class] ? r[@"id"] : @"";
            NSDictionary *matched = rid.length ? byID[rid] : nil;
            if (matched) [orderedRecents addObject:matched];
        }
        base = orderedRecents;
    } else if (idx > 0 && idx < (NSInteger)groups.count) {
        NSString *g = groups[idx];
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b) {
            BOOL exact = [o[@"group"] isKindOfClass:NSString.class] && [o[@"group"] isEqualToString:g];
            if (exact) return YES;
            if ([g isEqualToString:@"央视"] && [o[@"group"] isKindOfClass:NSString.class] && [o[@"group"] isEqualToString:@"熊猫"]) return YES;
            if ([g isEqualToString:@"其他"] && [o[@"group"] isKindOfClass:NSString.class] && ![@[@"央视", @"卫视", @"地方"] containsObject:o[@"group"]]) return YES;
            return NO;
        }]];
    }
    if (self.query.length) {
        NSString *q = self.query.lowercaseString;
        base = [base filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *o, NSDictionary *b) {
            // name/id 可能来自外部订阅缓存，非字符串时直接调 lowercaseString 会
            // 抛 unrecognized selector；用 description 归一为字符串再比较。
            NSString *name=[(o[@"name"]?:@"") description];
            NSString *cid=[(o[@"id"]?:@"") description];
            return [[name lowercaseString] containsString:q] || [[cid lowercaseString] containsString:q];
        }]];
    }
    NSArray *sorted = base;
    if (!isRecentsSegment) {
        NSMutableDictionary<NSString *,NSNumber *> *ranks=[NSMutableDictionary dictionary];
        for(NSUInteger index=0;index<self.favorites.count;index++){id fav=self.favorites[index];if([fav isKindOfClass:NSString.class]&&!ranks[fav])ranks[fav]=@(index);}
        sorted = [base sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSNumber *left=ranks[a[@"id"]?:@""],*right=ranks[b[@"id"]?:@""];
            if(left && right)return [left compare:right];
            if(left || right)return left?NSOrderedAscending:NSOrderedDescending;
            // 按名称排序：收藏仍置顶（按收藏顺序），其余按名称排序；默认模式保持订阅原始顺序。
            if(self.channelSortMode==1){NSString *an=[(a[@"name"]?:@"") description],*bn=[(b[@"name"]?:@"") description];return [an localizedCaseInsensitiveCompare:bn];}
            return NSOrderedSame;
        }];
    }
    self.shownChannels = sorted;
    [self.table reloadData];
    [self.channelGrid reloadData];
    NSString *empty=self.query.length?@"没有找到匹配频道":(isRecentsSegment?@"暂无最近观看记录\n点选任意频道即可自动记录上次播放":(self.favoritesOnly?@"还没有收藏频道\n长按或左滑任意频道即可加入收藏":(self.subscriptionCatalog?@"暂无订阅频道\n点击下方按钮或右下角更多 → 添加直播订阅":(!CCTVBoolPreference(@"nativeChannelsEnabled",YES)?@"官方频道已关闭\n点击下方按钮可立即启用央视与卫视频道":@"当前分组下暂无可用频道"))));
    self.channelGrid.backgroundView=sorted.count?nil:[self buildCatalogEmptyBackgroundViewWithMessage:empty];
    self.table.backgroundView=sorted.count?nil:[self buildCatalogEmptyBackgroundViewWithMessage:empty];
}

- (void)rememberChannel:(NSDictionary *)ch {
    if (!ch[@"id"]) return;
    NSMutableDictionary *entry = [@{@"id": ch[@"id"],
                                    @"name": ch[@"name"] ?: ch[@"id"],
                                    @"group": ch[@"group"] ?: @"",
                                    @"watchedAt": @(floor(NSDate.date.timeIntervalSince1970))} mutableCopy];
    if ([ch[@"remoteURL"] length]) entry[@"remoteURL"] = ch[@"remoteURL"];
    if ([ch[@"logo"] isKindOfClass:NSString.class] && [ch[@"logo"] length]) entry[@"logo"] = ch[@"logo"];
    NSMutableArray *m = [NSMutableArray arrayWithObject:entry];
    for (NSDictionary *r in self.recents) {
        if (![r[@"id"] isEqualToString:ch[@"id"]] && m.count < 24) [m addObject:r];
    }
    self.recents = m;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:@"recents"];
}

- (void)onPullRefresh {
    if(self.subscriptionCatalog||self.activeTab==3){for(NSString *u in self.subscriptionURLs.allObjects)[self fetchSubscription:u silent:NO];}
    else{self.epgListGeneration++;[self.epgCache removeAllObjects];[self saveEPGCache];if(self.firstRender)[self refreshNowNext];[self applyFilter];}
    [self.table.refreshControl endRefreshing];[self.channelGrid.refreshControl endRefreshing];
}

- (void)loadEPGForChannel:(NSString *)cid channel:(NSDictionary *)channel section:(NSIndexPath *)ip {
    if (!CCTVBoolPreference(@"autoLoadEPG",YES)) return;
    if(CACurrentMediaTime()<self.playbackPriorityUntil)return;
    if (!cid.length || self.epgCache[cid] || [self.epgInflight containsObject:cid]) return;
    // cellForRow 已持有该频道字典：直接复用，避免每次出现新 cell 都对
    // 全量频道做两次线性查找（约 2 万条时滚动掉帧）。
    if(!channel)channel=[self channelWithID:cid];NSString *xmlSource=[ProfileStore epgSourceForChannel:channel];
    if(xmlSource.length){NSArray *rows=[[XMLTVStore shared] cachedRowsForSource:xmlSource channel:[ProfileStore epgIDForChannel:channel]];[self cacheXMLRows:rows channel:cid];if(self.epgCache[cid])return;}
    if (self.epgInflight.count >= 3) return;
    NSString *epgCID=[self epgIDForChannel:channel];
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
            // 先清理在途标记再判代次：代次不匹配时若直接 return，该频道会永久
            // 留在 epgInflight 里，此后 loadEPGForChannel 每次都因
            // containsObject: 提前返回，EPG 再也加载不出来。
            [weakSelf.epgListTasks removeObjectForKey:cid];
            [weakSelf.epgInflight removeObject:cid];
            if(listGeneration!=weakSelf.epgListGeneration)return;
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
                NSString *title=[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:nil;
                if (now >= s0 && now < e0) cur = title;
                else if (s0 > now && !nxt) nxt = title;
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
    if(!self.resourceImportWorkflow){
        ResourceImportWorkflowViewController *workflow=[ResourceImportWorkflowViewController new];self.resourceImportWorkflow=workflow;__weak typeof(self) weakSelf=self;
        workflow.onStateChanged=^{[weakSelf refreshConfigurationPage];};
        workflow.onOpenServices=^{[weakSelf openServicesPage];};
        workflow.existingImportTargetsProvider=^NSArray<NSDictionary *> *{RootViewController *owner=weakSelf;if(!owner)return @[];NSMutableArray<NSDictionary *> *targets=[NSMutableArray array];for(NSDictionary *catalog in [TVBoxCatalogStore catalogs])if(!catalog[@"bundledResourceID"]){[targets addObject:@{@"kind":@"catalog",@"kindLabel":@"影视合集",@"id":catalog[@"id"]?:@"",@"name":catalog[@"name"]?:@"资源合集",@"url":catalog[@"url"]?:@"",@"fingerprint":catalog[@"importFingerprint"]?:@"",@"sourceFilename":catalog[@"importSourceFilename"]?:@""}];}for(NSDictionary *service in [ServiceStore services])if(![service[@"builtin"] boolValue]&&![service[@"bundledResourceID"] length]){[targets addObject:@{@"kind":@"service",@"kindLabel":@"脚本资源",@"id":service[@"id"]?:@"",@"name":service[@"name"]?:@"脚本资源",@"url":service[@"url"]?:@"",@"fingerprint":service[@"importFingerprint"]?:@"",@"sourceFilename":service[@"importSourceFilename"]?:@""}];}for(NSString *source in owner.subscriptionURLs)if([source hasPrefix:@"local-playlist:"]){NSDictionary *metadata=[ProfileStore metadata:source];[targets addObject:@{@"kind":@"playlist",@"kindLabel":@"本地直播列表",@"id":source,@"name":metadata[@"name"]?:@"本地播放列表",@"url":source,@"fingerprint":metadata[@"importFingerprint"]?:@"",@"sourceFilename":metadata[@"importSourceFilename"]?:@""}];}return targets.copy;};
        workflow.onSaveCandidate=^(NSDictionary *candidate,BOOL update,void (^completion)(NSError *)){RootViewController *owner=weakSelf;if(owner)[owner saveImportCandidate:candidate update:update completion:completion];else completion([NSError errorWithDomain:@"ResourceImport" code:1 userInfo:@{NSLocalizedDescriptionKey:@"资源页面已关闭"}]);};
        [workflow refreshExistingResourceMatches];
    }
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:self.resourceImportWorkflow];navigation.modalPresentationStyle=UIModalPresentationFullScreen;HostStyleNavigation(navigation);[self.navigationController.topViewController presentViewController:navigation animated:YES completion:nil];
}
- (void)saveImportCandidate:(NSDictionary *)candidate update:(BOOL)update completion:(void (^)(NSError *error))completion {
    NSError *failure=nil;NSString *kind=candidate[@"kind"],*sourceFilename=[candidate[@"localFileName"] isKindOfClass:NSString.class]?candidate[@"localFileName"]:@"";
    if([kind isEqual:@"catalog"]){
        NSMutableDictionary *incoming=[candidate[@"catalog"] mutableCopy];if(sourceFilename.length)incoming[@"importSourceFilename"]=sourceFilename;
        NSString *catOrigin=[candidate[@"origin"] isKindOfClass:NSString.class]?candidate[@"origin"]:([incoming[@"url"] isKindOfClass:NSString.class]?incoming[@"url"]:@"");
        if([catOrigin.lowercaseString containsString:@"sub.lytvs.top"]){NSString *tk=CCTVTVBoxTokenFromInput(catOrigin);if(tk.length)CCTVTVBoxSaveSubscriptionToken(tk);}NSDictionary *existing=nil;NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"catalog"]?candidate[@"existingResourceID"]:@"";
        for(NSDictionary *catalog in [TVBoxCatalogStore catalogs]){BOOL target=targetID.length&&[targetID isEqual:catalog[@"id"]];BOOL automatic=!targetID.length&&(([incoming[@"url"] length]&&[incoming[@"url"] isEqual:catalog[@"url"]])||([incoming[@"importFingerprint"] length]&&[incoming[@"importFingerprint"] isEqual:catalog[@"importFingerprint"]]));if(target||automatic){existing=catalog;break;}}
        if(targetID.length&&!existing)failure=[NSError errorWithDomain:@"ResourceImport" code:7 userInfo:@{NSLocalizedDescriptionKey:@"匹配到的旧合集已被移除，请重新识别后再保存"}];
        else if(existing&&update){NSMutableDictionary *merged=[existing mutableCopy];[merged addEntriesFromDictionary:incoming];merged[@"id"]=existing[@"id"];merged[@"name"]=existing[@"name"]?:incoming[@"name"]?:@"资源合集";[TVBoxCatalogStore saveCatalog:merged];}
        else if([TVBoxCatalogStore catalogs].count>=50)failure=[NSError errorWithDomain:@"ResourceImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"已达到 50 个合集上限"}];else [TVBoxCatalogStore saveCatalog:incoming];
    }else if([kind isEqual:@"service"]){
        NSMutableDictionary *incoming=[candidate[@"service"] mutableCopy];if(sourceFilename.length)incoming[@"importSourceFilename"]=sourceFilename;NSDictionary *existing=nil;NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"service"]?candidate[@"existingResourceID"]:@"";
        for(NSDictionary *service in [ServiceStore services]){if([service[@"builtin"] boolValue])continue;BOOL target=targetID.length&&[service[@"id"] isEqual:targetID];BOOL automatic=!targetID.length&&![service[@"id"] isEqual:incoming[@"id"]]&&(([incoming[@"url"] length]&&[incoming[@"url"] isEqual:service[@"url"]])||([incoming[@"importFingerprint"] length]&&[incoming[@"importFingerprint"] isEqual:service[@"importFingerprint"]]));if(target||automatic){existing=service;break;}}
        if(targetID.length&&!existing)failure=[NSError errorWithDomain:@"ResourceImport" code:8 userInfo:@{NSLocalizedDescriptionKey:@"匹配到的旧脚本资源已被移除，请重新识别后再保存"}];
        else if(existing&&update){if([PyHost isManagedServiceIdentifier:existing[@"id"]])failure=[NSError errorWithDomain:@"ResourceImport" code:3 userInfo:@{NSLocalizedDescriptionKey:@"已有资源正在运行或清理，请先停止该资源，再重试保存"}];else{NSDictionary *saved=[ServiceStore replaceImportedService:existing withService:incoming error:&failure];if(saved){NSMutableDictionary *metadata=[saved mutableCopy];if(incoming[@"importFingerprint"])metadata[@"importFingerprint"]=incoming[@"importFingerprint"];if(sourceFilename.length)metadata[@"importSourceFilename"]=sourceFilename;[ServiceStore save:metadata];}}}
        else [ServiceStore save:incoming];
    }else if([kind isEqual:@"playlist"]){
        NSString *origin=[self stableURLKey:candidate[@"origin"]],*text=candidate[@"text"]?:@"";NSString *targetID=update&&[candidate[@"existingResourceKind"] isEqual:@"playlist"]?candidate[@"existingResourceID"]:@"";NSURL *base=origin.length?[NSURL URLWithString:candidate[@"resolvedURL"]?:origin]:nil;NSArray *parsed=[M3UParser parse:text baseURL:base];
        if(!parsed.count)failure=[NSError errorWithDomain:@"ResourceImport" code:6 userInfo:@{NSLocalizedDescriptionKey:@"新播放列表没有有效 HTTP/HTTPS 频道，旧资源保持不变"}];
        else if(targetID.length){if([targetID hasPrefix:@"local-playlist:"]&&[self.subscriptionURLs containsObject:targetID]){NSMutableDictionary *values=[@{@"name":candidate[@"name"]?:@"本地播放列表",@"text":text,@"cachedChannels":CCTVPlaylistSnapshotRows(parsed,targetID)} mutableCopy];if(candidate[@"importFingerprint"])values[@"importFingerprint"]=candidate[@"importFingerprint"];if(sourceFilename.length)values[@"importSourceFilename"]=sourceFilename;[ProfileStore update:targetID values:values];[self installPlaylist:parsed source:targetID];}else if([self.subscriptionURLs containsObject:targetID]){[ProfileStore update:targetID values:@{@"name":candidate[@"name"]?:@"直播订阅",@"text":text,@"cachedChannels":CCTVPlaylistSnapshotRows(parsed,targetID)}];[self installPlaylist:parsed source:targetID];}else failure=[NSError errorWithDomain:@"ResourceImport" code:9 userInfo:@{NSLocalizedDescriptionKey:@"匹配到的旧直播资源已被移除，请重新识别后再保存"}];}
        else if(origin.length&&[self.subscriptionURLs containsObject:origin]&&!update)failure=[NSError errorWithDomain:@"ResourceImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"相同在线订阅只能更新；如需独立副本，请导出后作为本地文件导入"}];
        else if(origin.length){NSMutableDictionary *values=[@{@"name":candidate[@"name"]?:@"直播订阅",@"text":text,@"cachedChannels":CCTVPlaylistSnapshotRows(parsed,origin)} mutableCopy];if(candidate[@"importFingerprint"])values[@"importFingerprint"]=candidate[@"importFingerprint"];if(sourceFilename.length)values[@"importSourceFilename"]=sourceFilename;[ProfileStore update:origin values:values];[self.subscriptionURLs addObject:origin];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];NSString *detected=[M3UParser epgURL:text baseURL:base];if(detected.length)[ProfileStore update:origin values:@{@"detectedEPGURL":detected}];[self installPlaylist:parsed source:origin];}
        else {NSMutableDictionary *metadata=[NSMutableDictionary dictionary];if(sourceFilename.length)metadata[@"importSourceFilename"]=sourceFilename;if(candidate[@"importFingerprint"])metadata[@"importFingerprint"]=candidate[@"importFingerprint"];[self importPlaylistData:[text dataUsingEncoding:NSUTF8StringEncoding] name:candidate[@"name"]?:@"本地播放列表" metadata:metadata];}
    }else failure=[NSError errorWithDomain:@"ResourceImport" code:5 userInfo:@{NSLocalizedDescriptionKey:@"资源类型尚未识别"}];
    [self refreshConfigurationPage];completion(failure);
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
        NSMutableSet *sources = [NSMutableSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])];
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
            // 就绪检查进行中时不要静默丢弃用户的刷新请求：登记一次待处理，
            // 待本次探测结束（失败分支）再重调一次；成功分支本身就会重调，
            // 故只在失败分支消费，避免重复与死循环。
            if(self.subscriptionReadiness[sourceKey]){if(!self.pendingSubscriptionRefresh)self.pendingSubscriptionRefresh=[NSMutableSet set];[self.pendingSubscriptionRefresh addObject:sourceKey];return;}
            NSUInteger readinessVersion=[self.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]+1;self.subscriptionRequestVersions[sourceKey]=@(readinessVersion);
            LocalServiceReadiness *probe=[self readinessForURL:sourceURL service:localService];self.subscriptionReadiness[sourceKey]=probe;__weak typeof(self) w=self;
            [probe start:^(NSError *error,NSTimeInterval elapsed){
                if(w.subscriptionReadiness[sourceKey]!=probe)return;[w.subscriptionReadiness removeObjectForKey:sourceKey];
                if([w.subscriptionRequestVersions[sourceKey] unsignedIntegerValue]!=readinessVersion||![w.subscriptionURLs containsObject:sourceKey])return;
                NSMutableDictionary *probeFields=[@{@"correlation_id":traceID?:@"", @"service_id":localService[@"id"]?:@"", @"service_name":localService[@"name"]?:@"", @"engine":localService[@"engine"]?:@"python", @"port":localService[@"port"]?:@0, @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:probe.diagnosticSummary];[probeFields addEntriesFromDictionary:CCTVDiagnosticURLFields(sourceURL)];
                if(error){probeFields[@"error_domain"]=error.domain?:@"";probeFields[@"error_code"]=@(error.code);probeFields[@"error_message"]=error.localizedDescription?:@"";[RuntimeDiagnostics.shared recordEvent:@"local_service_health_failed" category:@"service" fields:probeFields];[ProfileStore update:sourceKey values:@{@"status":error.localizedDescription?:@"服务未就绪"}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[w refreshConfigurationPage];[w logPluginLine:[NSString stringWithFormat:@"订阅接口健康检查失败 · %@",[HostLogRedactor redactText:error.localizedDescription?:@"未知错误"]] identifier:localService[@"id"] name:localService[@"name"]];[w log:@"本机订阅等待服务失败 %@",error.localizedDescription];if([w.pendingSubscriptionRefresh containsObject:sourceKey]){[w.pendingSubscriptionRefresh removeObject:sourceKey];[w fetchSubscription:sourceKey silent:silent];}return;}
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
    NSString *playlistUserAgent=[ProfileStore metadata:sourceKey][@"userAgent"];
    if([playlistUserAgent isKindOfClass:NSString.class]&&playlistUserAgent.length<=1024&&[playlistUserAgent rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location==NSNotFound)[req setValue:playlistUserAgent forHTTPHeaderField:@"User-Agent"];
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
        NSArray<M3UChannel *> *list = text.length ? [M3UParser parse:text baseURL:resp.URL?:url error:&parseError] : nil;
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
                if(!retainedCount)for(NSDictionary *channel in weakSelf.allChannels)if([CCTVStringArrayValue(channel[@"subscriptionSources"]) containsObject:sourceKey])retainedCount++;
                NSString *reason=err.localizedDescription?:parseError.localizedDescription?:[NSString stringWithFormat:@"HTTP %ld / 无有效 M3U",(long)status];
                NSString *statusText=retainedCount?[NSString stringWithFormat:@"刷新失败 · 保留上次 %lu 个频道 · %@",(unsigned long)retainedCount,reason]:[NSString stringWithFormat:@"刷新失败 · %@",reason];
                [ProfileStore update:sourceKey values:@{@"status":statusText}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];[weakSelf refreshConfigurationPage];
                if(localService)[weakSelf logPluginLine:[NSString stringWithFormat:@"订阅地址读取失败 · %@",[HostLogRedactor redactText:reason]] identifier:localService[@"id"] name:localService[@"name"]];
                [weakSelf log:@"订阅失败 %@ %@", CCTVServiceLogAddress(urlString), [HostLogRedactor redactText:err.localizedDescription ?: @"无有效条目"]];
                return;
            }
            NSMutableDictionary *fields=[@{@"source_type":@"http", @"correlation_id":traceID?:@"", @"trigger":silent?@"automatic":@"user", @"http_status":@(status), @"response_mime_type":mimeType, @"elapsed_ms":@((NSInteger)((CACurrentMediaTime()-requestStartedAt)*1000)), @"channel_count":@(list.count), @"received_bytes":@(receivedBytes)} mutableCopy];[fields addEntriesFromDictionary:CCTVDiagnosticURLFields(url)];[RuntimeDiagnostics.shared recordEvent:@"subscription_refresh_succeeded" category:@"subscription" fields:fields];[weakSelf.subscriptionTraceIDs removeObjectForKey:sourceKey];
            NSString *detected=[M3UParser epgURL:text baseURL:resp.URL?:url];if(detected.length){NSString *prior=[ProfileStore metadata:sourceKey][@"detectedEPGURL"]?:[ProfileStore metadata:sourceKey][@"epgURL"];[ProfileStore update:sourceKey values:@{@"detectedEPGURL":detected}];if(![prior isEqual:detected])[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];if(localService&&![prior isEqual:detected])[weakSelf logPluginLine:[NSString stringWithFormat:@"节目单地址：%@",CCTVServiceLogAddress(detected)] identifier:localService[@"id"] name:localService[@"name"]];}
            // 新清单不再提供节目单地址时清掉过期推导值，否则行上永远显示
            // “已配置”，且 EPG 页会继续用旧地址。失败路径不碰它。
            else if([ProfileStore metadata:sourceKey][@"detectedEPGURL"]){[ProfileStore removeValueForKey:@"detectedEPGURL" source:sourceKey];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];if(localService)[weakSelf logPluginLine:@"节目单地址已清除 · 新订阅清单未提供节目单" identifier:localService[@"id"] name:localService[@"name"]];}
            if(localService)[weakSelf logPluginLine:[NSString stringWithFormat:@"订阅清单可读取 · %lu 个频道",(unsigned long)list.count] identifier:localService[@"id"] name:localService[@"name"]];
            [weakSelf installPlaylist:list source:sourceKey];
        });
    }];self.subscriptionTasks[sourceKey]=subscriptionTask;[subscriptionTask resume];
}
// 资源页单条目刷新：行里的 source 可能是订阅 URL，也可能是 plugin:<id>。
// 插件行先解析到它自己的订阅清单地址，再走同一条刷新链路。
- (void)refreshSubscriptionForProfile:(NSString *)source {
    NSString *url=source;
    NSDictionary *service=[self resourceServiceForSource:source];
    if(service)url=[ServiceStore subscriptionURLForService:service]?:@"";
    if(!url.length){[self showServiceError:@"此资源没有可刷新的订阅清单"];return;}
    [self fetchSubscription:url silent:NO];
}
// 单条目健康重查：有订阅清单的走一次带就绪探测的刷新（先丢弃该源
// 2 秒内的就绪缓存，强制重新探测）；无清单的插件直接对服务做一次
// 就绪探测，成功只写日志并刷新本行，失败弹明确提示。
- (void)recheckProfileHealth:(NSString *)source {
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *url=service?[ServiceStore subscriptionURLForService:service]?:@"":source;
    if(url.length){NSURL *u=[NSURL URLWithString:url];if(u&&[self localServiceForURL:u])[self.readyLocalOrigins removeObjectForKey:[self originForURL:u]];[self fetchSubscription:url silent:NO];return;}
    if(!service){[self showServiceError:@"找不到此资源，无法检测健康状态"];return;}
    if(![PyHost isRunningServiceIdentifier:service[@"id"]]){[self showServiceError:@"服务未运行，无法检测健康状态。请先启动服务。"];return;}
    NSURL *base=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@",service[@"port"]?:@0]];
    LocalServiceReadiness *probe=[self readinessForURL:base service:service];
    if(!self.subscriptionReadiness)self.subscriptionReadiness=[NSMutableDictionary dictionary];
    [self.subscriptionReadiness[source] cancel];self.subscriptionReadiness[source]=probe;
    __weak typeof(self) weakSelf=self;
    [probe start:^(NSError *error,NSTimeInterval elapsed){
        RootViewController *owner=weakSelf;if(!owner||owner.subscriptionReadiness[source]!=probe)return;
        [owner.subscriptionReadiness removeObjectForKey:source];
        // 探测完成前服务已被停掉：停服务本身已刷新页面，不再弹失败提示。
        if(![PyHost isRunningServiceIdentifier:service[@"id"]])return;
        if(error){[owner showServiceError:error.localizedDescription?:@"服务未就绪"];return;}
        [owner logPluginLine:[NSString stringWithFormat:@"健康检查通过 · %.2f 秒",elapsed] identifier:service[@"id"] name:service[@"name"]];
        NSString *origin=[owner originForURL:base];if(origin.length)owner.readyLocalOrigins[origin]=@(CACurrentMediaTime());
        [owner refreshConfigurationPage];
    }];
}
// 单条目 EPG 重匹配：复用订阅刷新链路，新清单重新推导 detectedEPGURL；
// 若新清单不再提供节目单地址，成功路径会清掉过期值（见 fetchSubscription）。
- (void)rematchEPGForProfile:(NSString *)source {
    NSDictionary *service=[self resourceServiceForSource:source];
    NSString *url=service?[ServiceStore subscriptionURLForService:service]?:@"":source;
    if(!url.length){[self showServiceError:@"此资源没有订阅清单，无法重新匹配节目单"];return;}
    [self fetchSubscription:url silent:NO];
}
// 单条目合集刷新：按原地址重新下载并解析，解析出的新 id 换回原合集 id
// 后保存——saveCatalog 按 id 合并，行不会重复，站点/直播数就地更新。
// MacCMS 行的 url 是接口地址，不走 JSON 下载；空合集不覆盖原合集。
- (void)refreshTVBoxCatalogProfile:(NSString *)source {
    NSString *identifier=[source hasPrefix:@"tvbox:"]?[source substringFromIndex:6]:@"";
    NSDictionary *catalog=[TVBoxCatalogStore catalogForID:identifier];
    if(!catalog){[self showServiceError:@"找不到此资源合集，请重新导入"];return;}
    if([[catalog[@"catalogKind"] isKindOfClass:NSString.class]?catalog[@"catalogKind"]:@"" isEqual:@"maccms"]){[self showServiceError:@"MacCMS 影视接口按接口配置使用，无需下载刷新"];return;}
    NSURL *url=[NSURL URLWithString:[catalog[@"url"] isKindOfClass:NSString.class]?catalog[@"url"]:@""];
    if(!url||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]){[self showServiceError:@"此合集没有可重新下载的配置地址"];return;}
    [self.tvboxCatalogDownloader cancel];self.tvboxCatalogDownloader=[TVBoxCatalogDownloader new];
    self.navigationItem.prompt=@"正在重新下载资源合集…";
    __weak typeof(self) weakSelf=self;
    [self.tvboxCatalogDownloader loadURL:url completion:^(NSDictionary *fresh,NSError *error){
        RootViewController *owner=weakSelf;if(!owner)return;owner.navigationItem.prompt=nil;
        if(error||!fresh){[owner showServiceError:error.localizedDescription?:@"资源合集下载失败"];return;}
        NSArray *sites=[fresh[@"sites"] isKindOfClass:NSArray.class]?fresh[@"sites"]:@[];
        NSArray *lives=[fresh[@"lives"] isKindOfClass:NSArray.class]?fresh[@"lives"]:@[];
        if(!sites.count&&!lives.count){[owner showServiceError:@"重新下载的合集为空，已保留原合集"];return;}
        NSMutableDictionary *updated=[fresh mutableCopy];updated[@"id"]=identifier;
        [TVBoxCatalogStore saveCatalog:updated];
        [owner refreshConfigurationPage];
        [owner log:@"资源合集已刷新 · %@ · %lu 个站点",(fresh[@"name"]?:catalog[@"name"]?:@"资源合集"),(unsigned long)sites.count];
    }];
}
- (void)installPlaylist:(NSArray<M3UChannel *> *)list source:(NSString *)sourceKey {
            NSDictionary *managedService=[self localServiceForURL:[NSURL URLWithString:sourceKey]];
            NSArray<NSString *> *retiredManagedSources=managedService?[self managedSubscriptionSourcesForService:managedService excludingURL:sourceKey]:@[];
            NSSet<NSString *> *retiredSourceSet=[NSSet setWithArray:retiredManagedSources];
            NSMutableArray *merged = [NSMutableArray array];
            for (NSDictionary *existing in self.allChannels ?: @[]) {
                NSArray *originalOwners=CCTVStringArrayValue(existing[@"subscriptionSources"]);NSMutableSet *owners = [NSMutableSet setWithArray:originalOwners];
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
                    NSMutableSet *owners = [NSMutableSet setWithArray:CCTVStringArrayValue(entry[@"subscriptionSources"])];
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
            NSArray *owned=[merged filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *c,NSDictionary *b){return [CCTVStringArrayValue(c[@"subscriptionSources"]) containsObject:sourceKey];}]];
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
    else if([ProfileStore metadata:sourceKey][@"detectedEPGURL"]){[ProfileStore removeValueForKey:@"detectedEPGURL" source:sourceKey];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:sourceKey];}
    [self installPlaylist:list source:sourceKey];
}
- (void)playRemote:(NSDictionary *)ch {
    self.livePlaybackSuspendedForNavigation=NO;
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
    self.currentRemoteURL=u;self.channelID=ch[@"id"]?:u;self.channelName=ch[@"name"]?:u;self.routeName=self.nativePlainRouteActive?[NSString stringWithFormat:@"%@ · AVPlayer 明文线路",self.requestedNativeRoute[@"provider"]?:@"自选"]:@"订阅";[self.channelGrid reloadData];[self.table reloadData];
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
    // 直播 AVPlayer 回退路径也按默认清晰度偏好约束 HLS 自适应码率，
    // 与影视播放页的映射一致（smooth 1.5M / hd 4M / uhd 8M，auto 不限）。
    NSString *preferredQuality=[NSUserDefaults.standardUserDefaults stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    if([preferredQuality isEqualToString:@"smooth"])item.preferredPeakBitRate=1500000;
    else if([preferredQuality isEqualToString:@"hd"])item.preferredPeakBitRate=4000000;
    else if([preferredQuality isEqualToString:@"uhd"])item.preferredPeakBitRate=8000000;
    self.avPlayer=[AVPlayer playerWithPlayerItem:item];self.avPlayer.automaticallyWaitsToMinimizeStalling=YES;self.avPlayer.allowsExternalPlayback=YES;self.avPlayer.usesExternalPlaybackWhileExternalScreenIsActive=YES;self.remotePlaybackWanted=YES;
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

- (NSDictionary *)nextUntriedAlternateChannel {
    // SDK 播放失败耗尽重试后也可复用：按同名找一条未试过、且订阅源未被禁用的远端地址。
    // 自选明文线路不自动换源；单频道最多试 4 条。
    if(self.nativePlainRouteActive || self.remoteAttemptedURLs.count>=4)return nil;
    NSSet *disabled=[NSSet setWithArray:[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[]];
    for (NSDictionary *channel in self.allChannels) {
        if(![channel[@"name"] isEqualToString:self.channelName])continue;
        NSString *url=[self stableURLKey:channel[@"remoteURL"]];
        if(!url.length || [self.remoteAttemptedURLs containsObject:url])continue;
        NSMutableSet *owners=[NSMutableSet setWithArray:CCTVStringArrayValue(channel[@"subscriptionSources"])];[owners minusSet:disabled];
        if(!owners.count)continue;
        return channel;
    }
    return nil;
}
- (void)tryAlternateSource {
    if(!self.remotePlaybackWanted)return;
    NSDictionary *alternate=[self nextUntriedAlternateChannel];
    if(alternate){
        self.remoteRetryCount=0;self.remoteFailureRecoveryPending=NO;
        [self log:@"换源重试 %lu/4",(unsigned long)self.remoteAttemptedURLs.count+1];
        [self startRemoteChannel:alternate];
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
        [self.spinner stopAnimating];self.titleLabel.hidden=YES;self.infoLabel.hidden=YES;self.playerTopScrim.hidden=YES;[self loadPlayerChannelLogoAfterFirstFrame];[self updateNowPlaying];[self refreshNowNext];[self restartEPGTimer];
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
            NSString *title=[row[@"title"] isKindOfClass:NSString.class]?row[@"title"]:nil;
            if (now >= s0 && now < e0) cur = title;
            else if (s0 > now && !next) next = title;
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
    self.nativeAttemptStartedAt=CACurrentMediaTime();
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
}

- (BOOL)recoverNativeStartupForReason:(NSString *)reason {
    if(self.directNativeRouteActive || self.nativeTimeShiftActive || self.nativeTransitionKind.length || self.firstRender || self.nativePlaybackFailed || self.nativeStartupRecoveryUsed || !self.currentPlayer || !self.channelID.length)return NO;
    NSString *channelID=self.channelID;
    NSTimeInterval now=CACurrentMediaTime();
    NSMutableDictionary *fields=[@{@"reason":reason?:@"startup_timeout", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"elapsed_seconds":@(MAX(0,now-self.playStartedAt)), @"attempt_seconds":@(MAX(0,now-self.nativeAttemptStartedAt)), @"startup_trace":self.startupTrace.summary?:@""} mutableCopy];
    if(![ProfileStore isHTTP:channelID]&&channelID.length<=128)fields[@"sdk_channel_id"]=channelID;
    [RuntimeDiagnostics.shared recordEvent:@"native_startup_recovery_started" category:@"playback" fields:fields];
    self.nativeStartupRecoveryUsed=YES;
    self.nativeSafeStartupActive=YES;
    self.playbackGeneration++;
    [self log:@"SDK 自动起播 %@，使用全新实例与默认配置恢复一次 · %@",reason?:@"超时",self.startupTrace.summary];
    [self stopPlayback];
    [self.nativePreloader cancel];
    self.sdkPlayer=nil;
    self.sdkPlayerUsed=NO;
    self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    [self recordStartupStage:@"recovery"];
    self.stallReported=NO;
    [self playViaSDK:channelID title:self.channelName?:channelID];
    return YES;
}

- (void)tick:(NSTimer *)timer {
    if(timer!=self.watchdog)return;
    self.watchdogTicks += 1;
    if (!self.currentPlayer) { [timer invalidate]; self.watchdog=nil; return; }
    [self attachVideoView];
    if (self.firstRender) { [timer invalidate]; self.watchdog=nil; return; }
    NSTimeInterval now=CACurrentMediaTime();
    NSTimeInterval elapsed=now-self.playStartedAt;
    NSTimeInterval attemptElapsed=self.nativeAttemptStartedAt>0?now-self.nativeAttemptStartedAt:elapsed;
    if(!self.directNativeRouteActive && !self.nativeTimeShiftActive && [self.startupTrace shouldRecoverMissingSetupAtTime:now alreadyRetried:self.nativeStartupRecoveryUsed failed:self.nativePlaybackFailed]){
        if([self recoverNativeStartupForReason:@"vdn_without_setup"])return;
    }
    if(elapsed>=10&&!self.stallReported){
        self.stallReported=YES;BOOL vdnDone=self.startupTrace.stages[@"vdn"]!=nil;NSString *waitState=self.directNativeRouteActive?@"自选地址等待视频数据":(vdnDone?@"等待视频数据":@"调度等待中");
        self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@",self.channelName,waitState];
        [self log:@"原生起播等待 %.2fs · %@ · %@",elapsed,self.directNativeRouteActive?@"SDK URL 路径":(vdnDone?@"VDN 已完成":@"VDN 尚未完成"),self.startupTrace.summary];
    }
    if(attemptElapsed>=25 || elapsed>=50){
        if(elapsed<50 && [self recoverNativeStartupForReason:@"first_frame_timeout"])return;
        [timer invalidate];[self log:@"%@ · 总计 %.2fs / 本次 %.2fs · %@",self.nativeStartupRecoveryUsed?@"SDK 默认配置恢复后仍未首帧":@"原生起播等待超时",elapsed,attemptElapsed,self.startupTrace.summary];
        [self displayNativePlaybackFailure:@"起播超时" error:nil];
        [self stopPlayback];
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
    if (!sig) return nil; // @try 只包了 invoke；signature 为 nil 时
    // invocationWithMethodSignature:nil 会直接抛异常，先判空返回。
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
    [self.timeshiftController noteLoadState:state];
    [self attachVideoView];
    if (state == 4) {                     // PrepareDone
        [self recordStartupStage:@"prepared"];
        if(!self.firstRender){[self log:@"PrepareDone → play"];[self call:self.currentPlayer sel:@"play"];}else [self log:@"PrepareDone：已自动出画面，不重复 play"];
    } else if (state == 13) {
        [self log:@"加载取消"];
    }
}

- (void)player:(id)player programPubicChanged:(BOOL)isPublic {
    if (player != self.currentPlayer) return;
    [self.timeshiftController noteCopyrightChanged:isPublic error:nil];
}

- (void)player:(id)player programPubicChanged:(BOOL)isPublic type:(NSUInteger)sourceType error:(NSError *)error {
    if (player != self.currentPlayer) return;
    [self.timeshiftController noteCopyrightChanged:isPublic error:error];
}

- (void)playerPeriodicTimeEvent:(id)player {
    if (player != self.currentPlayer) return;
    [self.timeshiftController notePeriodicTick];
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
    [self.timeshiftController noteStatEvent:event];
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
        self.firstRender = YES;self.nativePlaybackFailed=NO;self.nativeSafeStartupActive=NO;
        if(!self.nativeTimeShiftActive)[self.timeshiftController noteReturnedToLive];
        if([self.nativeStartupTuner restore])[self log:@"首帧后已恢复 SDK 稳态缓冲"];
        [self endPlaybackPriority];
        [self.spinner stopAnimating];
        self.titleLabel.text = self.channelName;
        if(!self.nativeTimeShiftActive){self.titleLabel.hidden=YES;self.infoLabel.hidden=YES;}if(!self.nativeTimeShiftActive){self.playerTopScrim.hidden=YES;}
        [self loadPlayerChannelLogoAfterFirstFrame];
        [self recordStartupStage:@"frame"];
        [RuntimeDiagnostics.shared recordEvent:@"playback_first_frame" category:@"playback" fields:@{@"player":@"CNPlayerSDK", @"elapsed_ms":@((NSInteger)(self.firstFrameSeconds*1000)), @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"route_type":self.requestedNativeRoute?@"user_selected":@"sdk_auto"}];
        if(self.nativeTransitionKind.length){[self log:@"原生%@首帧 %.2fs · %@",self.nativeTransitionKind,self.firstFrameSeconds,self.startupTrace.summary];self.nativeTransitionKind=nil;}
        else [self log:@"首帧渲染 %.2fs · %@", self.firstFrameSeconds,self.startupTrace.summary];
        [self log:@"SDK 报告节点 %@ · 请求线路 %@",[NativeCDNPreference observedCDNDescriptionForPlayer:self.currentPlayer],self.routeName?:@"自动"];
        [self updateNowPlaying];
        [self refreshNowNext];
        [self restartEPGTimer];
        if([self.pendingNativeReplayProgram[@"channelID"] isEqualToString:self.channelID]){
            NSDictionary *pendingReplay=self.pendingNativeReplayProgram;
            self.pendingNativeReplayProgram=nil;
            dispatch_async(dispatch_get_main_queue(),^{
                [self seekNativeStart:[pendingReplay[@"start"] doubleValue] end:[pendingReplay[@"end"] doubleValue]];
            });
        }
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
        // SDK 2 次重连耗尽：仍有未试过的同名订阅源时改走 AVPlayer，不直接判死刑；
        // 订阅源也耗尽才显示失败。自选明文线路不自动换源（见 nextUntriedAlternateChannel）。
        NSDictionary *alternate=[self nextUntriedAlternateChannel];
        if(alternate){[self log:@"SDK 播放失败，改用订阅源地址继续播放"];[self startRemoteChannel:alternate];}
        else [self displayNativePlaybackFailure:@"播放失败" error:error];
    }
}

- (void)retryPlaybackWithAlternateSource {
    // 失败后换源重试：订阅频道复用已有的备用源回退（未试过的同名源，最多 4 条），
    // 原生频道循环到下一条自选线路（绕回 SDK 自动）；无可换的就按原线路重试。
    if(self.remotePlaybackFailed&&self.currentRemoteURL.length){self.remotePlaybackWanted=YES;[self tryAlternateSource];return;}
    NSDictionary *channel=[self channelWithID:self.channelID];
    if(!channel&&self.channelID.length)channel=@{@"id":self.channelID,@"name":self.channelName?:self.channelID};
    if(!channel)return;
    NSArray *routes=[channel[@"routes"] isKindOfClass:NSArray.class]?channel[@"routes"]:@[];
    if(!routes.count){self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:self.requestedNativeRoute];return;}
    NSInteger current=[routes indexOfObjectPassingTest:^BOOL(NSDictionary *r,NSUInteger idx,BOOL *stop){return [r isEqual:self.requestedNativeRoute];}];
    NSDictionary *next=current==NSNotFound?routes.firstObject:(current+1<(NSInteger)routes.count?routes[current+1]:nil);
    [self log:@"换线路重试：%@ -> %@",self.routeName?:@"自动",next?@"自选线路":@"SDK 自动"];
    self.selectionRequestedAt=CACurrentMediaTime();[self playChannel:channel route:next];
}
- (void)displayNativePlaybackFailure:(NSString *)stage error:(NSError *)error {
    NSString *player=self.avPlayer?@"AVPlayer":(self.cicadaPlayer?@"CicadaPlayer":@"CNPlayerSDK");
    NSMutableDictionary *failureFields=[@{@"player":player, @"stage":stage?:@"unknown", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"playback_generation":@(self.playbackGeneration), @"correlation_id":self.currentPlaybackTraceID?:@"", @"route_type":self.directNativeRouteActive?@"user_selected":@"sdk_auto"} mutableCopy];
    if(![ProfileStore isHTTP:self.channelID]&&self.channelID.length<=128)failureFields[@"sdk_channel_id"]=self.channelID?:@"";
    if(self.currentPlayer&&!self.avPlayer)failureFields[@"sdk_reported_node"]=[NativeCDNPreference observedCDNDescriptionForPlayer:self.currentPlayer]?:@"unknown";
    [RuntimeDiagnostics.shared recordEvent:@"playback_failed" category:@"playback" fields:failureFields];
    self.nativePlaybackFailed=YES;self.nativeRetryPending=NO;[self.watchdog invalidate];self.watchdog=nil;[self.nativeStartupTuner restore];[self endPlaybackPriority];[self.spinner stopAnimating];
    NSString *channel=self.channelName.length?self.channelName:@"频道";
    self.titleLabel.text=error.code?[NSString stringWithFormat:@"%@ · %@ (%ld)",channel,stage,(long)error.code]:[NSString stringWithFormat:@"%@ · %@",channel,stage];
    self.titleLabel.hidden=NO;NSString *failureDetail=error.localizedDescription.length?[HostLogRedactor redactText:error.localizedDescription]:nil;self.infoLabel.text=failureDetail?[NSString stringWithFormat:@"%@ · 点按“重试”再次播放，或点“线路”换源后重试",failureDetail]:@"点按“重试”再次播放，或点“线路”换源后重试";self.infoLabel.hidden=NO;self.controlBar.hidden=NO;
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
            RootViewController *owner=weakSelf;if(!owner)return;
            [owner.navigationController popToViewController:owner animated:YES];
            owner.playerTabs.selectedSegmentIndex=1;[owner selectPlayerPanel];
            if(![owner.channelID isEqualToString:cid] || !owner.currentPlayer || owner.avPlayer || !owner.firstRender){
                owner.pendingNativeReplayProgram=@{@"channelID":cid?:@"",@"start":@([program[@"start"] doubleValue]),@"end":@([program[@"end"] doubleValue])};
                if(![owner.channelID isEqualToString:cid] || !owner.currentPlayer || owner.avPlayer)[owner selectChannel:channel];
                return;
            }
            [owner seekNativeStart:[program[@"start"] doubleValue] end:[program[@"end"] doubleValue]];
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
    self.firstRender=NO;self.nativePlaybackFailed=NO;self.stallReported=NO;self.nativeStartupRecoveryUsed=NO;self.nativeSafeStartupActive=NO;self.nativeTransitionKind=kind;
    self.playStartedAt=CACurrentMediaTime();self.startupTrace=[[PlaybackStartupTrace alloc] initWithStartTime:self.playStartedAt];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · %@中",self.channelName,kind];self.titleLabel.hidden=NO;[self.spinner startAnimating];[self startWatchdog];
}
- (void)seekNativeStart:(NSTimeInterval)start end:(NSTimeInterval)end {
    if (!self.currentPlayer || self.avPlayer || !self.firstRender) {
        [self showServiceError:@"请等待 CCTV 原生频道起播完成后再操作。"]; return;
    }
    if (!self.timeshiftController) [self rebuildTimeshiftController];
    [self beginNativeTransition:end == 0 ? @"时移" : @"回看"];
    self.nativeTimeShiftActive = YES;
    NSUInteger generation = self.playbackGeneration;
    __weak id player = self.currentPlayer;
    __weak typeof(self) weakSelf = self;
    [self.timeshiftController requestSeekToStart:start end:end channelID:self.channelID completion:^(BOOL ok, NSError *error) {
        if (generation != weakSelf.playbackGeneration || player != weakSelf.currentPlayer) return;
        if (!ok || error) {
            [weakSelf failNativeTransition:error.localizedDescription.length
                ? error.localizedDescription
                : @"频道未允许该时间的时移/回看，请返回直播或重新选台。"];
        } else {
            [weakSelf log:@"原生时移请求已完成，等待/确认首帧"];
        }
    }];
}
- (void)failNativeTransition:(NSString *)message {
    [self.nativeTimeshift cancel];self.nativeTransitionKind=nil;self.nativePlaybackFailed=YES;[self.watchdog invalidate];[self.spinner stopAnimating];[self endPlaybackPriority];
    self.titleLabel.text=[NSString stringWithFormat:@"%@ · 时移操作失败",self.channelName];[self log:@"%@",message];[self showServiceError:message];
}
- (void)returnToNativeLive {
    if (!self.currentPlayer || self.avPlayer) return;
    if (!self.timeshiftController) [self rebuildTimeshiftController];
    [self beginNativeTransition:@"返回直播"];
    self.nativeTimeShiftActive = NO;
    [self.timeshiftController returnToLive];
}

- (NSString *)activeAirPlayDeviceName {
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *output in route.outputs) {
        if ([output.portType isEqualToString:AVAudioSessionPortAirPlay]) {
            return output.portName.length ? output.portName : @"AirPlay 设备";
        }
    }
    if (self.avPlayer && self.avPlayer.isExternalPlaybackActive) return @"AirPlay 电视";
    return nil;
}

- (void)triggerSystemAirPlayPicker {
    AVRoutePickerView *picker = self.hiddenRoutePicker ?: self.catalogFloatingAirPlayPicker;
    for (UIView *subview in picker.subviews) {
        if ([subview isKindOfClass:UIButton.class]) {
            [(UIButton *)subview sendActionsForControlEvents:UIControlEventTouchUpInside];
            return;
        }
    }
}

- (NSString *)castableStreamURLForCurrentChannel {
    NSString *rawURL = self.currentRemoteURL;
    if (!rawURL.length && self.requestedNativeRoute[@"url"]) {
        rawURL = [self.requestedNativeRoute[@"url"] isKindOfClass:NSString.class] ? self.requestedNativeRoute[@"url"] : @"";
    }
    if (!rawURL.length && self.channelID.length) {
        NSDictionary *ch = [self channelWithID:self.channelID];
        if ([ch[@"remoteURL"] isKindOfClass:NSString.class] && [ch[@"remoteURL"] length]) {
            rawURL = ch[@"remoteURL"];
        } else {
            NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];
            for (NSDictionary *r in routes) {
                if (!CCTVRouteRequiresSDK(r) && [r[@"url"] isKindOfClass:NSString.class] && [r[@"url"] length]) {
                    rawURL = r[@"url"];
                    break;
                }
            }
            if (!rawURL.length && [routes.firstObject[@"url"] isKindOfClass:NSString.class]) {
                rawURL = routes.firstObject[@"url"];
            }
        }
    }
    if (!rawURL.length) return @"";
    NSURLComponents *parts = [NSURLComponents componentsWithString:rawURL];
    NSString *host = parts.host.lowercaseString ?: @"";
    if ([@[@"127.0.0.1", @"localhost", @"::1"] containsObject:host]) {
        NSString *lanIP = CCTVDeviceLANIPv4Address();
        if (lanIP.length && ![lanIP isEqualToString:@"127.0.0.1"]) {
            parts.host = lanIP;
            if (parts.URL.absoluteString.length) return parts.URL.absoluteString;
        }
    }
    return rawURL;
}

- (BOOL)switchToAirPlayCompatibleRouteIfPossible {
    if (!self.channelID.length) return NO;
    NSDictionary *ch = [self channelWithID:self.channelID];
    if (!ch) return NO;
    NSArray *routes = [ch[@"routes"] isKindOfClass:NSArray.class] ? ch[@"routes"] : @[];
    for (NSDictionary *candidate in routes) {
        if (!CCTVRouteRequiresSDK(candidate)) {
            [self log:@"已切换至 AirPlay 兼容明文线路 (%@)", candidate[@"provider"] ?: @"HLS"];
            [self playChannel:ch route:candidate];
            return YES;
        }
    }
    NSDictionary *alt = [self nextUntriedAlternateChannel];
    if (alt) {
        [self log:@"已切换至同名订阅源以支持 AirPlay 视频投屏"];
        [self startRemoteChannel:alt];
        return YES;
    }
    return NO;
}

- (void)handleAudioRouteChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *airPlayDevice = [self activeAirPlayDeviceName];
        self.activeAirPlayRouteName = airPlayDevice;
        BOOL isAirPlay = (airPlayDevice.length > 0);
        self.catalogFloatingAirPlayPicker.tintColor = isAirPlay ? HostAccent() : HostText();
        if (self.castBtn) {
            [self.castBtn setTitle:isAirPlay ? @"投屏中" : @"投屏" forState:UIControlStateNormal];
            self.castBtn.layer.borderColor = isAirPlay ? HostAccent().CGColor : [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        }
        if (isAirPlay && self.currentPlayer && !self.avPlayer && self.channelID.length) {
            if (![self switchToAirPlayCompatibleRouteIfPossible]) {
                self.infoLabel.hidden = NO;
                self.infoLabel.text = [NSString stringWithFormat:@"📺 已连接 %@ · 加密频道建议使用系统「屏幕镜像」", airPlayDevice];
            }
        } else if (isAirPlay && self.avPlayer) {
            self.infoLabel.hidden = NO;
            self.infoLabel.text = [NSString stringWithFormat:@"📺 正在投屏至 %@", airPlayDevice];
        }
    });
}

- (void)showCastingCenter {
    NSString *airPlayDevice = [self activeAirPlayDeviceName];
    NSString *castURL = [self castableStreamURLForCurrentChannel];
    NSString *statusSummary = airPlayDevice.length
        ? [NSString stringWithFormat:@"当前已连接：%@\n支持 AirPlay 无线投屏及智能电视局域网拉流。", airPlayDevice]
        : @"支持 AirPlay 无线音视频投屏、智能切换明文投屏线路及局域网电视地址复制。";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:self.channelName.length ? [NSString stringWithFormat:@"%@ · 投屏中心", self.channelName] : @"投屏中心"
                                                                   message:statusSummary
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:airPlayDevice.length ? [NSString stringWithFormat:@"切换 / 断开 AirPlay 设备（%@）", airPlayDevice] : @"选择 AirPlay 投屏设备"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [weakSelf triggerSystemAirPlayPicker];
    }]];
    if (self.channelID.length && self.currentPlayer && !self.avPlayer) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"切换 AirPlay 高清兼容线路（解决有声无画）"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            if (![weakSelf switchToAirPlayCompatibleRouteIfPossible]) {
                [weakSelf showServiceError:@"该央视加密频道暂无明文 HLS 线路，请从 iOS 控制中心打开「屏幕镜像」进行整屏投射，或在「频道」页导入订阅源。"];
            }
        }]];
    }
    if (castURL.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"复制局域网 / 电视端投屏流地址"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = castURL;
            weakSelf.infoLabel.hidden = NO;
            weakSelf.infoLabel.text = @"已复制投屏流地址 · 可粘贴至电视端 VLC / Kodi / 播放器";
            [weakSelf log:@"已复制投屏流地址"];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"分享直播流地址到其他设备"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            NSURL *shareURL = [NSURL URLWithString:castURL];
            NSArray *items = shareURL ? @[shareURL] : @[castURL];
            UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
            activity.popoverPresentationController.sourceView = weakSelf.castBtn ?: weakSelf.view;
            activity.popoverPresentationController.sourceRect = (weakSelf.castBtn ?: weakSelf.view).bounds;
            [weakSelf presentViewController:activity animated:YES completion:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = self.castBtn && !self.castBtn.hidden ? self.castBtn : (self.catalogMoreButton ?: self.view);
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showMorePlaybackActions {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:self.channelName ?: @"播放操作" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"投屏中心（AirPlay / 局域网电视）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self showCastingCenter]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:self.fullscreen?@"退出全屏":@"全屏" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self toggleFullscreen]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"上一个频道" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self playAdjacentChannel:-1];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"下一个频道" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self playAdjacentChannel:1];}]];
    if(self.nativePlaybackFailed||self.remotePlaybackFailed)[sheet addAction:[UIAlertAction actionWithTitle:@"换线路 / 换源重试" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self retryPlaybackWithAlternateSource];}]];
    if(self.currentPlayer && !self.avPlayer){
        [sheet addAction:[UIAlertAction actionWithTitle:@"时移 / 回看" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self showNativeTimeshiftActions];}]];
        if(self.nativeTimeShiftActive)[sheet addAction:[UIAlertAction actionWithTitle:@"返回直播" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){[self returnToNativeLive];}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"播放信息" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self showPlaybackInfo]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"画中画" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ [self togglePiP]; }]];
    NSString *sleepTitle=self.liveSleepMinutes>0?[NSString stringWithFormat:@"睡眠定时（当前 %ld 分钟）",(long)self.liveSleepMinutes]:@"睡眠定时关闭";
    [sheet addAction:[UIAlertAction actionWithTitle:sleepTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        UIAlertController *sleepSheet=[UIAlertController alertControllerWithTitle:@"直播睡眠定时" message:@"到点后自动暂停直播并释放解码器" preferredStyle:UIAlertControllerStyleActionSheet];
        for(NSNumber *mins in @[@0,@15,@30,@60]){NSInteger m=mins.integerValue;NSString *label=m==0?@"关闭定时":[NSString stringWithFormat:@"%ld 分钟后暂停",(long)m];[sleepSheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *act){[self configureLiveSleepTimerMinutes:m];}]];}
        [sleepSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        sleepSheet.popoverPresentationController.sourceView=self.moreBtn;sleepSheet.popoverPresentationController.sourceRect=self.moreBtn.bounds;
        [self presentViewController:sleepSheet animated:YES completion:nil];
    }]];
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
- (void)refreshConfigurationPage {if([self.tabPage isKindOfClass:ConfigCenterViewController.class])[(ConfigCenterViewController *)self.tabPage reloadProfiles];[self updateLiveResourceCapsule];}
- (void)importPlaylistData:(NSData *)data name:(NSString *)name {
    if(![self importPlaylistData:data name:name metadata:@{}])[self showServiceError:@"文件须为 UTF-8 M3U 播放列表，包含有效 HTTP/HTTPS 频道，且不超过 10MB。"];
}
- (NSString *)importPlaylistData:(NSData *)data name:(NSString *)name metadata:(NSDictionary *)metadata {
    NSString *text=data.length<=10*1024*1024?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;NSArray *channels=text.length?[M3UParser parse:text baseURL:nil]:@[];if(!channels.count)return nil;
    NSString *source=[@"local-playlist:" stringByAppendingString:NSUUID.UUID.UUIDString];NSArray *snapshot=CCTVPlaylistSnapshotRows(channels,source);NSMutableDictionary *values=[@{@"name":name?:@"本地播放列表",@"text":text,@"cachedChannels":snapshot} mutableCopy];if([metadata isKindOfClass:NSDictionary.class])[values addEntriesFromDictionary:metadata];[ProfileStore update:source values:values];[self.subscriptionURLs addObject:source];[NSUserDefaults.standardUserDefaults setObject:[ProfileStore orderedSources:self.subscriptionURLs.allObjects] forKey:@"subscriptions"];[self applyPlaylistText:text source:source];return source;
}
- (void)replaceSubscription:(NSString *)source URL:(NSString *)url values:(NSDictionary *)values disabled:(BOOL)disabled completion:(void (^)(NSError *error))completion {
    if([self.subscriptionURLs containsObject:url]){completion([NSError errorWithDomain:@"SubscriptionEdit" code:1 userInfo:@{NSLocalizedDescriptionKey:@"该地址已存在，请编辑已有订阅"}]);return;}
    if(!self.subscriptionEditTasks)self.subscriptionEditTasks=[NSMutableDictionary dictionary];
    [self.subscriptionEditTasks[source] cancel];
    UIAlertController *progress=[UIAlertController alertControllerWithTitle:@"正在验证新订阅" message:@"验证成功后替换；原订阅和频道暂时保留。" preferredStyle:UIAlertControllerStyleAlert];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    __weak typeof(self) weakSelf=self;__block NSURLSessionDownloadTask *task=nil;
    task=[NSURLSession.sharedSession downloadTaskWithRequest:request completionHandler:^(NSURL *location,NSURLResponse *response,NSError *error){
        NSNumber *size=nil;[location getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
        NSData *data=(location&&size&&!error&&status>=200&&status<300&&size.unsignedLongLongValue<=10*1024*1024)?[NSData dataWithContentsOfURL:location]:nil;
        NSString *text=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
        NSArray *channels=text.length?[M3UParser parse:text baseURL:response.URL?:[NSURL URLWithString:url]]:nil;
        dispatch_async(dispatch_get_main_queue(),^{RootViewController *owner=weakSelf;if(!owner||owner.subscriptionEditTasks[source]!=(id)task)return;[owner.subscriptionEditTasks removeObjectForKey:source];
            [progress dismissViewControllerAnimated:YES completion:^{
                if(!channels.count){completion(error?:[NSError errorWithDomain:@"SubscriptionEdit" code:2 userInfo:@{NSLocalizedDescriptionKey:@"新地址没有返回有效频道，已保留原订阅"}]);return;}
                if(![owner.subscriptionURLs containsObject:source]){completion([NSError errorWithDomain:@"SubscriptionEdit" code:3 userInfo:@{NSLocalizedDescriptionKey:@"原订阅已被移除，未保存此次编辑"}]);return;}
                NSArray *ordered=[ProfileStore orderedSources:owner.subscriptionURLs.allObjects];NSMutableArray *replacement=[ordered mutableCopy];NSUInteger index=[replacement indexOfObject:source];if(index!=NSNotFound)replacement[index]=url;
                BOOL selected=[owner.activeSource isEqual:source];NSMutableDictionary *metadata=[values mutableCopy];[metadata removeObjectForKey:@"cachedChannels"];[metadata removeObjectForKey:@"detectedEPGURL"];
                NSString *epg=[M3UParser epgURL:text baseURL:response.URL?:[NSURL URLWithString:url]];if(epg.length)metadata[@"detectedEPGURL"]=epg;
                [owner deleteSubscription:source];[owner.subscriptionURLs addObject:url];[ProfileStore update:url values:metadata];
                NSMutableArray *disabledSources=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"]?:@[] mutableCopy];[disabledSources removeObject:source];[disabledSources removeObject:url];if(disabled)[disabledSources addObject:url];[NSUserDefaults.standardUserDefaults setObject:disabledSources forKey:@"disabledSubscriptions"];
                [NSUserDefaults.standardUserDefaults setObject:replacement forKey:@"subscriptions"];
                if(selected)owner.activeSource=url;[owner.epgCache removeAllObjects];[owner installPlaylist:channels source:url];[owner refreshConfigurationPage];completion(nil);
            }];
        });
    }];
    self.subscriptionEditTasks[source]=(id)task;
    [progress addAction:[UIAlertAction actionWithTitle:@"取消验证" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action){RootViewController *owner=weakSelf;if(owner.subscriptionEditTasks[source]==(id)task)[owner.subscriptionEditTasks removeObjectForKey:source];[task cancel];completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);}]];
    [self.navigationController.topViewController presentViewController:progress animated:YES completion:^{[task resume];}];
}
- (void)editProfile:(NSString *)source {[self openSubscriptionProfile:source editing:YES];}
- (void)openSubscriptionProfile:(NSString *)source editing:(BOOL)editing {
    SubscriptionResourceViewController *page=[SubscriptionResourceViewController new];page.source=source;page.initiallyEditing=editing;__weak typeof(self) weakSelf=self;__weak SubscriptionResourceViewController *weakPage=page;
    page.profileProvider=^{RootViewController *owner=weakSelf;NSString *current=weakPage.source?:source;for(NSDictionary *profile in [owner configurationProfiles])if([profile[@"source"] isEqual:current])return profile;return @{};};
    page.onCommit=^(NSString *name,NSString *url,NSString *epg,void (^completion)(NSError *error)){
        RootViewController *owner=weakSelf;NSString *current=weakPage.source?:source;if(!owner){completion([NSError errorWithDomain:@"SubscriptionEdit" code:1 userInfo:@{NSLocalizedDescriptionKey:@"页面已关闭"}]);return;}
        NSMutableDictionary *values=[[ProfileStore metadata:current] mutableCopy];values[@"name"]=name;values[@"epgURL"]=epg;
        if(![url isEqual:current]){BOOL disabled=[[NSUserDefaults.standardUserDefaults arrayForKey:@"disabledSubscriptions"] containsObject:current];[owner replaceSubscription:current URL:url values:values disabled:disabled completion:completion];return;}
        [ProfileStore update:current values:values];[owner.epgCache removeAllObjects];[owner applyFilter];[owner refreshConfigurationPage];completion(nil);
    };
    page.onOpen=^{RootViewController *owner=weakSelf;if(!owner)return;NSString *current=weakPage.source?:source;[owner.navigationController popToViewController:owner animated:NO];[owner selectBottomTab:(id)owner.bottomBar.arrangedSubviews[current.length?1:0]];owner.activeSource=current;[owner applyFilter];[owner updateLiveResourceCapsule];};
    page.onRefresh=^{[weakSelf fetchSubscription:weakPage.source?:source silent:NO];};page.onExport=^{[weakSelf exportResource:weakPage.source?:source format:@"single"];};page.onRecheckHealth=^{[weakSelf recheckProfileHealth:weakPage.source?:source];};page.onRematchEPG=^{[weakSelf rematchEPGForProfile:weakPage.source?:source];};page.onDelete=^{[weakSelf deleteSubscription:weakPage.source?:source];[weakSelf refreshConfigurationPage];};
    if(self.activeTab==3)[(ConfigCenterViewController *)self.tabPages[@3] prepareForNavigationTransition];[self.navigationController pushViewController:page animated:YES];
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
    CGFloat previewWidth=MIN(280,self.view.bounds.size.width-32);
    UIView *box=[[UIView alloc] initWithFrame:CGRectMake(16,self.view.safeAreaInsets.top+12,previewWidth,158)];box.backgroundColor=UIColor.blackColor;box.layer.cornerRadius=14;box.clipsToBounds=YES;self.previewBox=box;[self.view addSubview:box];self.previewLayer.frame=box.bounds;self.previewLayer.videoGravity=AVLayerVideoGravityResizeAspect;[box.layer addSublayer:self.previewLayer];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];[close setTitle:@"关闭预览" forState:UIControlStateNormal];close.backgroundColor=[UIColor colorWithWhite:0 alpha:0.6];close.frame=CGRectMake(MAX(0,previewWidth-100),0,MIN(100,previewWidth),44);[close addTarget:self action:@selector(stopPreview) forControlEvents:UIControlEventTouchUpInside];[box addSubview:close];[self.previewPlayer play];__weak typeof(self) w=self;self.previewTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t){[w stopPreview];}];
}
- (void)stopPreview {[self.previewTimer invalidate];self.previewTimer=nil;[self.previewPlayer pause];[self.previewPlayer.currentItem.asset cancelLoading];[self.previewPlayer replaceCurrentItemWithPlayerItem:nil];self.previewPlayer=nil;self.previewLayer.player=nil;[self.previewLayer removeFromSuperlayer];self.previewLayer=nil;[self.previewBox removeFromSuperview];self.previewBox=nil;}
- (void)showHistory {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"最近观看" message:self.recents.count?nil:@"还没有观看记录" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *r in self.recents){NSString *title=[r[@"name"] isKindOfClass:NSString.class]?r[@"name"]:([r[@"id"] isKindOfClass:NSString.class]?r[@"id"]:@"");if(!title.length)title=@"未知频道";[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSDictionary *ch=[self channelWithID:r[@"id"]];if(ch)[self selectChannel:ch];else[self showServiceError:@"该频道已不在配置中，请刷新或重新导入原配置。"];}]];}
    if(self.recents.count)[a addAction:[UIAlertAction actionWithTitle:@"清空历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[self.recents removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"recents"];[self applyFilter];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)showFavoriteManager {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"整理收藏" message:self.favorites.count?@"点选频道可移到收藏首位；频道列表左滑可取消收藏。":@"还没有收藏频道，长按频道即可收藏。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSString *cid in self.favorites){NSDictionary *ch=[self channelWithID:cid];NSString *title=([ch[@"name"] isKindOfClass:NSString.class]&&[ch[@"name"] length])?ch[@"name"]:cid;[a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[self.favorites removeObject:cid];[self.favorites insertObject:cid atIndex:0];[NSUserDefaults.standardUserDefaults setObject:self.favorites forKey:@"favorites"];[self applyFilter];}]];}
    if(self.favorites.count)[a addAction:[UIAlertAction actionWithTitle:@"清空收藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[self.favorites removeAllObjects];[NSUserDefaults.standardUserDefaults setObject:@[] forKey:@"favorites"];[self configureCatalogNavigation];[self applyFilter];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.bottomBar;a.popoverPresentationController.sourceRect=self.bottomBar.bounds;[self presentViewController:a animated:YES completion:nil];
}
- (void)cacheXMLRows:(NSArray *)rows channel:(NSString *)cid {
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;NSString *current=nil,*next=nil;for(NSDictionary *r in rows){if(![r isKindOfClass:NSDictionary.class])continue;double start=[r[@"start"] doubleValue],end=[r[@"end"] doubleValue];NSString *title=[r[@"title"] isKindOfClass:NSString.class]?r[@"title"]:nil;if(now>=start&&now<end)current=title;else if(start>now&&!next)next=title;}
    if(current||next){self.epgCache[cid]=@{@"now":current?:@"",@"next":next?:@"",@"ts":@(now)};[self trimEPGCache];}
}
- (void)trimEPGCache {
    // EPG 缓存无上限会随频道浏览持续增长；保留最近的 128 条，按 ts 淘汰最旧。
    while(self.epgCache.count>128){
        NSString *oldest=nil;NSTimeInterval oldestTS=DBL_MAX;
        for(NSString *key in self.epgCache){NSTimeInterval ts=[self.epgCache[key][@"ts"] doubleValue];if(ts<oldestTS){oldestTS=ts;oldest=key;}}
        if(!oldest.length)break;
        [self.epgCache removeObjectForKey:oldest];
    }
}
@end
