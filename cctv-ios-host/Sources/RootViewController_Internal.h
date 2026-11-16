#pragma once
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#import "HostTabBarController.h"
#import "HostChannelCatalogController.h"
#import "PlaybackOverlayController.h"
#import "MediaPlaybackCicadaAdapter.h"
#import "MediaPlaybackDecodeRouter.h"
#import "MediaCapabilityRegistry.h"
#import "PlaybackCoordinator.h"
#import "MediaJARSource.h"
#import "MediaRelayDiagnostics.h"
#import "RootViewController.h"
#import "MediaSubscriptionToken.h"
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
#import "MediaChannelProbe.h"
#import "TVBoxCatalogStore.h"
#import "TVBoxCatalogPackageExporter.h"
#import "TVBoxCatalogBulkImporter.h"
#import "TVBoxCatalogDownloader.h"
#import "TVBoxCatalogViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
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
    token=MediaLytvsSubscriptionToken(token);
    NSData *data=[token dataUsingEncoding:NSUTF8StringEncoding];if(!data.length||data.length>512)return NO;
    NSMutableDictionary *attributes=[@{(__bridge id)kSecValueData:data,(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly} mutableCopy];
    NSDictionary *query=CCTVTVBoxTokenKeychainQuery();OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)attributes);
    if(status==errSecItemNotFound){NSMutableDictionary *item=[query mutableCopy];[item addEntriesFromDictionary:attributes];status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);}
    return status==errSecSuccess;
}
static NSString *CCTVTVBoxTokenFromInput(NSString *input) {
    NSString *value=[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";NSURL *u=CCTVURLFromPossiblyUnescapedString(value);NSURLComponents *parts=u?[NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO]:[NSURLComponents componentsWithString:value];
    if([parts.host.lowercaseString isEqual:@"sub.lytvs.top"]){
        for(NSURLQueryItem *item in parts.queryItems)if([@[@"token",@"tk"] containsObject:item.name.lowercaseString]&&item.value.length&&![item.value isEqualToString:CCTVTVBoxTokenPlaceholder])return MediaLytvsSubscriptionToken(item.value);
        NSString *path=parts.path?:@"";
        if(path.length){
            NSRegularExpression *pathRe=[NSRegularExpression regularExpressionWithPattern:@"(?:^|[_/-])tk_([A-Za-z0-9]{6,64})(?:\\.[A-Za-z0-9]+|$)" options:NSRegularExpressionCaseInsensitive error:NULL];
            NSTextCheckingResult *match=[pathRe firstMatchInString:path options:0 range:NSMakeRange(0,path.length)];
            if(match&&match.numberOfRanges>1){
                NSString *tk=[path substringWithRange:[match rangeAtIndex:1]];
                if(tk.length&&![tk isEqualToString:CCTVTVBoxTokenPlaceholder])return MediaLytvsSubscriptionToken(tk);
            }
        }
        return nil;
    }
    if(value.length>512||[value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound)return nil;return MediaLytvsSubscriptionToken(value);
}
static NSString *CCTVTVBoxStoredSubscriptionToken(void) {
    NSMutableDictionary *query=[CCTVTVBoxTokenKeychainQuery() mutableCopy];query[(__bridge id)kSecReturnData]=@YES;query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result=NULL;if(SecItemCopyMatching((__bridge CFDictionaryRef)query,&result)==errSecSuccess&&result){
        NSData *data=(__bridge_transfer NSData *)result;NSString *stored=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if(stored.length){NSString *normalized=MediaLytvsSubscriptionToken(stored);if(normalized.length&&![normalized isEqualToString:stored])CCTVTVBoxSaveSubscriptionToken(normalized);return normalized?:@"";}
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
    return @"";
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
        if(channel.catchupSource.length){row[@"catchupSource"]=channel.catchupSource;row[@"catchupMode"]=channel.catchupMode?:@"default";row[@"catchupDays"]=@(channel.catchupDays);row[@"tvgShift"]=@(channel.tvgShift);}
        if(channel.epgID.length)row[@"epgID"]=channel.epgID;if(channel.tvgName.length)row[@"tvgName"]=channel.tvgName;if(channel.logo.length)row[@"logo"]=channel.logo;if(channel.headers.count)row[@"headers"]=channel.headers;
        if([NSPropertyListSerialization propertyList:row isValidForFormat:NSPropertyListBinaryFormat_v1_0])[rows addObject:row.copy];
    }
    return rows.copy;
}
extern void *const kAVItemStatusContext;
extern void *const kAVLayerFrameContext;
NSCache<NSString *,UIImage *> *CCTVSharedChannelLogoCache(void);
// 这两个键名来自 CNPlayerSDK 导出常量（值即常量名本身），SDK 缺 Title 会直接拒播并报错误码 4012
static NSString *const kOptTitle = @"CNPlayerConfigOptionKey_Title";
static NSString *const kOptDefaultRate = @"CNPlayerConfigOptionKey_DefaultRate";
static NSString *const kOptUserID = @"CNPlayerConfigOptionKey_UserID";
static NSString *const kOptURLChannelIDForStats = @"CNPlayerConfigOptionKey_URLSource_VID_ChannelIDUsedStat";
static UIImage *CCTVChannelLogoImage(NSDictionary *channel) {
    NSString *identifier=[channel[@"id"] isKindOfClass:NSString.class]?channel[@"id"]:@"";
    if(identifier.length){UIImage *asset=[UIImage imageNamed:[@"ChannelLogo_" stringByAppendingString:identifier]];if(asset)return asset;}
    NSString *canonicalID=[ProfileStore canonicalStationIDForChannel:channel]?:@"";
    if(canonicalID.length){UIImage *asset=[UIImage imageNamed:[@"ChannelLogo_" stringByAppendingString:canonicalID]];if(asset)return asset;}
    NSCache<NSString *,UIImage *> *cache=CCTVSharedChannelLogoCache();
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
static BOOL CCTVChannelNeedsDarkLogoBacking(NSDictionary *channel, NSString *identifier) {
    if (CCTVChannelLogoNeedsDarkBacking(identifier)) return YES;
    NSString *canonical = [ProfileStore canonicalStationIDForChannel:channel] ?: @"";
    return CCTVChannelLogoNeedsDarkBacking(canonical);
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
    NSString *canonical=[ProfileStore canonicalStationIDForChannel:channel];
    if(canonical.length)return [@"tvg-id:" stringByAppendingString:canonical];
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
- (void)reloadThemeAppearance;
@end

@interface CCTVChannelListCell : UITableViewCell
@property(nonatomic,strong) UIImageView *previewThumbView;
@property(nonatomic,strong) UILabel *telemetryBadgeLabel;
@end

@interface RootViewController () <PlaybackSession, MediaPlaybackCicadaAdapterDelegate, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIDocumentPickerDelegate, AVPlayerViewControllerDelegate, UINavigationControllerDelegate>
@property(nonatomic,strong) HostTabBarController *hostTabController;
@property(nonatomic,strong) HostChannelCatalogController *channelCatalogController;
@property(nonatomic,strong) PlaybackOverlayController *liveControlsOverlay;
@property(nonatomic) BOOL livePanActive;
@property(nonatomic) BOOL livePanRightSide;
@property(nonatomic) BOOL livePanIgnored;
@property(nonatomic,strong) MediaPlaybackCicadaAdapter *remoteAdapter;
@property(nonatomic) BOOL remoteTriedCicada;
@property(nonatomic,strong) ResourceImportWorkflowViewController *resourceImportWorkflow;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSURLSessionTask *> *subscriptionEditTasks;
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *channelPreviewSnapshots;
@property (nonatomic, strong) NSMutableSet<NSString *> *channelPreviewInflight;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVAssetImageGenerator *> *channelPreviewGenerators;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *channelPreviewCapturedAt;
@property (nonatomic, strong) NSMutableSet<NSString *> *channelPreviewRefreshPending;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *channelTelemetryStore;
@property (nonatomic, strong) NSMutableSet<NSString *> *channelTelemetryInflight;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MediaChannelProbe *> *channelTelemetryTasks;
@property (nonatomic, strong) UIStackView *controlBar;
@property (nonatomic, strong) UIButton *liveResourceCapsule;
@property (nonatomic, strong) UIButton *playPauseBtn;
@property (nonatomic, strong) UIButton *muteBtn;
@property (nonatomic, strong) UIButton *fullscreenBtn;
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
@property (nonatomic, assign) CGSize liveVideoSize;
@property (nonatomic, assign) double liveBitrateBps;
@property (nonatomic, assign) double livePeakBitrateBps;
@property (nonatomic, assign) double liveFPS;
@property (nonatomic, copy) NSString *liveVideoCodec;
@property (nonatomic, copy) NSString *liveAudioCodec;
@property (nonatomic, assign) NSInteger liveStallCount;
@property (nonatomic, strong) UIButton *playbackQualityBadgeBtn;
@property (nonatomic, strong) NSTimer *liveQualityBadgeTimer;
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
@property (nonatomic, strong) NSArray<NSDictionary *> *channelIndexSourceArray;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *channelIndexByID;
@property (nonatomic, strong) NSArray<NSDictionary *> *shownChannelIndexSourceArray;
@property (nonatomic, strong) NSDictionary<NSString *, NSNumber *> *shownChannelIndexByID;
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
@property(nonatomic,strong) NSMutableArray<NSString *> *recentVODServiceIDs;
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
@end
- (BOOL)sessionHasContent;
- (BOOL)sessionWantsPlayback;
- (BOOL)sessionIsPlaying;
- (void)sessionPlay;
- (void)sessionPause;
- (BOOL)sessionStep:(NSInteger)direction;
- (void)sessionMediaServicesReset;
- (BOOL)shouldAutorotate;
- (UIInterfaceOrientationMask)supportedInterfaceOrientations;
- (void)viewDidLoad;
- (void)installBundledMediaResourcesIfNeeded;
- (void)viewDidAppear:(BOOL)animated;
- (BOOL)shouldHideNavigationBarForVisibleController:(UIViewController *)visibleController;
- (BOOL)hasVisibleExpandedLivePlayer;
- (BOOL)isExpandedLivePlayerVisible;
- (CGFloat)playerOverlayTopInset;
- (UIEdgeInsets)playerOverlayInsets;
- (UIStatusBarStyle)preferredStatusBarStyle;
- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated;
- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated;
- (void)dealloc;
- (void)didReceiveMemoryWarning;
- (void)onBackground;
- (void)onForeground;
- (void)checkVisibleMediaAfterActivation;
- (void)restoreDiagnosticLog;
- (void)persistDiagnosticLine:(NSString *)line;
- (void)scheduleDiagnosticLogFlush;
- (void)flushDiagnosticLog;
- (void)log:(NSString *)format, ...;
- (void)togglePiP;
- (void)buildPlayer;
- (UIButton *)barButton:(NSString *)title action:(SEL)action;
- (void)updatePlaybackControlAccessibility;
- (void)setLiveOverlayHidden:(BOOL)hidden;
- (PlaybackOverlayController *)liveOverlayPolicy;
- (void)toggleOverlay;
- (void)buildList;
- (void)openDiagnosticLog;
- (void)logPluginLine:(NSString *)line identifier:(NSString *)identifier name:(NSString *)name;
- (void)clearServiceLogHandlers:(NSString *)identifier;
- (void)openDiagnosticLogForIdentifier:(NSString *)identifier name:(NSString *)name;
- (void)openPluginRunLogForIdentifier:(NSString *)identifier name:(NSString *)name run:(NSDictionary *)run;
- (void)shareDiagnosticLogAtURL:(NSURL *)source;
- (NSString *)safeResourceExportName:(NSString *)name;
- (NSURL *)writeResourceExportData:(NSData *)data name:(NSString *)name extension:(NSString *)extension error:(NSError **)error;
- (void)exportCatalogSingleResource:(NSString *)source resource:(NSDictionary *)resource kind:(NSString *)kind index:(NSUInteger)index;
- (void)exportCatalogPackage:(NSString *)identifier token:(NSString *)token;
- (void)exportResource:(NSString *)source format:(NSString *)format;
- (void)exportDiagnosticLog;
- (void)clearDiagnosticLog;
- (void)buildBottomBar;
- (void)bottomTabTapped:(UIButton *)sender;
- (void)suspendLivePlaybackForReason:(NSString *)reason;
- (void)resumeSuspendedLiveFromMiniBar;
- (void)dismissSuspendedLiveMiniBar;
- (void)configureLiveSleepTimerMinutes:(NSInteger)minutes;
- (void)updateBottomBarSelection;
- (void)selectBottomTab:(UIButton *)sender;
- (void)showTabPage:(UIViewController *)page title:(NSString *)title;
- (MediaBrowserViewController *)mediaPageCreatingIfNeeded;
- (void)openMediaTab;
- (void)playerViewController:(AVPlayerViewController *)controller willEndFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator;
- (void)playerViewControllerWillStartPictureInPicture:(AVPlayerViewController *)controller;
- (void)playerViewControllerDidStopPictureInPicture:(AVPlayerViewController *)controller;
- (void)openConfigurationTab;
- (void)viewDidLayoutSubviews;
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection;
- (void)toggleFullscreen;
- (void)relayoutPlayer;
- (void)openServicesPage;
- (void)openPluginPage;
- (void)openSettingsPage;
- (UITraitCollection *)fontSizeOverrideTraitCollection;
- (void)applyFontSizeOverride;
- (void)updateLiveScreenAwakeState;
- (void)reloadThemeAppearance;
- (SettingsViewController *)makeSettingsPage;
- (void)exportLocalConfiguration;
- (void)importLocalConfiguration;
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller;
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls;
- (void)finishConfigurationImport:(NSData *)data;
@end

@interface RootViewController (Catalog)
- (void)loadChannels;
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip;
- (NSArray<NSString *> *)currentCatalogGroupTitles;
- (void)syncGroupControlSegments;
- (void)onGroupChanged;
- (void)configureCatalogNavigation;
- (void)toggleCatalogLayout;
- (void)toggleCatalogColumns;
- (void)toggleCurrentFavorite;
- (void)playAdjacentChannel:(NSInteger)direction;
- (void)scrollCatalogToPlayingChannel;
- (UIMenu *)catalogMenu;
- (void)showCatalogSearch;
- (void)showGroupMenu;
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section;
- (CGFloat)catalogTextHeight:(NSString *)text font:(UIFont *)font width:(CGFloat)width maximumLines:(NSUInteger)maximumLines;
- (NSUInteger)sourceCountForChannel:(NSDictionary *)channel;
- (BOOL)channelSupportsCatchup:(NSDictionary *)channel;
- (NSString *)catalogSubtitleForChannel:(NSDictionary *)channel;
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip;
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip;
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip;
- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point;
- (void)selectChannel:(NSDictionary *)ch;
- (void)routePlayback:(NSDictionary *)ch;
- (NSArray *)visibleRecents;
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t;
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s;
- (void)tableView:(UITableView *)t willDisplayHeaderView:(UIView *)view forSection:(NSInteger)s;
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s;
- (NSArray<NSDictionary *> *)channelsForSection:(NSInteger)section tableView:(UITableView *)t;
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip;
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip;
- (void)loadEPGForVisibleGridItems;
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView;
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate;
- (void)reloadVisibleCatalogItemForChannelID:(NSString *)cid;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
- (void)showRoutes;
- (NSDictionary *)channelWithID:(NSString *)cid;
- (void)presentRouteSheetForChannel:(NSDictionary *)ch fromIndexPath:(NSIndexPath *)ip;
- (NSArray<NSDictionary *> *)playerCategoryRows;
- (CCTVPlaybackListPanelController *)categoryPanel;
- (CCTVPlaybackListPanelController *)routesPanel;
- (void)selectPlayerPanel;
- (void)presentSubscriptionActions:(NSDictionary *)channel sourceView:(UIView *)source;
- (NSIndexPath *)indexPathForChannelID:(NSString *)cid;
- (void)loadLogo:(NSString *)url into:(UIImageView *)iv;
- (void)updateSearchResultsForSearchController:(UISearchController *)sc;
- (void)enableNativeChannelsFromEmptyState;
- (void)resetCatalogFilterToAll;
- (UIView *)buildCatalogEmptyBackgroundViewWithMessage:(NSString *)message;
- (void)applyFilter;
- (void)rememberChannel:(NSDictionary *)ch;
- (void)onPullRefresh;
@end

@interface RootViewController (Playback)
- (void)registerCallbackProtocol;
- (void)activateAudioSession;
- (void)configureSDKLogging;
- (void)setupSDK;
- (void)playChannel:(NSDictionary *)ch route:(NSDictionary *)route;
- (void)playSelectedNativeRouteOrChannel;
- (CNPlayerSessionDelegate *)beginNativeSession;
- (void)rebuildTimeshiftController;
- (void)playViaSDKURL:(NSString *)url channelID:(NSString *)cid title:(NSString *)title;
- (void)playViaSDK:(NSString *)cid title:(NSString *)title;
- (void)recordStartupStage:(NSString *)stage;
- (void)stopPlayback;
- (void)attachVideoView;
- (void)togglePlayPause;
- (void)toggleMute;
- (UISlider *)systemVolumeSlider;
- (void)onPan:(UIPanGestureRecognizer *)g;
- (void)setupRemoteCommands;
- (MPRemoteCommandHandlerStatus)togglePlayPauseForRemoteCommand:(MPRemoteCommandEvent *)event;
- (MPRemoteCommandHandlerStatus)stepToNextChannelForRemoteCommand:(MPRemoteCommandEvent *)event;
- (MPRemoteCommandHandlerStatus)stepToPreviousChannelForRemoteCommand:(MPRemoteCommandEvent *)event;
- (void)updateNowPlaying;
- (void)playRemote:(NSDictionary *)ch;
- (void)startRemoteChannel:(NSDictionary *)ch;
- (void)continueRemotePlaybackForURL:(NSString *)u service:(NSDictionary *)service generation:(NSUInteger)generation;
- (void)failRemoteReadiness:(NSError *)error generation:(NSUInteger)generation;
- (BOOL)startRemoteCicada:(NSString *)address generation:(NSUInteger)generation;
- (void)cicadaAdapterDidShowFirstFrame:(id)adapter;
- (void)cicadaAdapter:(id)adapter didUpdateVideoSize:(CGSize)size rotation:(NSInteger)rotation;
- (void)cicadaAdapter:(id)adapter didUpdateDownloadSpeed:(double)bitsPerSecond;
- (void)cicadaAdapter:(id)adapter didFailWithError:(NSError *)error;
- (void)cicadaAdapterDidComplete:(id)adapter;
- (void)startRemoteURL:(NSString *)url generation:(NSUInteger)generation;
- (void)avItemStalled:(NSNotification *)n;
- (void)recoverRemoteFailureForItem:(AVPlayerItem *)item error:(NSError *)error;
- (void)avItemFailed:(NSNotification *)n;
- (NSDictionary *)nextUntriedAlternateChannel;
- (void)tryAlternateSource;
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj change:(NSDictionary *)change context:(void *)context;
- (void)showNativeRouteError:(NSError *)error channel:(NSDictionary *)channel;
- (void)startWatchdog;
- (BOOL)recoverNativeStartupForReason:(NSString *)reason;
- (void)tick:(NSTimer *)timer;
- (id)callClass:(Class)cls sel:(NSString *)name args:(NSArray *)args;
- (id)call:(id)obj sel:(NSString *)name;
- (id)call:(id)obj sel:(NSString *)name args:(NSArray *)args;
- (id)invokeTarget:(id)target selector:(SEL)sel args:(NSArray *)args;
- (void)player:(id)player loadStateDidChanged:(NSUInteger)state;
- (void)player:(id)player programPubicChanged:(BOOL)isPublic;
- (void)player:(id)player programPubicChanged:(BOOL)isPublic type:(NSUInteger)sourceType error:(NSError *)error;
- (void)playerPeriodicTimeEvent:(id)player;
- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state;
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value;
- (void)prepareNextNativeChannelForGeneration:(NSUInteger)generation;
- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state;
- (void)player:(id)player playbackFailed:(NSError *)error;
- (void)retryPlaybackWithAlternateSource;
- (void)displayNativePlaybackFailure:(NSString *)stage error:(NSError *)error;
- (void)player:(id)player vdnRequestFailed:(NSError *)error;
- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate;
- (void)player:(id)player publicRequestFailed:(NSError *)error;
- (void)authFailed:(NSError *)error;
- (void)showPlaybackInfo;
- (void)showNativeTimeshiftActions;
- (void)beginNativeTransition:(NSString *)kind;
- (void)seekNativeStart:(NSTimeInterval)start end:(NSTimeInterval)end;
- (void)failNativeTransition:(NSString *)message;
- (void)returnToNativeLive;
- (NSString *)activeAirPlayDeviceName;
- (void)triggerSystemAirPlayPicker;
- (NSString *)castableStreamURLForCurrentChannel;
- (BOOL)switchToAirPlayCompatibleRouteIfPossible;
- (void)handleAudioRouteChange:(NSNotification *)notification;
- (void)showCastingCenter;
- (void)showMorePlaybackActions;
- (void)beginPlaybackPriority;
- (void)endPlaybackPriority;
- (void)refreshSubscriptionsWhenIdle;
@end

@interface RootViewController (StreamMetrics)
- (NSString *)formatBitrateMbps:(double)bps;
- (NSString *)resolutionTierTagForSize:(CGSize)size;
- (NSString *)codecNameFromFourCC:(FourCharCode)subType;
- (NSDictionary *)collectLiveStreamMetrics;
- (void)updateLiveQualityBadge;
- (void)startLiveQualityBadgeTimer;
- (PlaybackInfoViewController *)playbackInformationPage;
- (NSString *)displaySafeSourceURL:(NSString *)raw;
- (void)updatePlayerChannelLogoForChannel:(NSDictionary *)channel;
- (void)loadPlayerChannelLogoAfterFirstFrame;
- (void)handleProfileLogoOrMetadataChange:(NSNotification *)note;
- (void)applyResourcePreviewOrTelemetryToggleForSource:(NSString *)source enabled:(BOOL)enabled isPreview:(BOOL)isPreview;
- (NSString *)channelPreviewCacheDirectory;
- (NSString *)channelPreviewDiskPathForChannelID:(NSString *)cid;
- (UIImage *)cachedRealPreviewImageForChannelID:(NSString *)cid;
- (void)storeRealPreviewImage:(UIImage *)image forChannelID:(NSString *)cid;
- (void)refreshChannelPreviewSnapshotsForChannels:(NSArray<NSDictionary *> *)channels force:(BOOL)force;
- (void)detectRealPreviewFrameForChannel:(NSDictionary *)channel force:(BOOL)force;
- (UIImage *)previewImageForChannel:(NSDictionary *)channel;
- (void)captureLivePreviewSnapshotForChannelID:(NSString *)cid;
- (NSString *)primaryProbeURLForChannel:(NSDictionary *)channel;
- (NSString *)telemetryBadgeTextForChannel:(NSDictionary *)channel color:(UIColor * __autoreleasing *)colorOut;
- (NSString *)telemetryAccessibilityValueForChannel:(NSDictionary *)channel selected:(BOOL)selected;
- (void)probeTelemetryForChannel:(NSDictionary *)channel;
- (void)applyResourceChannelLogoToggleForSource:(NSString *)source enabled:(BOOL)enabled cornerOnly:(BOOL)cornerOnly;
- (NSArray<NSDictionary *> *)sameStationAlternateChannelsForChannel:(NSDictionary *)channel;
- (void)matchOfficialStationLogosAndEPGForSource:(NSString *)source;
- (void)handlePlayerChannelLogoTap;
- (void)presentStationEnhancementSheetForChannel:(NSDictionary *)channel sourceView:(UIView *)sourceView;
@end

@interface RootViewController (EPG)
- (NSString *)epgCachePath;
- (void)loadEPGCache;
- (void)saveEPGCache;
- (void)loadEPGForChannel:(NSString *)cid channel:(NSDictionary *)channel section:(NSIndexPath *)ip;
- (void)openEPG;
- (NSString *)epgIDForChannel:(NSDictionary *)ch;
- (void)openEPGforChannel:(NSString *)cid name:(NSString *)name;
- (void)restartEPGTimer;
- (void)refreshNowNext;
- (void)refreshOfficialNowNext;
- (EPGViewController *)epgPageForChannel:(NSString *)cid name:(NSString *)name;
- (void)cacheXMLRows:(NSArray *)rows channel:(NSString *)cid;
- (void)trimEPGCache;
@end

@interface RootViewController (Subscriptions)
- (NSDictionary *)resourceServiceForSource:(NSString *)source;
- (NSArray *)configurationProfiles;
- (NSDictionary *)configurationProfileForSource:(NSString *)source;
- (void)updateLiveResourceCapsule;
- (void)selectLiveResourceSource:(NSString *)source;
- (BOOL)subscriptionOwner:(NSString *)owner matchesLiveResourceSource:(NSString *)source;
- (void)deleteSubscription:(NSString *)source;
- (void)manageSubscriptions;
- (void)addSubscription;
- (void)saveImportCandidate:(NSDictionary *)candidate update:(BOOL)update completion:(void (^)(NSError *error))completion;
- (NSString *)stableURLKey:(id)value;
- (void)removeSubscriptionSource:(NSString *)sourceKey;
- (void)fetchSubscription:(NSString *)urlString silent:(BOOL)silent;
- (void)refreshSubscriptionForProfile:(NSString *)source;
- (void)recheckProfileHealth:(NSString *)source;
- (void)rematchEPGForProfile:(NSString *)source;
- (void)refreshTVBoxCatalogProfile:(NSString *)source;
- (void)installPlaylist:(NSArray<M3UChannel *> *)list source:(NSString *)sourceKey;
- (void)applyPlaylistText:(NSString *)text source:(NSString *)sourceKey;
- (void)refreshConfigurationPage;
- (void)importPlaylistData:(NSData *)data name:(NSString *)name;
- (NSString *)importPlaylistData:(NSData *)data name:(NSString *)name metadata:(NSDictionary *)metadata;
- (void)replaceSubscription:(NSString *)source URL:(NSString *)url values:(NSDictionary *)values disabled:(BOOL)disabled completion:(void (^)(NSError *error))completion;
- (void)editProfile:(NSString *)source;
- (void)openSubscriptionProfile:(NSString *)source editing:(BOOL)editing;
- (void)editEPGMapping:(NSDictionary *)ch;
- (void)showRemoteTools:(NSDictionary *)ch;
- (void)previewChannel:(NSDictionary *)ch;
- (void)stopPreview;
- (void)showHistory;
- (void)showFavoriteManager;
@end

@interface RootViewController (Services)
- (void)openPluginResource:(NSString *)source;
- (void)openServiceEditorForService:(NSDictionary *)service;
- (void)applyServiceConfigurationFrom:(NSDictionary *)previous to:(NSDictionary *)updated completion:(void (^)(NSError * _Nullable))completion;
- (void)usePluginService:(NSDictionary *)item kind:(NSString *)kind;
- (void)subscribeLiveFromCatalog:(NSDictionary *)live catalogID:(NSString *)identifier;
- (void)openTVBoxCatalog:(NSString *)identifier;
- (void)bulkImportTVBoxCatalog:(NSString *)identifier page:(TVBoxCatalogViewController *)page;
- (void)downloadPackageURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion;
- (void)downloadPackageURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSDictionary *,NSError *))completion;
- (void)downloadPackageURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers runtimeHint:(NSString *)runtimeHint completion:(void (^)(NSDictionary *,NSError *))completion;
- (void)activateNativeFallbackForTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport;
- (void)promptSubscriptionTokenForTVBoxSite:(NSDictionary *)site rawAPI:(NSString *)rawAPI browseAfterImport:(BOOL)browseAfterImport reason:(NSString *)reason;
- (void)reportAuthenticTVBoxSiteFailure:(NSDictionary *)site rawAPI:(NSString *)rawAPI url:(NSURL *)downloadURL error:(NSError *)error browseAfterImport:(BOOL)browseAfterImport;
- (void)importTVBoxSite:(NSDictionary *)site;
- (void)importTVBoxSite:(NSDictionary *)site browseAfterImport:(BOOL)browseAfterImport;
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error;
- (void)acceptImportedMedia:(NSDictionary *)service error:(NSError *)error autoBrowse:(BOOL)autoBrowse;
- (void)saveImportedMedia:(NSDictionary *)service;
- (void)saveImportedMedia:(NSDictionary *)service autoBrowse:(BOOL)autoBrowse;
- (NSString *)originForURL:(NSURL *)url;
- (NSDictionary *)localServiceForURL:(NSURL *)url;
- (NSDictionary *)localServiceForChannel:(NSDictionary *)channel URL:(NSURL *)url;
- (NSArray<NSString *> *)managedSubscriptionSourcesForService:(NSDictionary *)service excludingURL:(NSString *)url;
- (LocalServiceReadiness *)readinessForURL:(NSURL *)url service:(NSDictionary *)service;
- (BOOL)startService:(NSDictionary *)service error:(NSError **)error;
- (void)toggleService:(NSDictionary *)service enabled:(BOOL)enabled;
- (void)restartMediaService:(NSDictionary *)source completion:(void (^)(NSError *))completion;
- (void)changeService:(NSDictionary *)service enabled:(BOOL)enabled completion:(void (^)(NSError *))completion;
- (void)hibernateExcessBackgroundVODServicesKeepingID:(NSString *)activeServiceID;
- (void)completeServiceStopForIdentifier:(NSString *)serviceID;
- (void)showServiceError:(NSString *)message;
- (void)stopBuiltinPlugin;
- (void)startBuiltinPlugin;
@end


#pragma clang diagnostic pop
