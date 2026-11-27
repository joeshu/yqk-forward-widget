#import "SettingsViewController.h"
#import "HostLibraryStore.h"
#import "HostTheme.h"
#import "HostGlassActionSheetViewController.h"
#import "HostImageLoader.h"
#import "MediaMetadataCache.h"
#import "MediaPlaybackStateStore.h"
#import "MediaAdaptationMonitor.h"
#import "MediaEpisodeLayout.h"
#import "ProfileStore.h"
#import "ServiceStore.h"
#import "XMLTVStore.h"
#import "RuntimeDiagnostics.h"
#import <math.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>

static NSString *MediaMetadataCacheSummaryText(void) {
    NSDictionary *summary=MediaMetadataCache.shared.summary;
    NSString *size=[NSByteCountFormatter stringFromByteCount:[summary[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleMemory];
    return [NSString stringWithFormat:@"%lu 项 · %@",(unsigned long)[summary[@"entries"] unsignedIntegerValue],size];
}

static NSString *SettingsPlaybackRateText(void) {
    double rate=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.mediaPlaybackRate"]:1.0;
    return rate==1.0?@"正常速度":[NSString stringWithFormat:@"%.2gx",rate];
}

static NSString *SettingsVideoGravityText(void) {
    NSString *gravity=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    if([gravity isEqual:AVLayerVideoGravityResizeAspectFill])return @"铺满裁切";
    if([gravity isEqual:AVLayerVideoGravityResize])return @"拉伸填满";
    return @"画面适应";
}

static NSString *SettingsPreferredQualityText(void) {
    NSString *quality=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    if([quality isEqual:@"smooth"])return @"流畅";
    if([quality isEqual:@"hd"])return @"高清";
    if([quality isEqual:@"uhd"])return @"超清";
    return @"自动";
}

static NSString *SettingsDecodeModeText(void) {
    NSString *mode=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaDecodeMode.v1"]?:@"auto";
    if([mode isEqualToString:@"mpv"])return @"优先 MPV";
    if([mode isEqualToString:@"cicada"])return @"旧引擎兼容 (硬解)";
    if([mode isEqualToString:@"cicada_soft"])return @"旧引擎兼容 (软解)";
    return @"自动 · AVPlayer/MPV";
}

static NSString *SettingsEPGCacheFilePath(void) {
    NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES);
    return [[dirs firstObject] stringByAppendingPathComponent:@"epg-cache.json"];
}

static NSString *SettingsXMLTVCacheDirectoryPath(void) {
    NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES);
    return [[dirs firstObject] stringByAppendingPathComponent:@"XMLTV"];
}

static unsigned long long SettingsComputeEPGCacheBytesSync(void) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *attrs=[fm attributesOfItemAtPath:SettingsEPGCacheFilePath() error:NULL];
    unsigned long long total=[attrs fileSize];
    NSString *xmltvDir=SettingsXMLTVCacheDirectoryPath();
    NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:xmltvDir error:NULL];
    for(NSString *file in files){
        if(![file.pathExtension.lowercaseString isEqualToString:@"plist"])continue;
        NSDictionary *itemAttrs=[fm attributesOfItemAtPath:[xmltvDir stringByAppendingPathComponent:file] error:NULL];
        total+=[itemAttrs fileSize];
    }
    return total;
}

static NSString *SettingsImageThumbnailCacheDirectoryPath(void) {
    NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES);
    return [[dirs firstObject] stringByAppendingPathComponent:@"CCTVHostImageThumbnails"];
}

static unsigned long long SettingsComputeImageThumbnailCacheBytesSync(void) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *thumbDir=SettingsImageThumbnailCacheDirectoryPath();
    NSArray<NSString *> *files=[fm contentsOfDirectoryAtPath:thumbDir error:NULL];
    unsigned long long total=0;
    for(NSString *file in files){
        if(![file.pathExtension.lowercaseString isEqualToString:@"jpg"])continue;
        NSDictionary *attrs=[fm attributesOfItemAtPath:[thumbDir stringByAppendingPathComponent:file] error:NULL];
        total+=[attrs fileSize];
    }
    return total;
}

static unsigned long long gSettingsCachedEPGBytes = 0;
static unsigned long long gSettingsCachedImageThumbBytes = 0;
static BOOL gSettingsDiskCacheStatsReady = NO;

static void SettingsInvalidateDiskCacheStats(void) {
    gSettingsCachedEPGBytes = 0;
    gSettingsCachedImageThumbBytes = 0;
    gSettingsDiskCacheStatsReady = NO;
}

static void SettingsRefreshDiskCacheStatsAsync(void (^ _Nullable completion)(void)) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        q = dispatch_queue_create("com.cctvhost.settings.cachestats", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(q, ^{
        unsigned long long epgBytes = SettingsComputeEPGCacheBytesSync();
        unsigned long long imgBytes = SettingsComputeImageThumbnailCacheBytesSync();
        dispatch_async(dispatch_get_main_queue(), ^{
            gSettingsCachedEPGBytes = epgBytes;
            gSettingsCachedImageThumbBytes = imgBytes;
            gSettingsDiskCacheStatsReady = YES;
            if (completion) completion();
        });
    });
}

static unsigned long long SettingsEPGCacheBytes(void) {
    return gSettingsDiskCacheStatsReady ? gSettingsCachedEPGBytes : 0;
}

static NSString *SettingsEPGCacheSizeText(void) {
    unsigned long long bytes=SettingsEPGCacheBytes();
    if(bytes==0)return @"无缓存 · 下次打开频道时重新获取";
    NSString *size=[NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleMemory];
    return [NSString stringWithFormat:@"%@ · 下次打开频道时重新获取",size];
}

static unsigned long long SettingsImageThumbnailCacheBytes(void) {
    return gSettingsDiskCacheStatsReady ? gSettingsCachedImageThumbBytes : 0;
}

static NSString *SettingsCompactCacheSizeText(void) {
    unsigned long long epgBytes=SettingsEPGCacheBytes();
    unsigned long long imageBytes=SettingsImageThumbnailCacheBytes();
    NSDictionary *mediaSummary=MediaMetadataCache.shared.summary;
    unsigned long long mediaBytes=[mediaSummary[@"bytes"] unsignedLongLongValue];
    NSUInteger mediaEntries=[mediaSummary[@"entries"] unsignedIntegerValue];
    unsigned long long total=epgBytes+imageBytes+mediaBytes;
    if(total==0&&mediaEntries==0)return @"无缓存";
    return [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleMemory];
}

static NSString *SettingsAllCachesSummaryText(void) {
    unsigned long long epgBytes=SettingsEPGCacheBytes();
    unsigned long long imageBytes=SettingsImageThumbnailCacheBytes();
    NSDictionary *mediaSummary=MediaMetadataCache.shared.summary;
    unsigned long long mediaBytes=[mediaSummary[@"bytes"] unsignedLongLongValue];
    NSUInteger mediaEntries=[mediaSummary[@"entries"] unsignedIntegerValue];
    unsigned long long total=epgBytes+imageBytes+mediaBytes;
    if(total==0&&mediaEntries==0)return @"节目单、台标与影视元数据缓存 · 当前无磁盘缓存";
    NSString *totalText=[NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleMemory];
    NSString *epgText=epgBytes?[NSByteCountFormatter stringFromByteCount:(long long)epgBytes countStyle:NSByteCountFormatterCountStyleMemory]:@"0 KB";
    return [NSString stringWithFormat:@"共占用 %@（节目单 %@ · 影视元数据 %lu 项）",totalText,epgText,(unsigned long)mediaEntries];
}

static BOOL SettingsRemoveEPGCacheFile(void) {
    NSString *p=SettingsEPGCacheFilePath();
    NSError *error=nil;
    BOOL removed=![NSFileManager.defaultManager fileExistsAtPath:p]||[NSFileManager.defaultManager removeItemAtPath:p error:&error];
    [[XMLTVStore shared] clear];
    SettingsInvalidateDiskCacheStats();
    return removed;
}

static NSString *SettingsMediaDisplaySummaryText(void) {
    NSInteger cols=[[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.mediaGridColumns.v1"]==4?4:3;
    NSArray *saved=[[NSUserDefaults standardUserDefaults] arrayForKey:@"cctv.mediaHome.modules.v1"];
    NSUInteger moduleCount=saved?saved.count:3;
    return [NSString stringWithFormat:@"精选模块与海报布局 · %lu 模块 / %ld 列",(unsigned long)moduleCount,(long)cols];
}

static NSString *SettingsWatchHistorySummaryText(void) {
    NSUInteger liveCount=[[HostLibraryStore.shared recents] count];
    NSUInteger vodCount=[MediaPlaybackStateStore.watchHistory count];
    return [NSString stringWithFormat:@"本机最近观看的频道与影视（频道 %lu · 影视 %lu）",(unsigned long)liveCount,(unsigned long)vodCount];
}

static NSString *SettingsFavoritesSummaryText(void) {
    NSUInteger liveCount=[[HostLibraryStore.shared allFavorites] count];
    NSDictionary *vodFavs=HostLibraryStore.shared.mediaFavorites;
    NSUInteger vodCount=[vodFavs isKindOfClass:NSDictionary.class]?vodFavs.count:0;
    return [NSString stringWithFormat:@"全部频道收藏与影视收藏（频道 %lu · 影视 %lu）",(unsigned long)liveCount,(unsigned long)vodCount];
}

static NSString *SettingsSearchHistorySummaryText(void) {
    NSArray *history=[[NSUserDefaults standardUserDefaults] arrayForKey:@"media.globalSearchHistory.v1"];
    NSUInteger count=[history isKindOfClass:NSArray.class]?history.count:0;
    return [NSString stringWithFormat:@"本机保存的搜索关键词（当前 %lu 条）",(unsigned long)count];
}

static NSString *SettingsEPGRemindersSummaryText(void) {
    NSDictionary *reminders=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"cctv.epgReminders.v1"];
    NSUInteger count=[reminders isKindOfClass:NSDictionary.class]?reminders.count:0;
    return count?[NSString stringWithFormat:@"已设置 %lu 项节目单预约提醒",(unsigned long)count]:@"暂无节目单预约提醒";
}

// ---------- Spatial Glass 2.0 Semantic Palette & Squircle Icon Badge Engine ----------

static NSCache<NSString *, UIImage *> *SettingsIconBadgeCache(void) {
    static NSCache<NSString *, UIImage *> *cache=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        cache=[NSCache new];
        cache.countLimit=160;
    });
    return cache;
}

static void SettingsTriggerHapticSelection(void) {
    if(UIAccessibilityIsReduceMotionEnabled())return;
    UISelectionFeedbackGenerator *gen=[UISelectionFeedbackGenerator new];
    [gen prepare];
    [gen selectionChanged];
}

static void SettingsTriggerHapticImpact(UIImpactFeedbackStyle style) {
    if(UIAccessibilityIsReduceMotionEnabled())return;
    UIImpactFeedbackGenerator *gen=[[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen prepare];
    [gen impactOccurred];
}

static UIColor *SettingsSemanticTintForCategoryAndRole(NSString *category, NSString *role, BOOL isDark) {
    if([role isEqualToString:@"destructive"]){
        return isDark?[UIColor colorWithRed:0.98 green:0.36 blue:0.38 alpha:1.0]:[UIColor colorWithRed:0.84 green:0.18 blue:0.22 alpha:1.0];
    }
    if([role isEqualToString:@"cache"]){
        return isDark?[UIColor colorWithRed:0.98 green:0.60 blue:0.22 alpha:1.0]:[UIColor colorWithRed:0.84 green:0.44 blue:0.08 alpha:1.0];
    }
    if([category isEqualToString:@"appearance"]){
        return isDark?[UIColor colorWithRed:0.48 green:0.52 blue:0.98 alpha:1.0]:[UIColor colorWithRed:0.32 green:0.36 blue:0.86 alpha:1.0];
    }
    if([category isEqualToString:@"live"]){
        return isDark?[UIColor colorWithRed:0.22 green:0.72 blue:0.98 alpha:1.0]:[UIColor colorWithRed:0.04 green:0.50 blue:0.82 alpha:1.0];
    }
    if([category isEqualToString:@"vod"]){
        return isDark?[UIColor colorWithRed:0.96 green:0.64 blue:0.22 alpha:1.0]:[UIColor colorWithRed:0.82 green:0.46 blue:0.06 alpha:1.0];
    }
    if([category isEqualToString:@"engine"]){
        return isDark?[UIColor colorWithRed:0.18 green:0.82 blue:0.64 alpha:1.0]:[UIColor colorWithRed:0.06 green:0.62 blue:0.46 alpha:1.0];
    }
    if([category isEqualToString:@"diagnostics"]){
        return isDark?[UIColor colorWithRed:0.82 green:0.44 blue:0.96 alpha:1.0]:[UIColor colorWithRed:0.62 green:0.24 blue:0.82 alpha:1.0];
    }
    if([category isEqualToString:@"storage"]){
        return isDark?[UIColor colorWithRed:0.32 green:0.62 blue:0.98 alpha:1.0]:[UIColor colorWithRed:0.14 green:0.46 blue:0.86 alpha:1.0];
    }
    return HostAccent();
}

static UIImage *SettingsSquircleBadgeImage(NSString *symbolName, UIColor *tintColor, BOOL isDark, CGFloat boxSize) {
    NSString *safeSymbol=symbolName.length?symbolName:@"gearshape";
    CGFloat r=0,g=0,b=0,a=0;
    [tintColor getRed:&r green:&g blue:&b alpha:&a];
    NSString *cacheKey=[NSString stringWithFormat:@"%@:%.2f-%.2f-%.2f:%d:%.0f",safeSymbol,r,g,b,isDark?1:0,boxSize];
    UIImage *cached=[SettingsIconBadgeCache() objectForKey:cacheKey];
    if(cached)return cached;

    CGSize size=CGSizeMake(boxSize,boxSize);
    UIGraphicsImageRendererFormat *fmt=[UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque=NO;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *rendered=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx){
        CGContextRef cg=ctx.CGContext;
        CGRect rect=CGRectMake(0.5,0.5,boxSize-1.0,boxSize-1.0);
        CGFloat radius=round(boxSize*0.28);
        UIBezierPath *squircle=[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
        CGContextSaveGState(cg);
        [squircle addClip];

        UIColor *topFill=[tintColor colorWithAlphaComponent:isDark?0.24:0.16];
        UIColor *bottomFill=[tintColor colorWithAlphaComponent:isDark?0.09:0.06];
        NSArray *colors=@[(id)topFill.CGColor,(id)bottomFill.CGColor];
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
        CGFloat locations[2]={0.0,1.0};
        CGGradientRef grad=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,locations);
        if(grad){
            CGContextDrawLinearGradient(cg,grad,CGPointMake(0,0),CGPointMake(boxSize,boxSize),0);
            CGGradientRelease(grad);
        }
        CGColorSpaceRelease(space);

        // Top specular rim inside squircle
        UIBezierPath *topArc=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(rect,0.5,0.5) cornerRadius:MAX(1,radius-0.5)];
        [[UIColor colorWithWhite:1.0 alpha:isDark?0.12:0.35] setStroke];
        topArc.lineWidth=0.6;
        [topArc stroke];
        CGContextRestoreGState(cg);

        [[tintColor colorWithAlphaComponent:isDark?0.42:0.28] setStroke];
        squircle.lineWidth=0.8;
        [squircle stroke];

        CGFloat symPt=round(boxSize*0.45);
        UIImageSymbolConfiguration *symCfg=[UIImageSymbolConfiguration configurationWithPointSize:symPt weight:UIImageSymbolWeightSemibold];
        UIImage *sym=[[UIImage systemImageNamed:safeSymbol withConfiguration:symCfg] imageWithTintColor:tintColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        if(!sym){
            sym=[[UIImage systemImageNamed:@"gearshape" withConfiguration:symCfg] imageWithTintColor:tintColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        if(sym){
            CGSize imgSize=sym.size;
            CGRect drawRect=CGRectMake((boxSize-imgSize.width)/2.0,(boxSize-imgSize.height)/2.0,imgSize.width,imgSize.height);
            [sym drawInRect:drawRect];
        }
    }];
    rendered=[rendered imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if(rendered)[SettingsIconBadgeCache() setObject:rendered forKey:cacheKey];
    return rendered;
}

static UIImage *SettingsThemeSwatchPreviewImage(HostThemePalette *palette) {
    if(!palette)return nil;
    NSString *key=[NSString stringWithFormat:@"swatch:%@",palette.identifier?:@"default"];
    UIImage *cached=[SettingsIconBadgeCache() objectForKey:key];
    if(cached)return cached;
    UIGraphicsImageRendererFormat *fmt=[UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque=NO;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(22,14) format:fmt];
    UIImage *img=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx){
        CGRect bgCircle=CGRectMake(1,1,12,12);
        CGRect accentCircle=CGRectMake(9,1,12,12);
        UIBezierPath *p1=[UIBezierPath bezierPathWithOvalInRect:bgCircle];
        [palette.background setFill];
        [p1 fill];
        [[palette.accent colorWithAlphaComponent:0.55] setStroke];
        p1.lineWidth=1.0;
        [p1 stroke];

        UIBezierPath *p2=[UIBezierPath bezierPathWithOvalInRect:accentCircle];
        [palette.accent setFill];
        [p2 fill];
        [[UIColor colorWithWhite:1.0 alpha:0.65] setStroke];
        p2.lineWidth=0.9;
        [p2 stroke];
    }];
    img=[img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if(img)[SettingsIconBadgeCache() setObject:img forKey:key];
    return img;
}

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UIView *heroHeaderView;
@property(nonatomic,strong) UIView *settingsTopImmersiveScrim;
@property(nonatomic,strong) CAGradientLayer *settingsTopImmersiveGradient;
@property(nonatomic,strong) UIStackView *heroSummaryChipsStack;
@property(nonatomic,strong) UIStackView *heroQuickTilesStack;
@property(nonatomic,strong) UIButton *heroMoreButton;
@property(nonatomic,strong) UITextField *settingsSearchField;
@property(nonatomic,strong) UILabel *searchMatchCountBadge;
@property(nonatomic,strong) UIScrollView *categoryFilterScroll;
@property(nonatomic,strong) UIStackView *categoryFilterStack;
@property(nonatomic,copy) NSString *selectedCategoryKey;
@property(nonatomic,copy) NSString *searchKeyword;
@property(nonatomic,strong) NSMutableSet<NSString *> *collapsedCategories;
@property(nonatomic) CGFloat bottomOverlayInset;
@property(nonatomic,strong) NSArray<NSDictionary *> *allSections;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@property(nonatomic,copy,nullable) NSString *lastUpdateCheckText;
@property(nonatomic,assign) BOOL checkingUpdate;
@property(nonatomic,assign) BOOL clearedImagesState;
- (NSIndexPath *)indexPathForRowAction:(NSString *)action;
- (void)resetSingleRowToDefault:(NSDictionary *)row atIndexPath:(NSIndexPath *)ip;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip;
-  (void)applyCategoryFilter;
-  (void)setupHeroHeaderView;
-  (void)updateImmersiveTableInsets;
-  (void)refreshHeroSummaryChips;
-  (void)presentThemePicker:(NSIndexPath *)ip;
-  (void)presentPreferredQualityPicker:(NSIndexPath *)ip;
-  (void)presentDecodeModePicker:(NSIndexPath *)ip;
-  (void)showPrivacyStatement;
-  (void)confirmClearAllCaches;
-  (void)copyVersionDiagnosticsFromIndexPath:(NSIndexPath *)ip;
-  (void)confirmResetDefaultPreferences;
-  (void)confirmClearEPG;
-  (void)confirmClearMediaMetadata:(NSIndexPath *)indexPath;
-  (void)confirmClearWatchHistory;
-  (void)confirmClearFavorites;
-  (void)confirmClearProgramReminders;
-  (void)confirmClearSearchHistory;
-  (void)presentPlaybackRatePicker:(NSIndexPath *)ip;
-  (void)presentVideoGravityPicker:(NSIndexPath *)ip;
-  (void)checkForUpdateFromIndexPath:(NSIndexPath *)ip;
@end

@implementation SettingsViewController

- (NSArray<NSDictionary *> *)categoryFilterDefinitions {
    return @[
        @{@"id":@"all", @"title":@"全部", @"icon":@"square.grid.2x2.fill"},
        @{@"id":@"appearance", @"title":@"外观与导航", @"icon":@"paintbrush.fill"},
        @{@"id":@"live", @"title":@"直播与频道", @"icon":@"dot.radiowaves.left.and.right"},
        @{@"id":@"vod", @"title":@"影视与点播", @"icon":@"film.stack"},
        @{@"id":@"engine", @"title":@"引擎与网络", @"icon":@"bolt.horizontal.fill"},
        @{@"id":@"diagnostics", @"title":@"运行诊断", @"icon":@"waveform.path.ecg"},
        @{@"id":@"privacy", @"title":@"隐私与授权", @"icon":@"hand.raised.fill"},
        @{@"id":@"storage", @"title":@"数据与缓存", @"icon":@"externaldrive.fill.badge.checkmark"},
        @{@"id":@"about", @"title":@"服务与关于", @"icon":@"info.circle.fill"}
    ];
}

- (void)buildSettingsSchema {
    self.allSections=@[
      @{ @"category":@"appearance", @"icon":@"paintbrush.fill", @"subtitle":@"主题色板 · 全局字号 · 导航恢复", @"title":@"外观与界面导航", @"footer":@"主题实时应用于全局；下方色板提供 6 套主题（4 套深色沉浸、2 套浅色），点选即时生效，无需重启。字号与底部导航偏好即时刷新生效。", @"rows":@[
        @{ @"title":@"全局主题", @"detail":@"系统 / 浅色 / 深色 · 全端即时响应", @"key":HostThemeModePreferenceKey, @"appearance":@YES, @"icon":@"circle.lefthalf.filled", @"subgroup":@"视觉风格" },
        @{ @"title":@"主题色板", @"detail":@"晨光白", @"action":@"themePalette", @"icon":@"paintpalette", @"subgroup":@"视觉风格" },
        @{ @"title":@"字号", @"detail":@"应用内全局动态字号档位", @"key":@"cctv.appFontSize.v1", @"segmented":@YES, @"options":@[@"标准",@"大",@"特大"], @"values":@[@0,@1,@2], @"default":@0, @"icon":@"textformat.size", @"subgroup":@"界面排版" },
        @{ @"title":@"启动时恢复上次打开的页面", @"detail":@"关闭后每次启动默认进入央视直播页", @"key":@"cctv.restoreLastTab.v1", @"icon":@"arrow.uturn.left", @"default":@YES, @"subgroup":@"导航记忆" }
      ]},
      @{ @"category":@"live", @"icon":@"dot.radiowaves.left.and.right", @"subtitle":@"内置央视增强 · 频道网格 · 直播画中画与节目单", @"title":@"直播与频道管理", @"footer":@"集中管理内置央视频道展示、频道网格/列表视图、排序方式及直播画中画。播放时屏幕常亮对央视与订阅直播同时生效。", @"rows":@[
        @{ @"title":@"显示内置央视频道", @"detail":@"在直播与频道列表中展示内置央视/卫视频道", @"key":@"nativeChannelsEnabled", @"icon":@"tv.badge.wifi", @"default":@YES, @"subgroup":@"内置央视" },
        @{ @"title":@"内置央视频道台标", @"detail":@"控制央视页列表与播放器右上角高清台标展示（默认关闭）", @"key":@"nativeChannelLogoEnabled", @"icon":@"sparkles.tv", @"default":@NO, @"subgroup":@"内置央视" },
        @{ @"title":@"内置央视播放器右上角台标", @"detail":@"独立控制内置央视播放画面右上角台标展示（默认关闭）", @"key":@"nativePlayerCornerLogoEnabled", @"icon":@"tv.inset.filled", @"default":@NO, @"subgroup":@"内置央视" },
        @{ @"title":@"内置央视频道实时预览图", @"detail":@"在频道列表刷新时检测并展示最新真实画面缩略图（默认关闭）", @"key":@"nativeChannelPreviewEnabled", @"icon":@"photo.tv", @"default":@NO, @"subgroup":@"内置央视" },
        @{ @"title":@"内置央视频道速率与延迟", @"detail":@"在央视页与频道页展示实时网速与毫秒级响应延迟角标（默认关闭）", @"key":@"nativeChannelTelemetryEnabled", @"icon":@"speedometer", @"default":@NO, @"subgroup":@"内置央视" },
        @{ @"title":@"频道用网格显示", @"detail":@"切换频道列表为海报卡片网格或紧凑列表", @"key":@"channelGridMode", @"icon":@"square.grid.2x2", @"default":@YES, @"subgroup":@"频道布局" },
        @{ @"title":@"频道网格列数", @"detail":@"网格模式下的单行频道卡片数量", @"key":@"cctv.channelGridColumns.v1", @"segmented":@YES, @"options":@[@"3 列",@"4 列"], @"values":@[@3,@4], @"default":@4, @"icon":@"rectangle.grid.3x2", @"subgroup":@"频道布局" },
        @{ @"title":@"频道排序方式", @"detail":@"按默认顺序、频道名称或测速结果排序", @"key":@"cctv.channelSortMode.v1", @"segmented":@YES, @"options":@[@"默认",@"名称",@"延迟"], @"values":@[@0,@1,@2], @"default":@0, @"icon":@"arrow.up.arrow.down", @"subgroup":@"频道布局" },
        @{ @"title":@"播放时屏幕常亮", @"detail":@"直播与点播播放期间防止自动锁屏息屏", @"key":@"cctv.mediaKeepScreenAwake", @"icon":@"sun.max", @"default":@YES, @"subgroup":@"播放交互" },
        @{ @"title":@"允许后台音频播放", @"detail":@"切到后台或锁屏时保持直播声音输出", @"key":@"allowBackgroundAudio", @"icon":@"speaker.wave.2", @"default":@YES, @"subgroup":@"播放交互" },
        @{ @"title":@"订阅流自动画中画", @"detail":@"退回主屏幕时自动开启系统内联画中画", @"key":@"autoPiP", @"icon":@"pip", @"default":@NO, @"subgroup":@"播放交互" },
        @{ @"title":@"自动获取节目单", @"detail":@"打开频道时自动同步并刷新 EPG 节目预告", @"key":@"autoLoadEPG", @"icon":@"list.bullet.rectangle", @"default":@YES, @"subgroup":@"节目单与续播" },
        @{ @"title":@"记住上次观看频道", @"detail":@"记录最后一次播放的直播频道", @"key":@"rememberLastChannel", @"icon":@"bookmark", @"default":@YES, @"subgroup":@"节目单与续播" },
        @{ @"title":@"启动时自动续播上次频道", @"detail":@"进入应用时自动拉起上次记住的频道", @"key":@"resumeLastChannel", @"icon":@"arrow.counterclockwise", @"default":@NO, @"subgroup":@"节目单与续播" },
        @{ @"title":@"默认清晰度", @"detail":SettingsPreferredQualityText(), @"action":@"defaultQuality", @"icon":@"4k.tv", @"subgroup":@"画质策略" }
      ]},
      @{ @"category":@"vod", @"icon":@"film.stack", @"subtitle":@"首页海报密度 · 选集视图样式 · 连播与片头片尾", @"title":@"影视与点播体验", @"footer":@"调整影视精选首页模块、海报网格列数与点播默认策略。自动跳过仅对已标记片头片尾位置的剧集生效；播放参数在播放器内也可随时调整。", @"rows":@[
        @{ @"title":@"媒体显示", @"detail":SettingsMediaDisplaySummaryText(), @"action":@"mediaDisplay", @"icon":@"rectangle.grid.2x2", @"subgroup":@"首页与海报" },
        @{ @"title":@"影视海报网格列数", @"detail":@"分类浏览与聚合列表的海报卡片密度", @"key":@"cctv.mediaGridColumns.v1", @"segmented":@YES, @"options":@[@"3 列",@"4 列"], @"values":@[@3,@4], @"default":@3, @"icon":@"square.grid.3x2", @"subgroup":@"首页与海报" },
        @{ @"title":@"详情与选集列表样式", @"detail":@"切换影视详情页与选集页的分集排列视图样式", @"key":@"cctv.mediaEpisodeLayoutStyle.v1", @"segmented":@YES, @"options":@[@"四列",@"单列",@"双列",@"三列"], @"values":@[@0,@1,@2,@3], @"default":@0, @"icon":@"list.bullet.below.rectangle", @"subgroup":@"选集交互" },
        @{ @"title":@"显示分集备注与状态角标", @"detail":@"在单列/双列选集视图中展示分集副标题、清晰度与播放状态", @"key":@"cctv.mediaEpisodeShowBadge.v1", @"icon":@"tag", @"default":@YES, @"subgroup":@"选集交互" },
        @{ @"title":@"进入选集页自动展开全集", @"detail":@"打开选集页时默认展开完整分集列表，无需手动点按展开", @"key":@"cctv.mediaEpisodeAutoExpand.v1", @"icon":@"rectangle.expand.vertical", @"default":@NO, @"subgroup":@"选集交互" },
        @{ @"title":@"自动连播下一集", @"detail":@"本集播放结束后自动切换并播放下一集", @"key":@"cctv.mediaAutoPlayNext", @"icon":@"forward.end.fill", @"default":@YES, @"subgroup":@"点播策略" },
        @{ @"title":@"自动跳过片头片尾", @"detail":@"按本机已保存的片头片尾锚点自动跳过", @"key":@"cctv.mediaAutoSkipIntroOutro", @"icon":@"forward.end.circle", @"default":@NO, @"subgroup":@"点播策略" },
        @{ @"title":@"默认播放速度", @"detail":SettingsPlaybackRateText(), @"action":@"defaultPlaybackRate", @"icon":@"speedometer", @"subgroup":@"点播策略" },
        @{ @"title":@"默认画面比例", @"detail":SettingsVideoGravityText(), @"action":@"defaultVideoGravity", @"icon":@"aspectratio", @"subgroup":@"点播策略" },
        @{ @"title":@"保存搜索历史", @"detail":@"在影视全局搜索与分类浏览中保留历史搜索词", @"key":@"media.globalSearchHistoryEnabled.v1", @"icon":@"magnifyingglass", @"default":@NO, @"subgroup":@"搜索偏好" }
      ]},
      @{ @"category":@"engine", @"icon":@"bolt.horizontal.fill", @"subtitle":@"首帧秒开优化 · 邻台预热 · 全局网络超时", @"title":@"播放引擎与网络性能", @"footer":@"快速起播降低首帧前的缓冲门槛，出画面后恢复 SDK 原值；预解析提前缓存相邻频道信息。网络请求超时统一控制 Spider、TVBox、MacCMS 与全局搜索等待时间。", @"rows":@[
        @{ @"title":@"原生播放器快速起播", @"detail":@"降低首帧前缓冲水位，提升切台响应速度", @"key":@"fastNativeStartup", @"icon":@"bolt", @"default":@YES, @"subgroup":@"起播加速" },
        @{ @"title":@"预解析下一个 CCTV 频道", @"detail":@"空闲时预热相邻央视频道线路信息", @"key":@"preloadNativeChannel", @"icon":@"forward.end", @"default":@YES, @"subgroup":@"起播加速" },
        @{ @"title":@"复用原生播放器", @"detail":@"切台时复用已有播放器实例以减少重建开销", @"key":@"legacyNativePlayback", @"icon":@"backward.end", @"default":@YES, @"subgroup":@"起播加速" },
        @{ @"title":@"网络请求超时", @"detail":@"影视接口、目录抓取与搜索请求超时上限", @"key":@"cctv.networkTimeout.v1", @"segmented":@YES, @"options":@[@"10 秒",@"20 秒",@"40 秒"], @"values":@[@10,@20,@40], @"default":@20, @"icon":@"network", @"subgroup":@"网络策略" },
        @{ @"title":@"点播解码引擎偏好", @"detail":SettingsDecodeModeText(), @"action":@"defaultDecodeMode", @"icon":@"cpu", @"subgroup":@"解码策略" },
        @{ @"title":@"SDK 详细日志（诊断）", @"detail":@"输出底层播放器 SDK 调试日志供排障分析", @"key":@"nativeSDKVerboseLogs", @"icon":@"doc.text", @"default":@NO, @"subgroup":@"底层调试" }
      ]},
      @{ @"category":@"diagnostics", @"icon":@"waveform.path.ecg", @"subtitle":@"站点健康度 · 播放内核选路 · 会话崩溃追踪", @"title":@"运行诊断与日志中心", @"footer":@"开启后记录应用启动、影视加载与播放阶段、海报失败和系统内存告警。站点与播放适配监测支持实时追踪站点连通性、容器编码、播放器内核选路及网址/流媒体探测。", @"rows":@[
        @{ @"title":@"站点与播放适配监测记录", @"detail":@"自动记录站点接口、CENC/代理、播放器内核与适配建议", @"key":@"cctv.adaptationMonitor.enabled", @"icon":@"waveform.badge.magnifyingglass", @"default":@YES, @"subgroup":@"适配监测" },
        @{ @"title":@"站点与播放适配监测中心", @"detail":@"查看站点健康度、播放器适配矩阵与网址/流实时探测", @"action":@"adaptationMonitor", @"icon":@"antenna.radiowaves.left.and.right", @"subgroup":@"适配监测", @"badge":@"探测面板" },
        @{ @"title":@"运行诊断模式", @"detail":@"先开启再复现；若闪退，重开 App 后导出", @"key":@"runtimeDiagnosticsEnabled", @"icon":@"waveform.path.ecg", @"default":@NO, @"subgroup":@"会话追踪" },
        @{ @"title":@"运行诊断记录", @"detail":@"按 App 运行分开查看 · 可单次导出、删除或清空", @"action":@"runtimeDiagnostics", @"icon":@"list.bullet.rectangle", @"subgroup":@"会话追踪", @"badge":@"按次归档" },
        @{ @"title":@"日志中心", @"action":@"logs", @"detail":@"总日志与各插件独立日志", @"icon":@"doc.text.magnifyingglass", @"subgroup":@"插件日志", @"badge":@"实时日志" }
      ]},
      @{ @"category":@"privacy", @"icon":@"hand.raised.fill", @"subtitle":@"外部解析授权 · 本机隐私边界", @"title":@"隐私与外部服务授权", @"footer":@"默认关闭第三方公共解析。开启后，自动解析可能把商业视频网页地址发送给外部解析站点，并把片名和分集信息发送给公共影视目录。合集配置中由你选择的解析接口不受此开关影响；关闭后，网页仍可在应用内打开。此授权仅保存在本机，不随配置备份迁移。", @"rows":@[
        @{ @"title":@"允许第三方公共视频解析", @"detail":@"仅在自动解析网页播放地址时使用；可能向外部服务发送网页地址、片名和分集信息。默认关闭", @"key":@"cctv.allowPublicMediaResolvers", @"icon":@"arrow.up.forward.app", @"default":@NO, @"subgroup":@"影视来源授权" }
      ]},
      @{ @"category":@"storage", @"icon":@"externaldrive.fill.badge.checkmark", @"subtitle":@"配置与合集索引备份 · 缓存与记录管理", @"title":@"数据备份与存储管理", @"footer":@"目录、分类和搜索结果可保存；影片详情仅短时缓存在内存中，播放地址不持久化。清理缓存或恢复默认偏好时，收藏、观看历史、订阅和插件数据会保留。", @"rows":@[
        @{ @"title":@"导出本机配置", @"detail":@"包含订阅、收藏、历史、偏好及合集索引；脚本、服务配置和钥匙串凭据需另行迁移", @"action":@"export", @"icon":@"square.and.arrow.up", @"subgroup":@"配置迁移", @"badge":@"JSON 备份" },
        @{ @"title":@"导入配置文件", @"detail":@"从 JSON 备份恢复配置并立即应用主题与字号", @"action":@"import", @"icon":@"square.and.arrow.down", @"subgroup":@"配置迁移", @"badge":@"恢复备份" },
        @{ @"title":@"恢复默认偏好设置", @"detail":@"重置界面与播放偏好为默认值（保留订阅与收藏）", @"action":@"resetDefaultPreferences", @"icon":@"arrow.counterclockwise.circle", @"subgroup":@"偏好重置", @"role":@"destructive", @"badge":@"重置偏好" },
        @{ @"title":@"清理全部缓存", @"detail":@"节目单、台标与影视元数据缓存", @"icon":@"trash.fill", @"action":@"clearAllCaches", @"subgroup":@"缓存清理", @"role":@"cache" },
        @{ @"title":@"清理节目单缓存", @"detail":SettingsEPGCacheSizeText(), @"icon":@"trash", @"action":@"clearEPG", @"subgroup":@"缓存清理", @"role":@"cache" },
        @{ @"title":@"清理台标缓存", @"detail":@"清理内存与磁盘缩略图缓存", @"icon":@"photo", @"action":@"clearImages", @"subgroup":@"缓存清理", @"role":@"cache" },
        @{ @"title":@"清理影视元数据缓存", @"detail":MediaMetadataCacheSummaryText(), @"icon":@"film", @"action":@"clearMediaMetadata", @"subgroup":@"缓存清理", @"role":@"cache" },
        @{ @"title":@"清理 JAR 运行时缓存", @"detail":@"清理已下载并转换的 TVBox spider.jar 缓存", @"icon":@"shippingbox", @"action":@"clearJARRuntimeCache", @"subgroup":@"缓存清理", @"role":@"cache" },
        @{ @"title":@"清除观看历史", @"detail":SettingsWatchHistorySummaryText(), @"icon":@"clock.arrow.circlepath", @"action":@"clearWatchHistory", @"subgroup":@"记录清理", @"role":@"destructive" },
        @{ @"title":@"清除收藏", @"detail":SettingsFavoritesSummaryText(), @"icon":@"heart.slash", @"action":@"clearFavorites", @"subgroup":@"记录清理", @"role":@"destructive" },
        @{ @"title":@"清除节目单预约提醒", @"detail":SettingsEPGRemindersSummaryText(), @"icon":@"bell.slash", @"action":@"clearEPGReminders", @"subgroup":@"记录清理", @"role":@"destructive" },
        @{ @"title":@"清除搜索历史", @"detail":SettingsSearchHistorySummaryText(), @"icon":@"magnifyingglass.circle", @"action":@"clearSearchHistory", @"subgroup":@"记录清理", @"role":@"destructive" }
      ]},
      @{ @"category":@"about", @"icon":@"info.circle.fill", @"subtitle":@"五大核心模块直达 · 本地沙盒隐私承诺 · 版本检查", @"title":@"服务直达与关于", @"footer":@"偏好保存在本机；订阅、节目单及插件会访问所配置的网络来源。", @"rows":@[
        @{ @"title":@"央视直播", @"detail":@"官方 CNPlayerSDK · VDN 自动选线", @"action":@"openTabLive", @"icon":@"tv", @"subgroup":@"核心导航", @"badge":@"直达" },
        @{ @"title":@"M3U / HLS 订阅", @"detail":@"AVPlayer · iOS 系统解码", @"action":@"openTabChannels", @"icon":@"play.rectangle", @"subgroup":@"核心导航", @"badge":@"直达" },
        @{ @"title":@"影视点播库", @"detail":@"Spider / TVBox / MacCMS 聚合影院", @"action":@"openTabMedia", @"icon":@"film", @"subgroup":@"核心导航", @"badge":@"直达" },
        @{ @"title":@"资源与配置中心", @"detail":@"管理直播订阅、影视站点与插件包", @"action":@"openTabResources", @"icon":@"square.stack.3d.up", @"subgroup":@"核心导航", @"badge":@"直达" },
        @{ @"title":@"内置插件", @"detail":@"Python / JavaScriptCore · 本机运行", @"action":@"openServices", @"icon":@"curlybraces", @"subgroup":@"核心导航", @"badge":@"服务页" },
        @{ @"title":@"隐私说明", @"detail":@"数据如何保存与使用", @"action":@"privacy", @"icon":@"hand.raised", @"subgroup":@"关于与更新", @"badge":@"纯本地" },
        @{ @"title":@"CCTVHost", @"detail":[NSString stringWithFormat:@"%@ (%@) · %@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"开发版",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?",[[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"] isEqual:@"no-python"]?@"无 Python 诊断版":@"完整版"], @"action":@"copyVersionDiagnostics", @"icon":@"info.circle", @"subgroup":@"关于与更新", @"badge":@"复制摘要" },
        @{ @"title":@"检查更新", @"detail":@"点按检查最新发布", @"action":@"checkUpdate", @"icon":@"arrow.down.circle", @"subgroup":@"关于与更新" }
      ]}
    ];
    [self applyCategoryFilter];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSUInteger)totalRowCountForCategory:(NSString *)categoryID {
    NSUInteger count=0;
    for(NSDictionary *sec in self.allSections){
        if([categoryID isEqualToString:@"all"] || [sec[@"category"] isEqualToString:categoryID]){
            count+=[sec[@"rows"] count];
        }
    }
    return count;
}

- (NSUInteger)visibleRowCountAcrossSections {
    NSUInteger count=0;
    for(NSDictionary *sec in self.sections){
        count+=[sec[@"rows"] count];
    }
    return count;
}

- (UIView *)buildSettingsSearchEmptyView {
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,320,240)];
    container.backgroundColor=UIColor.clearColor;
    container.accessibilityIdentifier=@"settings.search.empty";
    UIStackView *stack=[UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    stack.axis=UILayoutConstraintAxisVertical;
    stack.alignment=UIStackViewAlignmentCenter;
    stack.spacing=10;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-12],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:28],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-28]
    ]];
    UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass.circle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium]]];
    icon.tintColor=HostMutedText();
    [stack addArrangedSubview:icon];
    UILabel *label=[UILabel new];
    label.numberOfLines=0;
    label.textAlignment=NSTextAlignmentCenter;
    label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.adjustsFontForContentSizeCategory=YES;
    label.textColor=HostSecondaryText();
    label.text=[NSString stringWithFormat:@"未找到与“%@”匹配的设置项\n可尝试搜索“画中画”、“台标”、“缓存”或清空筛选条件",self.searchKeyword?:@""];
    [stack addArrangedSubview:label];
    UIButton *resetBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:@"  清空搜索与分类筛选  " forState:UIControlStateNormal];
    HostStylePillButton(resetBtn,YES);
    resetBtn.accessibilityIdentifier=@"settings.search.clear";
    [resetBtn.heightAnchor constraintGreaterThanOrEqualToConstant:36].active=YES;
    [resetBtn addTarget:self action:@selector(clearSettingsSearchFilter) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:resetBtn];
    return container;
}

- (void)updateSearchMatchCountBadge {
    if(!self.searchMatchCountBadge||!self.settingsSearchField)return;
    if(!self.searchKeyword.length){
        self.searchMatchCountBadge.hidden=YES;
        self.settingsSearchField.rightViewMode=UITextFieldViewModeNever;
        return;
    }
    NSUInteger matched=[self visibleRowCountAcrossSections];
    self.searchMatchCountBadge.text=[NSString stringWithFormat:@"  %lu 项  ",(unsigned long)matched];
    self.searchMatchCountBadge.textColor=matched?HostOnAccent():HostSecondaryText();
    self.searchMatchCountBadge.backgroundColor=matched?HostAccent():HostNeutralSurface();
    [self.searchMatchCountBadge sizeToFit];
    CGRect f=self.searchMatchCountBadge.frame;
    self.searchMatchCountBadge.frame=CGRectMake(0,0,MAX(42,CGRectGetWidth(f)+4),20);
    self.searchMatchCountBadge.hidden=NO;
    self.settingsSearchField.rightViewMode=UITextFieldViewModeUnlessEditing;
}

- (void)settingsSearchChanged:(UITextField *)sender {
    NSString *trimmed=[sender.text?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([trimmed isEqualToString:(self.searchKeyword?:@"")])return;
    self.searchKeyword=trimmed;
    [self applyCategoryFilter];
    [self updateSearchMatchCountBadge];
    [self.table reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)refreshCategoryPillAppearance {
    NSArray<NSDictionary *> *categories=[self categoryFilterDefinitions];
    NSArray<UIView *> *pills=self.categoryFilterStack.arrangedSubviews;
    for(NSUInteger idx=0; idx<pills.count && idx<categories.count; idx++){
        if(![pills[idx] isKindOfClass:UIButton.class])continue;
        UIButton *pill=(UIButton *)pills[idx];
        NSDictionary *cat=categories[idx];
        NSString *catID=cat[@"id"];
        BOOL selected=[catID isEqualToString:(self.selectedCategoryKey?:@"all")];
        NSUInteger count=[self totalRowCountForCategory:catID];
        [pill setTitle:[NSString stringWithFormat:@" %@ · %lu",cat[@"title"],(unsigned long)count] forState:UIControlStateNormal];
        pill.titleLabel.font=HostRoundedFont(12.5,selected?UIFontWeightBold:UIFontWeightMedium,UIFontTextStyleCaption1);
        pill.tintColor=selected?HostOnAccent():HostSecondaryText();
        [pill setTitleColor:selected?HostOnAccent():HostText() forState:UIControlStateNormal];
        pill.backgroundColor=selected?HostAccent():HostCard();
        HostSetLayerBorderColor(pill,selected?HostAccent():HostBorder());
    }
}

- (void)clearSettingsSearchFilter {
    SettingsTriggerHapticSelection();
    self.searchKeyword=@"";
    self.settingsSearchField.text=@"";
    [self.settingsSearchField resignFirstResponder];
    self.selectedCategoryKey=@"all";
    [self applyCategoryFilter];
    [self updateSearchMatchCountBadge];
    [self refreshCategoryPillAppearance];
    [self.table reloadData];
}

- (void)applyCategoryFilter {
    NSArray<NSDictionary *> *baseSections=self.allSections;
    if(self.selectedCategoryKey.length && ![self.selectedCategoryKey isEqualToString:@"all"]){
        NSMutableArray<NSDictionary *> *filtered=[NSMutableArray array];
        for(NSDictionary *sec in self.allSections){
            if([sec[@"category"] isEqualToString:self.selectedCategoryKey]){
                [filtered addObject:sec];
            }
        }
        if(filtered.count)baseSections=filtered;
    }
    NSString *kw=[self.searchKeyword?:@"" lowercaseString];
    if(!kw.length){
        self.sections=baseSections;
        if(self.table)self.table.backgroundView=nil;
        return;
    }
    NSMutableArray<NSDictionary *> *kwSections=[NSMutableArray array];
    for(NSDictionary *sec in baseSections){
        NSString *secTitle=[sec[@"title"] isKindOfClass:NSString.class]?[sec[@"title"] lowercaseString]:@"";
        NSString *secFooter=[sec[@"footer"] isKindOfClass:NSString.class]?[sec[@"footer"] lowercaseString]:@"";
        NSString *secSub=[sec[@"subtitle"] isKindOfClass:NSString.class]?[sec[@"subtitle"] lowercaseString]:@"";
        BOOL secMatched=[secTitle containsString:kw]||[secFooter containsString:kw]||[secSub containsString:kw];
        NSMutableArray<NSDictionary *> *matchedRows=[NSMutableArray array];
        for(NSDictionary *row in sec[@"rows"]){
            NSString *rTitle=[row[@"title"] isKindOfClass:NSString.class]?[row[@"title"] lowercaseString]:@"";
            NSString *rDetail=[row[@"detail"] isKindOfClass:NSString.class]?[row[@"detail"] lowercaseString]:@"";
            NSString *rKey=[row[@"key"] isKindOfClass:NSString.class]?[row[@"key"] lowercaseString]:@"";
            NSString *rAction=[row[@"action"] isKindOfClass:NSString.class]?[row[@"action"] lowercaseString]:@"";
            NSString *rSubgroup=[row[@"subgroup"] isKindOfClass:NSString.class]?[row[@"subgroup"] lowercaseString]:@"";
            if(secMatched||[rTitle containsString:kw]||[rDetail containsString:kw]||[rKey containsString:kw]||[rAction containsString:kw]||[rSubgroup containsString:kw]){
                [matchedRows addObject:row];
            }
        }
        if(matchedRows.count){
            NSMutableDictionary *copySec=[sec mutableCopy];
            copySec[@"rows"]=matchedRows.copy;
            [kwSections addObject:copySec.copy];
        }
    }
    self.sections=kwSections.copy;
    if(self.table)self.table.backgroundView=kwSections.count?nil:[self buildSettingsSearchEmptyView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"设置";
    self.selectedCategoryKey=@"all";
    self.searchKeyword=@"";
    self.collapsedCategories=[NSMutableSet set];
    self.view.backgroundColor=HostBackground();
    self.navigationController.navigationBar.tintColor=HostAccent();
    [self buildSettingsSchema];

    self.table=[[UITableView alloc]initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints=NO;
    self.table.backgroundColor=UIColor.clearColor;
    self.table.dataSource=self;
    self.table.delegate=self;
    self.table.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.table.rowHeight=UITableViewAutomaticDimension;
    self.table.estimatedRowHeight=68;
    self.table.sectionHeaderHeight=UITableViewAutomaticDimension;
    self.table.estimatedSectionHeaderHeight=48;
    self.table.tintColor=HostAccent();
    self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.table.separatorStyle=UITableViewCellSeparatorStyleNone;
    HostInstallGlassBackdrop(self.table);
    [self.view addSubview:self.table];

    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    self.settingsTopImmersiveScrim=[UIView new];
    self.settingsTopImmersiveScrim.userInteractionEnabled=NO;
    self.settingsTopImmersiveScrim.accessibilityIdentifier=@"settings.top.immersive.scrim";
    self.settingsTopImmersiveGradient=[CAGradientLayer layer];
    self.settingsTopImmersiveGradient.locations=@[@0.0,@0.68,@1.0];
    [self.settingsTopImmersiveScrim.layer addSublayer:self.settingsTopImmersiveGradient];
    [self.view addSubview:self.settingsTopImmersiveScrim];

    [self setupHeroHeaderView];
    [self updateImmersiveTableInsets];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleExternalPreferenceNotification:) name:ProfileStoreMetadataDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleExternalPreferenceNotification:) name:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleExternalPreferenceNotification:) name:@"MediaDisplayConfigurationDidChangeNotification" object:nil];
}

- (void)handleExternalPreferenceNotification:(NSNotification *)note {
    (void)note;
    if(!self.isViewLoaded||!self.view.window)return;
    [self refreshHeroSummaryChips];
    [self.table reloadData];
}

- (void)refreshHeroSummaryChips {
    if(self.heroSummaryChipsStack){
        NSArray<UIView *> *chips=self.heroSummaryChipsStack.arrangedSubviews;
        NSArray<NSString *> *texts=@[
            [NSString stringWithFormat:@"  🎨 %@  ", [HostThemePalette currentPalette].displayName],
            [NSString stringWithFormat:@"  📺 画质·%@  ", SettingsPreferredQualityText()],
            @"  🛡️ 隐私说明  "
        ];
        for(NSUInteger i=0;i<chips.count&&i<texts.count;i++){
            if([chips[i] isKindOfClass:UIButton.class])[(UIButton *)chips[i] setTitle:texts[i] forState:UIControlStateNormal];
        }
    }
    if(self.heroQuickTilesStack){
        NSArray<UIView *> *tiles=self.heroQuickTilesStack.arrangedSubviews;
        NSArray<NSString *> *subtitles=@[
            [HostThemePalette currentPalette].displayName?:@"晨光白",
            SettingsPreferredQualityText(),
            MediaAdaptationMonitor.shared.monitoringEnabled?@"实时监测中":@"已暂停",
            SettingsCompactCacheSizeText()
        ];
        for(NSUInteger i=0;i<tiles.count&&i<subtitles.count;i++){
            UILabel *subLabel=(UILabel *)[tiles[i] viewWithTag:2002];
            if([subLabel isKindOfClass:UILabel.class])subLabel.text=subtitles[i];
        }
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if(!self.heroHeaderView)[self setupHeroHeaderView];
    else [self refreshHeroSummaryChips];
    [self.table reloadData];
    __weak typeof(self) weakSelf=self;
    SettingsRefreshDiskCacheStatsAsync(^{
        SettingsViewController *owner=weakSelf;
        if(!owner||!owner.isViewLoaded||!owner.view.window)return;
        [owner refreshHeroSummaryChips];
        [owner.table reloadData];
    });
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();
    self.navigationController.navigationBar.tintColor=HostAccent();
    self.table.tintColor=HostAccent();
    HostStyleNavigation(self.navigationController);
    [self setupHeroHeaderView];
    [self.table reloadData];
    UIWindow *window=self.view.window;
    if(window){
        HostApplyThemeToWindow(window);
        HostRefreshAppearanceLayers(window);
    }
}

- (UIView *)buildQuickControlTileWithTitle:(NSString *)title
                                  subtitle:(NSString *)subtitle
                                      icon:(NSString *)iconName
                                  category:(NSString *)category
                                      role:(nullable NSString *)role
                                identifier:(NSString *)identifier
                                       tag:(NSInteger)tag {
    BOOL isDark=HostIsDarkThemeSelected();
    UIColor *tint=SettingsSemanticTintForCategoryAndRole(category,role,isDark);
    UIButton *tile=[UIButton buttonWithType:UIButtonTypeCustom];
    tile.translatesAutoresizingMaskIntoConstraints=NO;
    tile.tag=tag;
    tile.accessibilityIdentifier=identifier;
    tile.accessibilityLabel=[NSString stringWithFormat:@"%@，当前%@",title,subtitle];
    tile.backgroundColor=[HostText() colorWithAlphaComponent:isDark?0.055:0.04];
    tile.layer.cornerRadius=12;
    tile.layer.cornerCurve=kCACornerCurveContinuous;
    tile.layer.borderWidth=0.6;
    HostSetLayerBorderColor(tile,HostBorder());
    tile.clipsToBounds=YES;
    HostInstallPressFeedback(tile);
    [tile addTarget:self action:@selector(handleHeroQuickTileTap:) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iconView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11.5 weight:UIImageSymbolWeightSemibold]]];
    iconView.translatesAutoresizingMaskIntoConstraints=NO;
    iconView.tintColor=tint;
    iconView.userInteractionEnabled=NO;
    [tile addSubview:iconView];

    UILabel *titleLbl=[UILabel new];
    titleLbl.translatesAutoresizingMaskIntoConstraints=NO;
    titleLbl.text=title;
    titleLbl.font=HostRoundedFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2);
    titleLbl.textColor=HostSecondaryText();
    titleLbl.adjustsFontSizeToFitWidth=YES;
    titleLbl.minimumScaleFactor=0.72;
    titleLbl.lineBreakMode=NSLineBreakByClipping;
    titleLbl.userInteractionEnabled=NO;
    [tile addSubview:titleLbl];

    UILabel *subLbl=[UILabel new];
    subLbl.translatesAutoresizingMaskIntoConstraints=NO;
    subLbl.tag=2002;
    subLbl.text=subtitle;
    subLbl.font=HostRoundedFont(11.5,UIFontWeightBold,UIFontTextStyleCaption1);
    subLbl.textColor=HostText();
    subLbl.adjustsFontSizeToFitWidth=YES;
    subLbl.minimumScaleFactor=0.78;
    subLbl.lineBreakMode=NSLineBreakByTruncatingTail;
    subLbl.userInteractionEnabled=NO;
    [tile addSubview:subLbl];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:6],
        [iconView.topAnchor constraintEqualToAnchor:tile.topAnchor constant:8],
        [iconView.widthAnchor constraintEqualToConstant:12],
        [iconView.heightAnchor constraintEqualToConstant:12],

        [titleLbl.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:3],
        [titleLbl.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],
        [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:tile.trailingAnchor constant:-4],

        [subLbl.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:6],
        [subLbl.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-4],
        [subLbl.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-7]
    ]];
    return tile;
}

- (void)setupHeroHeaderView {
    if(self.heroHeaderView){
        [self.heroHeaderView removeFromSuperview];
        self.heroHeaderView=nil;
    }
    CGFloat width=CGRectGetWidth(self.view.bounds)?:390;
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,274)];
    header.autoresizingMask=UIViewAutoresizingFlexibleWidth;

    UIView *card=[UIView new];
    card.translatesAutoresizingMaskIntoConstraints=NO;
    HostStyleGlassCard(card,20);
    [header addSubview:card];

    UIView *iconBox=[UIView new];
    iconBox.translatesAutoresizingMaskIntoConstraints=NO;
    iconBox.backgroundColor=[HostAccent() colorWithAlphaComponent:0.18];
    iconBox.layer.cornerRadius=14;
    iconBox.layer.cornerCurve=kCACornerCurveContinuous;
    iconBox.layer.borderWidth=0.6;
    HostSetLayerBorderColor(iconBox,[HostAccent() colorWithAlphaComponent:0.35]);
    iconBox.clipsToBounds=YES;
    [card addSubview:iconBox];

    UIImageView *iconView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"tv.inset.filled"]];
    iconView.translatesAutoresizingMaskIntoConstraints=NO;
    iconView.tintColor=HostAccent();
    iconView.contentMode=UIViewContentModeScaleAspectFit;
    [iconBox addSubview:iconView];

    UILabel *titleLabel=[UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints=NO;
    titleLabel.text=@"CCTVHost 2026";
    titleLabel.textColor=HostText();
    titleLabel.font=HostRoundedFont(20.5,UIFontWeightBold,UIFontTextStyleTitle3);
    titleLabel.numberOfLines=0;
    titleLabel.adjustsFontForContentSizeCategory=YES;
    [card addSubview:titleLabel];

    UILabel *subtitleLabel=[UILabel new];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints=NO;
    subtitleLabel.text=@"Spatial Glass 2.0 · 全域视听与系统设置中心";
    subtitleLabel.textColor=HostSecondaryText();
    subtitleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    subtitleLabel.adjustsFontSizeToFitWidth=YES;
    subtitleLabel.minimumScaleFactor=0.80;
    subtitleLabel.numberOfLines=0;
    subtitleLabel.adjustsFontForContentSizeCategory=YES;
    [card addSubview:subtitleLabel];

    UIButton *moreBtn=[UIButton buttonWithType:UIButtonTypeSystem];
    moreBtn.translatesAutoresizingMaskIntoConstraints=NO;
    moreBtn.accessibilityIdentifier=@"settings.hero.more";
    moreBtn.accessibilityLabel=@"设置页快捷操作菜单";
    [moreBtn setImage:[UIImage systemImageNamed:@"slider.horizontal.3" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    moreBtn.tintColor=HostAccent();
    moreBtn.backgroundColor=[HostAccent() colorWithAlphaComponent:0.14];
    moreBtn.layer.cornerRadius=17;
    moreBtn.layer.cornerCurve=kCACornerCurveContinuous;
    moreBtn.layer.borderWidth=0.6;
    HostSetLayerBorderColor(moreBtn,[HostAccent() colorWithAlphaComponent:0.32]);
    HostInstallPressFeedback(moreBtn);
    [moreBtn addTarget:self action:@selector(presentHeroQuickActionsSheet:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:moreBtn];
    self.heroMoreButton=moreBtn;

    UIStackView *chipsStack=[UIStackView new];
    chipsStack.translatesAutoresizingMaskIntoConstraints=NO;
    BOOL accessibleLayout=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    chipsStack.axis=accessibleLayout?UILayoutConstraintAxisVertical:UILayoutConstraintAxisHorizontal;
    chipsStack.spacing=8;
    chipsStack.distribution=UIStackViewDistributionFillProportionally;
    [card addSubview:chipsStack];
    self.heroSummaryChipsStack=chipsStack;

    NSString *qualityLabel=SettingsPreferredQualityText();
    NSArray<NSDictionary *> *chipData=@[
        @{@"text":[NSString stringWithFormat:@"  🎨 %@  ", [HostThemePalette currentPalette].displayName], @"id":@"settings.hero.chip.theme"},
        @{@"text":[NSString stringWithFormat:@"  📺 画质·%@  ", qualityLabel], @"id":@"settings.hero.chip.quality"},
        @{@"text":@"  🛡️ 隐私说明  ", @"id":@"settings.hero.chip.privacy"}
    ];
    for(NSUInteger idx=0; idx<chipData.count; idx++){
        NSDictionary *item=chipData[idx];
        UIButton *chip=[UIButton buttonWithType:UIButtonTypeSystem];
        chip.tag=(NSInteger)idx;
        chip.accessibilityIdentifier=item[@"id"];
        [chip setTitle:item[@"text"] forState:UIControlStateNormal];
        chip.titleLabel.font=HostRoundedFont(11,UIFontWeightSemibold,UIFontTextStyleCaption2);
        chip.titleLabel.adjustsFontForContentSizeCategory=YES;
        [chip setTitleColor:HostSecondaryText() forState:UIControlStateNormal];
        chip.backgroundColor=[HostText() colorWithAlphaComponent:0.06];
        chip.layer.cornerRadius=8;
        chip.layer.cornerCurve=kCACornerCurveContinuous;
        chip.layer.borderWidth=0.5;
        HostSetLayerBorderColor(chip,HostBorder());
        chip.clipsToBounds=YES;
        [chip.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
        [chip addTarget:self action:@selector(handleHeroSummaryChipTap:) forControlEvents:UIControlEventTouchUpInside];
        [chipsStack addArrangedSubview:chip];
    }

    UIStackView *quickTilesStack=[UIStackView new];
    quickTilesStack.translatesAutoresizingMaskIntoConstraints=NO;
    quickTilesStack.axis=accessibleLayout?UILayoutConstraintAxisVertical:UILayoutConstraintAxisHorizontal;
    quickTilesStack.spacing=6;
    quickTilesStack.distribution=UIStackViewDistributionFillEqually;
    quickTilesStack.accessibilityIdentifier=@"settings.hero.quickTiles";
    [card addSubview:quickTilesStack];
    self.heroQuickTilesStack=quickTilesStack;

    NSArray<NSDictionary *> *quickSpecs=@[
        @{@"title":@"外观色板", @"sub":[HostThemePalette currentPalette].displayName?:@"晨光白", @"icon":@"paintpalette.fill", @"cat":@"appearance", @"id":@"settings.quick.theme"},
        @{@"title":@"默认画质", @"sub":qualityLabel, @"icon":@"4k.tv", @"cat":@"live", @"id":@"settings.quick.quality"},
        @{@"title":@"适配监测", @"sub":MediaAdaptationMonitor.shared.monitoringEnabled?@"实时监测中":@"已暂停", @"icon":@"waveform.path.ecg", @"cat":@"diagnostics", @"id":@"settings.quick.monitor"},
        @{@"title":@"释放缓存", @"sub":SettingsCompactCacheSizeText(), @"icon":@"sparkles", @"cat":@"storage", @"role":@"cache", @"id":@"settings.quick.cache"}
    ];
    for(NSUInteger i=0;i<quickSpecs.count;i++){
        NSDictionary *spec=quickSpecs[i];
        UIView *tile=[self buildQuickControlTileWithTitle:spec[@"title"] subtitle:spec[@"sub"] icon:spec[@"icon"] category:spec[@"cat"] role:spec[@"role"] identifier:spec[@"id"] tag:(NSInteger)i];
        [quickTilesStack addArrangedSubview:tile];
    }

    UITextField *searchField=[[UITextField alloc] initWithFrame:CGRectZero];
    searchField.translatesAutoresizingMaskIntoConstraints=NO;
    searchField.delegate=self;
    searchField.accessibilityIdentifier=@"settings.search.field";
    searchField.accessibilityLabel=@"搜索设置项";
    searchField.accessibilityHint=@"输入关键词筛选设置项，如画中画、台标、跳过片头或缓存";
    searchField.placeholder=@"搜索设置项（如：画中画、台标、跳过片头、缓存）";
    searchField.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    searchField.adjustsFontForContentSizeCategory=YES;
    searchField.textColor=HostText();
    searchField.tintColor=HostAccent();
    searchField.backgroundColor=[HostText() colorWithAlphaComponent:0.06];
    searchField.layer.cornerRadius=10;
    searchField.layer.cornerCurve=kCACornerCurveContinuous;
    searchField.layer.borderWidth=0.6;
    HostSetLayerBorderColor(searchField,HostBorder());
    searchField.clearButtonMode=UITextFieldViewModeWhileEditing;
    searchField.returnKeyType=UIReturnKeySearch;
    searchField.autocorrectionType=UITextAutocorrectionTypeNo;
    searchField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    UIView *leftWrap=[[UIView alloc] initWithFrame:CGRectMake(0,0,28,32)];
    UIImageView *magIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium]]];
    magIcon.tintColor=HostSecondaryText();
    magIcon.frame=CGRectMake(8,9,14,14);
    [leftWrap addSubview:magIcon];
    searchField.leftView=leftWrap;
    searchField.leftViewMode=UITextFieldViewModeAlways;

    UILabel *matchBadge=[[UILabel alloc] initWithFrame:CGRectMake(0,0,50,20)];
    matchBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightBold,UIFontTextStyleCaption2);
    matchBadge.layer.cornerRadius=10;
    matchBadge.layer.cornerCurve=kCACornerCurveContinuous;
    matchBadge.clipsToBounds=YES;
    matchBadge.textAlignment=NSTextAlignmentCenter;
    matchBadge.hidden=YES;
    self.searchMatchCountBadge=matchBadge;
    searchField.rightView=matchBadge;

    if(self.searchKeyword.length)searchField.text=self.searchKeyword;
    [searchField addTarget:self action:@selector(settingsSearchChanged:) forControlEvents:UIControlEventEditingChanged];
    [card addSubview:searchField];
    self.settingsSearchField=searchField;
    [self updateSearchMatchCountBadge];

    UIScrollView *filterScroll=[UIScrollView new];
    filterScroll.translatesAutoresizingMaskIntoConstraints=NO;
    filterScroll.showsHorizontalScrollIndicator=NO;
    filterScroll.accessibilityIdentifier=@"settings.category.filter.scroll";
    [header addSubview:filterScroll];
    self.categoryFilterScroll=filterScroll;

    UIStackView *filterStack=[UIStackView new];
    filterStack.translatesAutoresizingMaskIntoConstraints=NO;
    filterStack.axis=UILayoutConstraintAxisHorizontal;
    filterStack.spacing=8;
    filterStack.alignment=UIStackViewAlignmentCenter;
    [filterScroll addSubview:filterStack];
    self.categoryFilterStack=filterStack;

    NSArray<NSDictionary *> *categories=[self categoryFilterDefinitions];
    for(NSUInteger idx=0; idx<categories.count; idx++){
        NSDictionary *cat=categories[idx];
        NSString *catID=cat[@"id"];
        BOOL selected=[catID isEqualToString:(self.selectedCategoryKey?:@"all")];
        NSUInteger count=[self totalRowCountForCategory:catID];
        UIButton *pill=[UIButton buttonWithType:UIButtonTypeSystem];
        pill.translatesAutoresizingMaskIntoConstraints=NO;
        pill.tag=(NSInteger)idx;
        pill.accessibilityIdentifier=[NSString stringWithFormat:@"settings.category.%@",catID];
        pill.accessibilityLabel=[NSString stringWithFormat:@"筛选%@",cat[@"title"]];
        UIImageSymbolConfiguration *symCfg=[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        UIImage *icon=[UIImage systemImageNamed:cat[@"icon"] withConfiguration:symCfg];
        [pill setImage:icon forState:UIControlStateNormal];
        [pill setTitle:[NSString stringWithFormat:@" %@ · %lu",cat[@"title"],(unsigned long)count] forState:UIControlStateNormal];
        pill.titleLabel.font=HostRoundedFont(12.5,selected?UIFontWeightBold:UIFontWeightMedium,UIFontTextStyleCaption1);
        pill.tintColor=selected?HostOnAccent():HostSecondaryText();
        [pill setTitleColor:selected?HostOnAccent():HostText() forState:UIControlStateNormal];
        pill.backgroundColor=selected?HostAccent():HostCard();
        pill.layer.cornerRadius=17;
        pill.layer.cornerCurve=kCACornerCurveContinuous;
        pill.layer.borderWidth=0.6;
        HostSetLayerBorderColor(pill,selected?HostAccent():HostBorder());
        pill.contentEdgeInsets=UIEdgeInsetsMake(7,12,7,12);
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:34].active=YES;
        HostInstallPressFeedback(pill);
        [pill addTarget:self action:@selector(selectCategoryPill:) forControlEvents:UIControlEventTouchUpInside];
        [filterStack addArrangedSubview:pill];
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],

        [iconBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [iconBox.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [iconBox.widthAnchor constraintEqualToConstant:44],
        [iconBox.heightAnchor constraintEqualToConstant:44],

        [iconView.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:24],
        [iconView.heightAnchor constraintEqualToConstant:24],

        [moreBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [moreBtn.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [moreBtn.widthAnchor constraintEqualToConstant:44],
        [moreBtn.heightAnchor constraintEqualToConstant:44],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:moreBtn.leadingAnchor constant:-8],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:moreBtn.leadingAnchor constant:-8],

        [chipsStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [chipsStack.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],
        [chipsStack.topAnchor constraintGreaterThanOrEqualToAnchor:iconBox.bottomAnchor constant:10],
        [chipsStack.topAnchor constraintGreaterThanOrEqualToAnchor:subtitleLabel.bottomAnchor constant:10],

        [quickTilesStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [quickTilesStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [quickTilesStack.topAnchor constraintEqualToAnchor:chipsStack.bottomAnchor constant:10],
        [quickTilesStack.heightAnchor constraintEqualToConstant:accessibleLayout?210:48],

        [searchField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [searchField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [searchField.topAnchor constraintEqualToAnchor:quickTilesStack.bottomAnchor constant:10],
        [searchField.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-10],
        [searchField.heightAnchor constraintGreaterThanOrEqualToConstant:44],

        [filterScroll.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:10],
        [filterScroll.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [filterScroll.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [filterScroll.heightAnchor constraintEqualToConstant:40],
        [filterScroll.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],

        [filterStack.leadingAnchor constraintEqualToAnchor:filterScroll.contentLayoutGuide.leadingAnchor constant:16],
        [filterStack.trailingAnchor constraintEqualToAnchor:filterScroll.contentLayoutGuide.trailingAnchor constant:-16],
        [filterStack.centerYAnchor constraintEqualToAnchor:filterScroll.frameLayoutGuide.centerYAnchor]
    ]];

    self.heroHeaderView=header;
    self.table.tableHeaderView=header;
}

- (void)handleHeroSummaryChipTap:(UIButton *)chip {
    if(!chip)return;
    SettingsTriggerHapticSelection();
    HostAnimateSelection(chip);
    if(chip.tag==0){
        NSIndexPath *ip=[self indexPathForRowAction:@"themePalette"]?:[NSIndexPath indexPathForRow:0 inSection:0];
        [self presentThemePicker:ip];
    }else if(chip.tag==1){
        NSIndexPath *ip=[self indexPathForRowAction:@"defaultQuality"]?:[NSIndexPath indexPathForRow:0 inSection:0];
        [self presentPreferredQualityPicker:ip];
    }else{
        [self showPrivacyStatement];
    }
}

- (void)handleHeroQuickTileTap:(UIButton *)sender {
    SettingsTriggerHapticSelection();
    HostAnimateSelection(sender);
    if(sender.tag==0){
        NSIndexPath *ip=[self indexPathForRowAction:@"themePalette"]?:[NSIndexPath indexPathForRow:0 inSection:0];
        [self presentThemePicker:ip];
    }else if(sender.tag==1){
        NSIndexPath *ip=[self indexPathForRowAction:@"defaultQuality"]?:[NSIndexPath indexPathForRow:0 inSection:0];
        [self presentPreferredQualityPicker:ip];
    }else if(sender.tag==2){
        MediaAdaptationMonitorViewController *monitor=[[MediaAdaptationMonitorViewController alloc] initWithContext:nil];
        if(self.navigationController)[self.navigationController pushViewController:monitor animated:YES];
        else{UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:monitor];[self presentViewController:nav animated:YES completion:nil];}
    }else if(sender.tag==3){
        [self confirmClearAllCaches];
    }
}

- (void)presentHeroQuickActionsSheet:(UIButton *)sender {
    if(self.presentedViewController)return;
    SettingsTriggerHapticSelection();
    BOOL hasCollapsed=self.collapsedCategories.count>0;
    NSString *cacheSize=SettingsCompactCacheSizeText();
    __weak typeof(self) weakSelf=self;
    HostGlassSheetSection *viewCacheSection=[HostGlassSheetSection sectionWithTitle:@"视图与缓存" actions:@[
        [HostGlassSheetAction actionWithTitle:(hasCollapsed?@"展开全部分组":@"收起非首屏分组") subtitle:@"快速调整设置页面的分组折叠状态" value:nil icon:(hasCollapsed?@"rectangle.expand.vertical":@"rectangle.compress.vertical") tint:HostAccent() destructive:NO selected:NO handler:^{
            SettingsViewController *owner=weakSelf;if(!owner)return;
            if(hasCollapsed){
                [owner.collapsedCategories removeAllObjects];
            }else{
                for(NSDictionary *sec in owner.allSections){
                    NSString *cat=sec[@"category"];
                    if(cat.length && ![cat isEqualToString:@"appearance"])[owner.collapsedCategories addObject:cat];
                }
            }
            [owner.table reloadData];
        }],
        [HostGlassSheetAction actionWithTitle:@"一键清理全部缓存" subtitle:@"释放海报、节目单与临时网络缓存" value:cacheSize icon:@"trash.circle.fill" tint:UIColor.systemOrangeColor destructive:NO selected:NO handler:^{
            [weakSelf confirmClearAllCaches];
        }]
    ]];
    HostGlassSheetSection *backupDiagSection=[HostGlassSheetSection sectionWithTitle:@"备份与诊断" actions:@[
        [HostGlassSheetAction actionWithTitle:@"导出本机配置备份" subtitle:@"包含订阅、收藏、历史、偏好及合集索引；脚本、服务配置和钥匙串凭据需另行迁移" value:nil icon:@"square.and.arrow.up" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{
            if(weakSelf.onExportData)weakSelf.onExportData();
        }],
        [HostGlassSheetAction actionWithTitle:@"复制版本与运行环境摘要" subtitle:@"便于反馈问题或留存排查快照" value:nil icon:@"doc.on.doc" tint:UIColor.systemTealColor destructive:NO selected:NO handler:^{
            [weakSelf copyVersionDiagnosticsFromIndexPath:nil];
        }]
    ]];
    HostGlassSheetSection *dangerSection=[HostGlassSheetSection sectionWithTitle:@"重置" actions:@[
        [HostGlassSheetAction actionWithTitle:@"恢复默认偏好设置" subtitle:@"重置外观与播放偏好，保留已导入资源" value:nil icon:@"arrow.counterclockwise" tint:UIColor.systemRedColor destructive:YES selected:NO handler:^{
            [weakSelf confirmResetDefaultPreferences];
        }]
    ]];
    [HostGlassActionSheetViewController presentOn:self title:@"设置中心全局操作" subtitle:@"一键管理分组折叠、释放本机缓存、导出配置备份或复制诊断快照。" badgeText:[NSString stringWithFormat:@"当前缓存 · %@",cacheSize] badgeColor:HostAccent() sections:@[viewCacheSection,backupDiagSection,dangerSection] sourceView:(sender?:self.view)];
}

- (void)selectCategoryPill:(UIButton *)sender {
    NSArray<NSDictionary *> *categories=[self categoryFilterDefinitions];
    if(sender.tag<0 || sender.tag>=(NSInteger)categories.count)return;
    NSString *nextKey=categories[sender.tag][@"id"];
    if([self.selectedCategoryKey isEqualToString:nextKey])return;
    SettingsTriggerHapticSelection();
    HostAnimateSelection(sender);
    self.selectedCategoryKey=nextKey;
    if(![nextKey isEqualToString:@"all"])[self.collapsedCategories removeObject:nextKey];
    [self applyCategoryFilter];
    [self refreshCategoryPillAppearance];
    if(self.categoryFilterScroll)[self.categoryFilterScroll scrollRectToVisible:CGRectInset(sender.frame,-16,0) animated:YES];
    [self.table reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if(self.heroHeaderView && CGRectGetWidth(self.table.bounds)>0){
        CGRect f=self.heroHeaderView.frame;
        f.size.width=CGRectGetWidth(self.table.bounds);
        CGFloat height=[self.heroHeaderView systemLayoutSizeFittingSize:CGSizeMake(f.size.width,UILayoutFittingCompressedSize.height) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
        if(height>0 && (fabs(CGRectGetWidth(self.heroHeaderView.frame)-f.size.width)>0.5 || fabs(CGRectGetHeight(self.heroHeaderView.frame)-height)>0.5)){
            f.size.height=ceil(height);
            self.heroHeaderView.frame=f;
            self.table.tableHeaderView=self.heroHeaderView;
        }
    }
    [self updateImmersiveTableInsets];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateImmersiveTableInsets];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView==self.table&&self.settingsTopImmersiveScrim){
        CGFloat top=MAX(0,self.view.safeAreaInsets.top);
        CGFloat progress=MIN(1.0,MAX(0.0,(scrollView.contentOffset.y+top)/96.0));
        HostUpdateImmersiveTopScrim(self.settingsTopImmersiveScrim,self.settingsTopImmersiveGradient,CGRectMake(0,0,CGRectGetWidth(self.view.bounds),top+18),progress,NO);
    }
}

- (void)updateImmersiveTableInsets {
    if(!self.isViewLoaded||!self.table)return;
    CGFloat top=MAX(0,self.view.safeAreaInsets.top),bottom=MAX(24,self.bottomOverlayInset+22);
    if(self.settingsTopImmersiveScrim){
        CGFloat progress=MIN(1.0,MAX(0.0,(self.table.contentOffset.y+top)/96.0));
        HostUpdateImmersiveTopScrim(self.settingsTopImmersiveScrim,self.settingsTopImmersiveGradient,CGRectMake(0,0,CGRectGetWidth(self.view.bounds),top+18),progress,NO);
        [self.view bringSubviewToFront:self.settingsTopImmersiveScrim];
    }
    UIEdgeInsets old=self.table.contentInset,next=UIEdgeInsetsMake(top,0,bottom,0);
    if(fabs(old.top-top)<0.5&&fabs(old.bottom-bottom)<0.5)return;
    BOOL wasAtTop=self.table.contentOffset.y<=-old.top+1;
    self.table.contentInset=next;
    self.table.scrollIndicatorInsets=next;
    if(wasAtTop)self.table.contentOffset=CGPointMake(self.table.contentOffset.x,-top);
}

- (void)setBottomOverlayInset:(CGFloat)inset {
    if(!isfinite(inset))inset=0;
    inset=MAX(8,inset);
    if(fabs(_bottomOverlayInset-inset)<0.01)return;
    _bottomOverlayInset=inset;
    [self updateImmersiveTableInsets];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(self.isViewLoaded&&previousTraitCollection&&![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self setupHeroHeaderView];
        [self.table reloadData];
    }
}

- (BOOL)isSectionCollapsedAtIndex:(NSInteger)section {
    if(section<0 || section>=(NSInteger)self.sections.count)return NO;
    if(self.searchKeyword.length>0)return NO;
    if(self.selectedCategoryKey.length && ![self.selectedCategoryKey isEqualToString:@"all"])return NO;
    NSString *cat=self.sections[section][@"category"];
    return cat.length && [self.collapsedCategories containsObject:cat];
}

- (void)toggleSectionHeaderButton:(UIButton *)sender {
    NSInteger section=sender.tag;
    if(section<0 || section>=(NSInteger)self.sections.count)return;
    NSString *cat=self.sections[section][@"category"];
    if(!cat.length)return;
    SettingsTriggerHapticImpact(UIImpactFeedbackStyleLight);
    BOOL collapsed=[self.collapsedCategories containsObject:cat];
    if(collapsed)[self.collapsedCategories removeObject:cat];
    else [self.collapsedCategories addObject:cat];
    [self.table reloadSections:[NSIndexSet indexSetWithIndex:(NSUInteger)section] withRowAnimation:UITableViewRowAnimationFade];
    NSString *title=self.sections[section][@"title"]?:@"分组";
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"%@已%@",title,collapsed?@"展开":@"收起"]);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if([self isSectionCollapsedAtIndex:section])return 0;
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"title"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if([self isSectionCollapsedAtIndex:section])return nil;
    return self.sections[section][@"footer"];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if(section<0 || section>=(NSInteger)self.sections.count)return 0.01;
    BOOL isAccessibility=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    return isAccessibility?58.0:48.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if(section<0 || section>=(NSInteger)self.sections.count)return nil;
    NSDictionary *sec=self.sections[section];
    NSString *cat=sec[@"category"]?:@"all";
    NSString *title=sec[@"title"]?:@"";
    NSString *subtitle=sec[@"subtitle"]?:@"";
    NSString *iconName=sec[@"icon"]?:@"gearshape.fill";
    NSUInteger rowCount=[sec[@"rows"] count];
    BOOL collapsed=[self isSectionCollapsedAtIndex:section];
    BOOL isDark=HostIsDarkThemeSelected();
    UIColor *domainTint=SettingsSemanticTintForCategoryAndRole(cat,nil,isDark);

    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,CGRectGetWidth(tableView.bounds)?:390,46)];
    container.backgroundColor=UIColor.clearColor;

    UIImageView *badgeView=[[UIImageView alloc] initWithImage:SettingsSquircleBadgeImage(iconName,domainTint,isDark,26)];
    badgeView.translatesAutoresizingMaskIntoConstraints=NO;
    [container addSubview:badgeView];

    UILabel *titleLbl=[UILabel new];
    titleLbl.translatesAutoresizingMaskIntoConstraints=NO;
    titleLbl.text=title;
    titleLbl.font=HostRoundedFont(14.0,UIFontWeightBold,UIFontTextStyleSubheadline);
    titleLbl.textColor=HostText();
    titleLbl.adjustsFontForContentSizeCategory=YES;
    [container addSubview:titleLbl];

    UILabel *subLbl=[UILabel new];
    subLbl.translatesAutoresizingMaskIntoConstraints=NO;
    subLbl.text=subtitle;
    subLbl.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    subLbl.textColor=HostMutedText();
    subLbl.lineBreakMode=NSLineBreakByTruncatingTail;
    [container addSubview:subLbl];

    UILabel *countBadge=[UILabel new];
    countBadge.translatesAutoresizingMaskIntoConstraints=NO;
    countBadge.text=[NSString stringWithFormat:@"  %lu 项  ",(unsigned long)rowCount];
    countBadge.font=HostMonospacedDigitFont(11.0,UIFontWeightSemibold,UIFontTextStyleCaption2);
    countBadge.textColor=domainTint;
    countBadge.backgroundColor=[domainTint colorWithAlphaComponent:isDark?0.16:0.10];
    countBadge.layer.cornerRadius=9;
    countBadge.layer.cornerCurve=kCACornerCurveContinuous;
    countBadge.clipsToBounds=YES;
    [container addSubview:countBadge];

    UIImageView *chevron=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:collapsed?@"chevron.right":@"chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightBold]]];
    chevron.translatesAutoresizingMaskIntoConstraints=NO;
    chevron.tintColor=HostSecondaryText();
    [container addSubview:chevron];

    UIButton *headerBtn=[UIButton buttonWithType:UIButtonTypeCustom];
    headerBtn.translatesAutoresizingMaskIntoConstraints=NO;
    headerBtn.tag=section;
    headerBtn.accessibilityIdentifier=[NSString stringWithFormat:@"settings.section.header.%@",cat];
    headerBtn.accessibilityLabel=[NSString stringWithFormat:@"%@，共 %lu 项，当前%@",title,(unsigned long)rowCount,collapsed?@"已收起":@"已展开"];
    headerBtn.accessibilityHint=@"点按展开或收起本分组";
    [headerBtn addTarget:self action:@selector(toggleSectionHeaderButton:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:headerBtn];

    [NSLayoutConstraint activateConstraints:@[
        [container.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [badgeView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:4],
        [badgeView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [badgeView.widthAnchor constraintEqualToConstant:26],
        [badgeView.heightAnchor constraintEqualToConstant:26],

        [chevron.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [chevron.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:12],
        [chevron.heightAnchor constraintEqualToConstant:12],

        [countBadge.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-6],
        [countBadge.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [countBadge.heightAnchor constraintEqualToConstant:18],

        [titleLbl.leadingAnchor constraintEqualToAnchor:badgeView.trailingAnchor constant:9],
        [titleLbl.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],
        [titleLbl.trailingAnchor constraintLessThanOrEqualToAnchor:countBadge.leadingAnchor constant:-8],

        [subLbl.leadingAnchor constraintEqualToAnchor:titleLbl.leadingAnchor],
        [subLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:1],
        [subLbl.trailingAnchor constraintLessThanOrEqualToAnchor:countBadge.leadingAnchor constant:-8],
        [subLbl.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-4],

        [headerBtn.topAnchor constraintEqualToAnchor:container.topAnchor],
        [headerBtn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [headerBtn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [headerBtn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]
    ]];
    return container;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    HostStyleSectionHeaderView(view);
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    HostStyleSectionFooterView(view);
}

- (NSAttributedString *)highlightedAttributedString:(NSString *)text
                                           baseFont:(UIFont *)baseFont
                                          baseColor:(UIColor *)baseColor
                                     subgroupPrefix:(nullable NSString *)subgroup
                                       subgroupTint:(nullable UIColor *)subgroupTint {
    NSString *safeText=text?:@"";
    NSString *fullString=subgroup.length?[NSString stringWithFormat:@"%@ · %@",subgroup,safeText]:safeText;
    NSMutableAttributedString *attr=[[NSMutableAttributedString alloc] initWithString:fullString attributes:@{
        NSFontAttributeName:baseFont?:[UIFont preferredFontForTextStyle:UIFontTextStyleBody],
        NSForegroundColorAttributeName:baseColor?:HostText()
    }];
    if(subgroup.length && subgroupTint){
        NSRange subRange=NSMakeRange(0,subgroup.length);
        UIFont *subFont=HostRoundedFont(11.5,UIFontWeightSemibold,UIFontTextStyleCaption1);
        [attr addAttributes:@{
            NSFontAttributeName:subFont,
            NSForegroundColorAttributeName:subgroupTint
        } range:subRange];
    }
    if(self.searchKeyword.length){
        NSRange searchRange=NSMakeRange(0,fullString.length);
        while(searchRange.location<fullString.length){
            NSRange found=[fullString rangeOfString:self.searchKeyword options:NSCaseInsensitiveSearch range:searchRange];
            if(found.location==NSNotFound)break;
            [attr addAttributes:@{
                NSForegroundColorAttributeName:HostAccent(),
                NSBackgroundColorAttributeName:[HostAccent() colorWithAlphaComponent:0.20]
            } range:found];
            searchRange.location=NSMaxRange(found);
            searchRange.length=fullString.length-searchRange.location;
        }
    }
    return attr;
}

- (NSString *)trailingBadgeTextForActionRow:(NSDictionary *)row {
    NSString *action=row[@"action"];
    if([action isEqualToString:@"themePalette"])return [HostThemePalette currentPalette].displayName;
    if([action isEqualToString:@"defaultQuality"])return SettingsPreferredQualityText();
    if([action isEqualToString:@"defaultDecodeMode"])return SettingsDecodeModeText();
    if([action isEqualToString:@"defaultPlaybackRate"])return SettingsPlaybackRateText();
    if([action isEqualToString:@"defaultVideoGravity"])return SettingsVideoGravityText();
    if([action isEqualToString:@"mediaDisplay"]){
        NSInteger cols=[[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.mediaGridColumns.v1"]==4?4:3;
        return [NSString stringWithFormat:@"%ld 列",(long)cols];
    }
    if([action isEqualToString:@"clearAllCaches"])return SettingsCompactCacheSizeText();
    if([action isEqualToString:@"clearEPG"]){
        unsigned long long b=SettingsEPGCacheBytes();
        return b?[NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleMemory]:@"无缓存";
    }
    if([action isEqualToString:@"clearMediaMetadata"]){
        NSDictionary *summary=MediaMetadataCache.shared.summary;
        return [NSString stringWithFormat:@"%lu 项",(unsigned long)[summary[@"entries"] unsignedIntegerValue]];
    }
    if([action isEqualToString:@"clearImages"])return self.clearedImagesState?@"已清理":@"清理";
    if([action isEqualToString:@"clearWatchHistory"]||[action isEqualToString:@"clearFavorites"]||[action isEqualToString:@"clearEPGReminders"]||[action isEqualToString:@"clearSearchHistory"])return @"清空";
    if([action isEqualToString:@"checkUpdate"])return self.checkingUpdate?@"检查中":@"检查";
    if([row[@"badge"] isKindOfClass:NSString.class])return row[@"badge"];
    return nil;
}

- (UIView *)buildActionAccessoryViewForRow:(NSDictionary *)row inCategory:(NSString *)category {
    NSString *action=row[@"action"];
    NSString *role=row[@"role"];
    BOOL isDestructive=[role isEqualToString:@"destructive"];
    BOOL isDark=HostIsDarkThemeSelected();
    UIColor *tint=SettingsSemanticTintForCategoryAndRole(category,role,isDark);
    NSString *badgeText=[self trailingBadgeTextForActionRow:row];

    UIView *wrap=[[UIView alloc] initWithFrame:CGRectMake(0,0,120,30)];
    wrap.accessibilityIdentifier=@"settings.row.accessory";
    wrap.userInteractionEnabled=NO;

    CGFloat rightEdge=0;
    UIImageView *chevron=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]]];
    chevron.tintColor=isDestructive?tint:HostMutedText();
    [chevron sizeToFit];

    UIView *pillView=nil;
    if([action isEqualToString:@"checkUpdate"] && self.checkingUpdate){
        UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.color=HostAccent();
        [spinner startAnimating];
        pillView=spinner;
    }else if(badgeText.length){
        UIView *pill=[[UIView alloc] initWithFrame:CGRectZero];
        pill.backgroundColor=isDestructive?[tint colorWithAlphaComponent:isDark?0.18:0.12]:[HostText() colorWithAlphaComponent:isDark?0.07:0.05];
        pill.layer.cornerRadius=11;
        pill.layer.cornerCurve=kCACornerCurveContinuous;
        pill.layer.borderWidth=0.5;
        HostSetLayerBorderColor(pill,isDestructive?[tint colorWithAlphaComponent:0.35]:HostBorder());

        CGFloat x=8;
        if([action isEqualToString:@"themePalette"]){
            UIImageView *swatch=[[UIImageView alloc] initWithImage:SettingsThemeSwatchPreviewImage([HostThemePalette currentPalette])];
            swatch.frame=CGRectMake(x,4,22,14);
            [pill addSubview:swatch];
            x+=26;
        }
        UILabel *lbl=[UILabel new];
        lbl.text=badgeText;
        lbl.font=HostMonospacedDigitFont(11.5,UIFontWeightSemibold,UIFontTextStyleCaption1);
        lbl.textColor=isDestructive?tint:HostSecondaryText();
        [lbl sizeToFit];
        CGFloat maxLblW=112;
        CGFloat lblW=MIN(maxLblW,CGRectGetWidth(lbl.frame));
        lbl.frame=CGRectMake(x,3,lblW,16);
        [pill addSubview:lbl];
        pill.frame=CGRectMake(0,4,x+lblW+8,22);
        pillView=pill;
    }

    CGFloat totalW=CGRectGetWidth(chevron.frame);
    if(pillView){
        totalW+=CGRectGetWidth(pillView.frame)+6;
    }
    wrap.frame=CGRectMake(0,0,totalW,30);
    rightEdge=totalW;
    chevron.frame=CGRectMake(rightEdge-CGRectGetWidth(chevron.frame),(30-CGRectGetHeight(chevron.frame))/2.0,CGRectGetWidth(chevron.frame),CGRectGetHeight(chevron.frame));
    [wrap addSubview:chevron];
    if(pillView){
        CGRect pf=pillView.frame;
        pf.origin.x=CGRectGetMinX(chevron.frame)-6-CGRectGetWidth(pf);
        pf.origin.y=(30-CGRectGetHeight(pf))/2.0;
        pillView.frame=pf;
        [wrap addSubview:pillView];
    }
    return wrap;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting.row"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting.row"];
    NSDictionary *sec=self.sections[ip.section];
    NSString *secCategory=sec[@"category"]?:@"all";
    NSDictionary *row=sec[@"rows"][ip.row];
    BOOL isDark=HostIsDarkThemeSelected();
    NSString *role=row[@"role"];
    BOOL isDestructive=[role isEqualToString:@"destructive"];
    UIColor *semanticTint=SettingsSemanticTintForCategoryAndRole(secCategory,role,isDark);

    NSString *titleText=row[@"title"]?:@"";
    UIFont *titleFont=HostRoundedFont(16.0,isDestructive?UIFontWeightSemibold:UIFontWeightMedium,UIFontTextStyleBody);
    UIColor *titleColor=isDestructive?semanticTint:HostText();
    cell.textLabel.attributedText=nil;
    cell.detailTextLabel.attributedText=nil;
    cell.textLabel.text=titleText;
    cell.textLabel.textColor=titleColor;
    cell.textLabel.font=titleFont;
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.textLabel.numberOfLines=0;
    if(self.searchKeyword.length){
        cell.textLabel.attributedText=[self highlightedAttributedString:titleText baseFont:titleFont baseColor:titleColor subgroupPrefix:nil subgroupTint:nil];
    }

    cell.detailTextLabel.text=row[@"detail"];

    if([row[@"action"] isEqualToString:@"mediaDisplay"])cell.detailTextLabel.text=SettingsMediaDisplaySummaryText();
    if([row[@"action"] isEqualToString:@"clearAllCaches"])cell.detailTextLabel.text=SettingsAllCachesSummaryText();
    if([row[@"action"] isEqualToString:@"clearMediaMetadata"])cell.detailTextLabel.text=MediaMetadataCacheSummaryText();
    if([row[@"action"] isEqualToString:@"clearEPG"])cell.detailTextLabel.text=SettingsEPGCacheSizeText();
    if([row[@"action"] isEqualToString:@"clearImages"]&&self.clearedImagesState)cell.detailTextLabel.text=@"已清理，下次加载时重新获取";
    if([row[@"action"] isEqualToString:@"clearWatchHistory"])cell.detailTextLabel.text=SettingsWatchHistorySummaryText();
    if([row[@"action"] isEqualToString:@"clearFavorites"])cell.detailTextLabel.text=SettingsFavoritesSummaryText();
    if([row[@"action"] isEqualToString:@"clearEPGReminders"])cell.detailTextLabel.text=SettingsEPGRemindersSummaryText();
    if([row[@"action"] isEqualToString:@"clearSearchHistory"])cell.detailTextLabel.text=SettingsSearchHistorySummaryText();
    if([row[@"action"] isEqualToString:@"defaultPlaybackRate"])cell.detailTextLabel.text=SettingsPlaybackRateText();
    if([row[@"action"] isEqualToString:@"defaultVideoGravity"])cell.detailTextLabel.text=SettingsVideoGravityText();
    if([row[@"action"] isEqualToString:@"defaultQuality"])cell.detailTextLabel.text=SettingsPreferredQualityText();
    if([row[@"action"] isEqualToString:@"defaultDecodeMode"])cell.detailTextLabel.text=SettingsDecodeModeText();
    if([row[@"action"] isEqualToString:@"themePalette"])cell.detailTextLabel.text=[HostThemePalette currentPalette].displayName;
    if([row[@"action"] isEqualToString:@"checkUpdate"])cell.detailTextLabel.text=self.lastUpdateCheckText?:@"点按检查最新发布";

    UIFont *detailFont=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.textColor=HostSecondaryText();
    cell.detailTextLabel.font=detailFont;
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.numberOfLines=0;
    NSString *subgroup=row[@"subgroup"];
    if(subgroup.length || self.searchKeyword.length){
        cell.detailTextLabel.attributedText=[self highlightedAttributedString:cell.detailTextLabel.text baseFont:detailFont baseColor:HostSecondaryText() subgroupPrefix:subgroup subgroupTint:semanticTint];
    }

    // 2026 Spatial Glass Squircle Icon Badge
    NSString *iconName=row[@"icon"]?:@"gearshape";
    cell.imageView.image=SettingsSquircleBadgeImage(iconName,semanticTint,isDark,34);
    cell.imageView.tintColor=semanticTint;

    cell.backgroundColor=HostCard(); cell.layer.cornerRadius=14; cell.layer.cornerCurve=kCACornerCurveContinuous; cell.clipsToBounds=YES; cell.layer.borderWidth=0.6; HostSetLayerBorderColor(cell,HostBorder());
    cell.accessoryView=nil;
    cell.accessoryType=UITableViewCellAccessoryNone;
    cell.selectionStyle=UITableViewCellSelectionStyleNone;

    NSString *key=row[@"key"];
    if([row[@"appearance"] boolValue]){
        UISegmentedControl *style=[[UISegmentedControl alloc] initWithItems:@[@"系统",@"浅色",@"深色"]];
        style.apportionsSegmentWidthsByContent=YES;
        UIFont *segFont=HostRoundedFont(12.5,UIFontWeightSemibold,UIFontTextStyleSubheadline);
        NSString *mode=HostThemeMode();
        style.selectedSegmentIndex=[mode isEqual:@"system"]?0:([mode isEqual:@"light"]?1:2);
        style.selectedSegmentTintColor=HostAccent();
        [style setTitleTextAttributes:@{NSFontAttributeName:segFont,NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];
        [style setTitleTextAttributes:@{NSFontAttributeName:segFont,NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];
        style.accessibilityIdentifier=HostThemeModePreferenceKey;
        style.accessibilityLabel=row[@"title"];
        [style addTarget:self action:@selector(appearanceChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=style;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else if([row[@"segmented"] boolValue]){
        NSArray *options=row[@"options"];
        UISegmentedControl *seg=[[UISegmentedControl alloc] initWithItems:options];
        seg.apportionsSegmentWidthsByContent=YES;
        UIFont *segFont=HostRoundedFont(12.5,UIFontWeightSemibold,UIFontTextStyleSubheadline);
        NSInteger saved=[[NSUserDefaults standardUserDefaults] objectForKey:key]?[[NSUserDefaults standardUserDefaults] integerForKey:key]:[row[@"default"] integerValue];
        NSInteger index=[row[@"values"] indexOfObject:@(saved)];
        seg.selectedSegmentIndex=index==NSNotFound?0:index;
        seg.selectedSegmentTintColor=HostAccent();
        [seg setTitleTextAttributes:@{NSFontAttributeName:segFont,NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];
        [seg setTitleTextAttributes:@{NSFontAttributeName:segFont,NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];
        seg.accessibilityIdentifier=key;
        seg.accessibilityLabel=row[@"title"];
        [seg addTarget:self action:@selector(segmentedChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=seg;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else if(key){
        UISwitch *sw=[UISwitch new];
        sw.onTintColor=HostAccent();
        if([key isEqualToString:@"nativeChannelLogoEnabled"])sw.on=[ProfileStore isChannelLogoEnabledForSource:@""];
        else if([key isEqualToString:@"nativePlayerCornerLogoEnabled"])sw.on=[ProfileStore isPlayerCornerLogoEnabledForSource:@""];
        else if([key isEqualToString:@"nativeChannelPreviewEnabled"])sw.on=[ProfileStore isChannelPreviewEnabledForSource:@""];
        else if([key isEqualToString:@"nativeChannelTelemetryEnabled"])sw.on=[ProfileStore isChannelTelemetryEnabledForSource:@""];
        else {
            id saved=[[NSUserDefaults standardUserDefaults] objectForKey:key];
            sw.on=saved? [saved boolValue]:[row[@"default"] boolValue];
        }
        sw.accessibilityIdentifier=key;
        sw.accessibilityLabel=row[@"title"];
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=sw;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else if(row[@"action"]){
        cell.accessoryView=[self buildActionAccessoryViewForRow:row inCategory:secCategory];
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    }
    else {
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(!cell || UIAccessibilityIsReduceMotionEnabled())return;
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        cell.transform=CGAffineTransformMakeScale(0.984,0.984);
        cell.backgroundColor=HostHighlightedSurface();
        HostSetLayerBorderColor(cell,HostAccent());
    } completion:nil];
}

- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(!cell)return;
    [UIView animateWithDuration:0.24 delay:0 usingSpringWithDamping:0.76 initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        cell.transform=CGAffineTransformIdentity;
        cell.backgroundColor=HostCard();
        HostSetLayerBorderColor(cell,HostBorder());
    } completion:nil];
}

- (nullable UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)point;
    if(indexPath.section<0 || indexPath.section>=(NSInteger)self.sections.count)return nil;
    NSArray *rows=self.sections[indexPath.section][@"rows"];
    if(indexPath.row<0 || indexPath.row>=(NSInteger)rows.count)return nil;
    NSDictionary *row=rows[indexPath.row];
    NSString *title=row[@"title"]?:@"设置项";
    NSString *key=row[@"key"];
    NSString *action=row[@"action"];
    __weak typeof(self) weakSelf=self;

    return [UIContextMenuConfiguration configurationWithIdentifier:indexPath previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        (void)suggestedActions;
        NSMutableArray<UIMenuElement *> *actions=[NSMutableArray array];
        if(action.length){
            [actions addObject:[UIAction actionWithTitle:@"打开或执行此项" image:[UIImage systemImageNamed:@"hand.tap"] identifier:nil handler:^(__kindof UIAction * _Nonnull act) {
                SettingsViewController *owner=weakSelf;
                if(!owner)return;
                [owner tableView:owner.table didSelectRowAtIndexPath:indexPath];
            }]];
        }
        BOOL isResettablePickerAction=[@[@"defaultQuality",@"defaultPlaybackRate",@"defaultVideoGravity",@"themePalette"] containsObject:action?:@""];
        if((key.length && row[@"default"]!=nil) || isResettablePickerAction){
            [actions addObject:[UIAction actionWithTitle:@"恢复此项默认值" image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(__kindof UIAction * _Nonnull act) {
                [weakSelf resetSingleRowToDefault:row atIndexPath:indexPath];
            }]];
        }
        [actions addObject:[UIAction actionWithTitle:@"复制设置项状态" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__kindof UIAction * _Nonnull act) {
            SettingsViewController *owner=weakSelf;
            if(!owner)return;
            UITableViewCell *cell=[owner.table cellForRowAtIndexPath:indexPath];
            NSString *detail=cell.detailTextLabel.text?:row[@"detail"]?:@"";
            UIPasteboard.generalPasteboard.string=[NSString stringWithFormat:@"%@：%@",title,detail];
            SettingsTriggerHapticSelection();
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"已复制设置项状态");
        }]];
        return [UIMenu menuWithTitle:title children:actions];
    }];
}

- (void)resetSingleRowToDefault:(NSDictionary *)row atIndexPath:(NSIndexPath *)ip {
    NSString *key=row[@"key"];
    NSString *action=row[@"action"];
    if(!key.length && !action.length)return;
    SettingsTriggerHapticImpact(UIImpactFeedbackStyleMedium);
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if(!key.length && action.length){
        if([action isEqualToString:@"defaultQuality"]){
            [defaults setObject:@"auto" forKey:@"cctv.mediaPreferredQuality.v1"];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaPreferredQuality.v1",YES);
        }else if([action isEqualToString:@"defaultPlaybackRate"]){
            [defaults setDouble:1.0 forKey:@"cctv.mediaPlaybackRate"];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaPlaybackRate",YES);
        }else if([action isEqualToString:@"defaultVideoGravity"]){
            [defaults setObject:AVLayerVideoGravityResizeAspect forKey:@"cctv.mediaVideoGravity"];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaVideoGravity",YES);
        }else if([action isEqualToString:@"themePalette"]){
            [HostThemePalette setCurrentPaletteIdentifier:HostThemePaletteDefaultIdentifier];
            [defaults setObject:@"light" forKey:HostThemeModePreferenceKey];
            [defaults setBool:NO forKey:HostDarkThemePreferenceKey];
            UIWindow *window=self.view.window;
            if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);HostRefreshAppearanceLayers(window);}
            [self reloadThemeAppearance];
            if(self.onPreferenceChanged)self.onPreferenceChanged(HostThemePaletteIdentifierPreferenceKey,YES);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"HostThemeDidChangeNotification" object:nil];
        }
        [self refreshHeroSummaryChips];
        if(ip)[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        else [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"%@已恢复默认值",row[@"title"]?:@"设置项"]);
        return;
    }
    if([row[@"segmented"] boolValue]){
        NSInteger defVal=[row[@"default"] integerValue];
        if([key isEqualToString:@"cctv.mediaEpisodeLayoutStyle.v1"]){
            CCTVEpisodeSetLayoutStyle((CCTVEpisodeLayoutStyle)defVal);
        }else{
            [defaults setInteger:defVal forKey:key];
        }
        if(self.onIntegerPreferenceChanged)self.onIntegerPreferenceChanged(key,defVal);
    }else{
        BOOL defBool=[row[@"default"] boolValue];
        if([key isEqualToString:@"cctv.adaptationMonitor.enabled"]){
            MediaAdaptationMonitor.shared.monitoringEnabled=defBool;
        }else if([key isEqualToString:@"cctv.mediaEpisodeShowBadge.v1"]){
            CCTVEpisodeSetShowRemarksBadgeEnabled(defBool);
        }else if([key isEqualToString:@"cctv.mediaEpisodeAutoExpand.v1"]){
            CCTVEpisodeSetAutoExpandEnabled(defBool);
            [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];
        }else{
            [defaults setBool:defBool forKey:key];
        }
        if([key isEqualToString:@"nativeChannelLogoEnabled"])[ProfileStore setChannelLogoEnabled:defBool forSource:@""];
        else if([key isEqualToString:@"nativePlayerCornerLogoEnabled"])[ProfileStore setPlayerCornerLogoEnabled:defBool forSource:@""];
        else if([key isEqualToString:@"nativeChannelPreviewEnabled"])[ProfileStore setChannelPreviewEnabled:defBool forSource:@""];
        else if([key isEqualToString:@"nativeChannelTelemetryEnabled"])[ProfileStore setChannelTelemetryEnabled:defBool forSource:@""];
        if(self.onPreferenceChanged)self.onPreferenceChanged(key,defBool);
    }
    [self refreshHeroSummaryChips];
    if(ip)[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    else [self.table reloadData];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"%@已恢复默认值",row[@"title"]?:@"设置项"]);
}

- (void)toggle:(UISwitch *)sender {
    if(!sender.accessibilityIdentifier.length)return;
    SettingsTriggerHapticSelection();
    NSString *key=sender.accessibilityIdentifier;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if([key isEqualToString:@"cctv.adaptationMonitor.enabled"]){
        MediaAdaptationMonitor.shared.monitoringEnabled=sender.on;
        [self refreshHeroSummaryChips];
    }else if([key isEqualToString:@"cctv.mediaEpisodeShowBadge.v1"]){
        CCTVEpisodeSetShowRemarksBadgeEnabled(sender.on);
    }else if([key isEqualToString:@"cctv.mediaEpisodeAutoExpand.v1"]){
        CCTVEpisodeSetAutoExpandEnabled(sender.on);
        [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:nil];
    }else{
        [defaults setBool:sender.on forKey:key];
    }
    if([key isEqualToString:@"nativeChannelLogoEnabled"])[ProfileStore setChannelLogoEnabled:sender.on forSource:@""];
    else if([key isEqualToString:@"nativePlayerCornerLogoEnabled"])[ProfileStore setPlayerCornerLogoEnabled:sender.on forSource:@""];
    else if([key isEqualToString:@"nativeChannelPreviewEnabled"])[ProfileStore setChannelPreviewEnabled:sender.on forSource:@""];
    else if([key isEqualToString:@"nativeChannelTelemetryEnabled"])[ProfileStore setChannelTelemetryEnabled:sender.on forSource:@""];
    if ([key isEqualToString:@"rememberLastChannel"] && !sender.on) {
        [defaults removeObjectForKey:@"lastChannel"];
        if ([defaults boolForKey:@"resumeLastChannel"]) {
            [defaults setBool:NO forKey:@"resumeLastChannel"];
            if (self.onPreferenceChanged) self.onPreferenceChanged(@"resumeLastChannel", NO);
            [self.table reloadData];
        }
    }
    if ([key isEqualToString:@"resumeLastChannel"] && sender.on) {
        if ([defaults objectForKey:@"rememberLastChannel"] && ![defaults boolForKey:@"rememberLastChannel"]) {
            [defaults setBool:YES forKey:@"rememberLastChannel"];
            if (self.onPreferenceChanged) self.onPreferenceChanged(@"rememberLastChannel", YES);
            [self.table reloadData];
        }
    }
    if ([key isEqualToString:@"cctv.restoreLastTab.v1"] && !sender.on) [defaults removeObjectForKey:@"cctv.lastBottomTab.v1"];
    if ([key isEqualToString:@"media.globalSearchHistoryEnabled.v1"]) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaGlobalSearchHistoryDidChange" object:nil userInfo:@{@"enabled":@(sender.on),@"cleared":@NO}];
    }
    if(self.onPreferenceChanged) self.onPreferenceChanged(key,sender.on);
}

- (void)segmentedChanged:(UISegmentedControl *)sender {
    NSArray *values=nil;
    for(NSDictionary *section in self.allSections)
        for(NSDictionary *row in section[@"rows"])
            if([row[@"key"] isEqualToString:sender.accessibilityIdentifier]&&[row[@"segmented"] boolValue])values=row[@"values"];
    if(!values||sender.selectedSegmentIndex<0||sender.selectedSegmentIndex>=(NSInteger)values.count)return;
    SettingsTriggerHapticSelection();
    NSInteger value=[values[sender.selectedSegmentIndex] integerValue];
    if([sender.accessibilityIdentifier isEqualToString:@"cctv.mediaEpisodeLayoutStyle.v1"]){
        CCTVEpisodeSetLayoutStyle((CCTVEpisodeLayoutStyle)value);
    }else{
        [NSUserDefaults.standardUserDefaults setInteger:value forKey:sender.accessibilityIdentifier];
    }
    if([sender.accessibilityIdentifier isEqualToString:@"cctv.appFontSize.v1"]){
        [self.table reloadData];
    }
    if([sender.accessibilityIdentifier isEqualToString:@"cctv.mediaGridColumns.v1"]){
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaDisplayConfigurationDidChangeNotification" object:nil];
        [self.table reloadData];
    }
    if(self.onIntegerPreferenceChanged) self.onIntegerPreferenceChanged(sender.accessibilityIdentifier,value);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *row=self.sections[ip.section][@"rows"][ip.row];
    if(row[@"action"])SettingsTriggerHapticSelection();
    if([row[@"action"] isEqualToString:@"clearEPG"]) [self confirmClearEPG];
    else if([row[@"action"] isEqualToString:@"clearImages"]){
        [HostImageLoader.shared clearCache];
        [HostImageLoader.shared clearDiskCache];
        SettingsInvalidateDiskCacheStats();
        self.clearedImagesState=YES;
        [self refreshHeroSummaryChips];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"台标缓存已清理");
        [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }
    else if([row[@"action"] isEqualToString:@"clearMediaMetadata"]) [self confirmClearMediaMetadata:ip];
    else if([row[@"action"] isEqualToString:@"clearJARRuntimeCache"]){
        NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
        NSString *jarDir=[support stringByAppendingPathComponent:@"JARRuntime"];
        if(jarDir.length)[NSFileManager.defaultManager removeItemAtPath:jarDir error:nil];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"JAR 运行时缓存已清理");
        [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    }
    else if([row[@"action"] isEqualToString:@"clearAllCaches"]) [self confirmClearAllCaches];
    else if([row[@"action"] isEqualToString:@"clearWatchHistory"]) [self confirmClearWatchHistory];
    else if([row[@"action"] isEqualToString:@"clearFavorites"]) [self confirmClearFavorites];
    else if([row[@"action"] isEqualToString:@"clearEPGReminders"]) [self confirmClearProgramReminders];
    else if([row[@"action"] isEqualToString:@"clearSearchHistory"]) [self confirmClearSearchHistory];
    else if([row[@"action"] isEqualToString:@"resetDefaultPreferences"]) [self confirmResetDefaultPreferences];
    else if([row[@"action"] isEqualToString:@"privacy"]) [self showPrivacyStatement];
    else if([row[@"action"] isEqualToString:@"defaultPlaybackRate"]) [self presentPlaybackRatePicker:ip];
    else if([row[@"action"] isEqualToString:@"defaultVideoGravity"]) [self presentVideoGravityPicker:ip];
    else if([row[@"action"] isEqualToString:@"defaultQuality"]) [self presentPreferredQualityPicker:ip];
    else if([row[@"action"] isEqualToString:@"defaultDecodeMode"]) [self presentDecodeModePicker:ip];
    else if([row[@"action"] isEqualToString:@"themePalette"]) [self presentThemePicker:ip];
    else if([row[@"action"] isEqualToString:@"checkUpdate"]) [self checkForUpdateFromIndexPath:ip];
    else if([row[@"action"] isEqualToString:@"openTabLive"]){if(self.onOpenTab)self.onOpenTab(0);}
    else if([row[@"action"] isEqualToString:@"openTabChannels"]){if(self.onOpenTab)self.onOpenTab(1);}
    else if([row[@"action"] isEqualToString:@"openTabMedia"]){if(self.onOpenTab)self.onOpenTab(2);}
    else if([row[@"action"] isEqualToString:@"openTabResources"]){if(self.onOpenTab)self.onOpenTab(3);}
    else if([row[@"action"] isEqualToString:@"openServices"]){if(self.onOpenServices)self.onOpenServices();}
    else if([row[@"action"] isEqualToString:@"export"]){if(self.onExportData)self.onExportData();}
    else if([row[@"action"] isEqualToString:@"adaptationMonitor"]){
        MediaAdaptationMonitorViewController *monitor=[[MediaAdaptationMonitorViewController alloc] initWithContext:nil];
        if(self.navigationController)[self.navigationController pushViewController:monitor animated:YES];
        else{UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:monitor];[self presentViewController:nav animated:YES completion:nil];}
    }
    else if([row[@"action"] isEqualToString:@"runtimeDiagnostics"]){if(self.onOpenDiagnostics)self.onOpenDiagnostics();}
    else if([row[@"action"] isEqualToString:@"mediaDisplay"]){if(self.onMediaDisplaySettings)self.onMediaDisplaySettings();}
    else if([row[@"action"] isEqualToString:@"import"]){if(self.onImportData)self.onImportData();}
    else if([row[@"action"] isEqualToString:@"logs"]){if(self.onOpenLog)self.onOpenLog();}
    else if([row[@"action"] isEqualToString:@"copyVersionDiagnostics"]) [self copyVersionDiagnosticsFromIndexPath:ip];
}

- (void)presentActionSheet:(UIAlertController *)sheet fromIndexPath:(NSIndexPath *)ip {
    if(self.presentedViewController)return;
    UITableViewCell *cell=[self.table cellForRowAtIndexPath:ip];
    sheet.popoverPresentationController.sourceView=cell?:self.view;
    sheet.popoverPresentationController.sourceRect=cell?cell.bounds:CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPlaybackRatePicker:(NSIndexPath *)ip {
    if(self.presentedViewController)return;
    double current=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.mediaPlaybackRate"]:1.0;
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetAction *> *baseChips=[NSMutableArray array];
    for(NSNumber *candidate in @[@0.5,@0.75,@1.0]){
        double rate=candidate.doubleValue;
        NSString *title=rate==1.0?@"正常速度":[NSString stringWithFormat:@"%.2gx",rate];
        BOOL selected=fabs(current-rate)<0.01;
        [baseChips addObject:[HostGlassSheetAction actionWithTitle:title subtitle:nil value:nil icon:nil tint:HostAccent() destructive:NO selected:selected handler:^{
            SettingsViewController *owner=weakSelf;if(!owner)return;
            [NSUserDefaults.standardUserDefaults setDouble:rate forKey:@"cctv.mediaPlaybackRate"];
            [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(owner.onPreferenceChanged)owner.onPreferenceChanged(@"cctv.mediaPlaybackRate",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认播放速度已设为%@",title]);
        }]];
    }
    NSMutableArray<HostGlassSheetAction *> *fastChips=[NSMutableArray array];
    for(NSNumber *candidate in @[@1.25,@1.5,@1.75,@2.0]){
        double rate=candidate.doubleValue;
        NSString *title=[NSString stringWithFormat:@"%.2gx",rate];
        BOOL selected=fabs(current-rate)<0.01;
        [fastChips addObject:[HostGlassSheetAction actionWithTitle:title subtitle:nil value:nil icon:nil tint:HostAccent() destructive:NO selected:selected handler:^{
            SettingsViewController *owner=weakSelf;if(!owner)return;
            [NSUserDefaults.standardUserDefaults setDouble:rate forKey:@"cctv.mediaPlaybackRate"];
            [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(owner.onPreferenceChanged)owner.onPreferenceChanged(@"cctv.mediaPlaybackRate",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认播放速度已设为%@",title]);
        }]];
    }
    UITableViewCell *cell=[self.table cellForRowAtIndexPath:ip];
    NSString *badge=fabs(current-1.0)<0.01?@"当前 · 正常速度":[NSString stringWithFormat:@"当前 · %.2gx",current];
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"默认播放速度"
                                         subtitle:@"下次播放影视时生效，也可在播放器右上角菜单里临时调整。"
                                        badgeText:badge
                                       badgeColor:HostAccent()
                                         sections:@[
                                             [HostGlassSheetSection chipSectionWithTitle:@"慢速与标准" actions:baseChips],
                                             [HostGlassSheetSection chipSectionWithTitle:@"倍速播放" actions:fastChips]
                                         ]
                                       sourceView:cell?:self.view];
}

- (void)presentVideoGravityPicker:(NSIndexPath *)ip {
    if(self.presentedViewController)return;
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    __weak typeof(self) weakSelf=self;
    NSArray<NSDictionary *> *options=@[
        @{@"title":@"画面适应",@"sub":@"保持原始宽高比，完整显示画面不裁切",@"icon":@"rectangle.arrowtriangle.2.inward",@"value":AVLayerVideoGravityResizeAspect},
        @{@"title":@"铺满裁切",@"sub":@"按比例放大填满屏幕，边缘超出部分自动裁切",@"icon":@"rectangle.arrowtriangle.2.outward",@"value":AVLayerVideoGravityResizeAspectFill},
        @{@"title":@"拉伸填满",@"sub":@"强制拉伸画面贴合屏幕边界",@"icon":@"arrow.up.left.and.arrow.down.right",@"value":AVLayerVideoGravityResize}
    ];
    NSMutableArray<HostGlassSheetAction *> *rows=[NSMutableArray array];
    NSString *activeTitle=@"画面适应";
    for(NSDictionary *option in options){
        NSString *title=option[@"title"],*value=option[@"value"];
        BOOL selected=[current isEqual:value];
        if(selected)activeTitle=title;
        [rows addObject:[HostGlassSheetAction actionWithTitle:title subtitle:option[@"sub"] value:nil icon:option[@"icon"] tint:HostAccent() destructive:NO selected:selected handler:^{
            SettingsViewController *owner=weakSelf;if(!owner)return;
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaVideoGravity"];
            [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(owner.onPreferenceChanged)owner.onPreferenceChanged(@"cctv.mediaVideoGravity",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认画面比例已设为%@",title]);
        }]];
    }
    UITableViewCell *cell=[self.table cellForRowAtIndexPath:ip];
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"默认画面比例"
                                         subtitle:@"下次播放影视时生效，也可在播放器右上角菜单里临时调整。"
                                        badgeText:[NSString stringWithFormat:@"当前 · %@",activeTitle]
                                       badgeColor:HostAccent()
                                         sections:@[[HostGlassSheetSection sectionWithTitle:@"画面填充模式" actions:rows]]
                                       sourceView:cell?:self.view];
}

- (void)presentPreferredQualityPicker:(NSIndexPath *)ip {
    if(self.presentedViewController)return;
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    NSArray<NSDictionary *> *options=@[
        @{@"title":@"自动",@"sub":@"根据网络带宽自适应选择最佳码率",@"val":@"自适应",@"icon":@"sparkles",@"value":@"auto"},
        @{@"title":@"流畅",@"sub":@"省流优先，峰值码率约 1.5 Mbps",@"val":@"1.5M",@"icon":@"tortoise",@"value":@"smooth"},
        @{@"title":@"高清",@"sub":@"清晰均衡，峰值码率约 4 Mbps",@"val":@"4M",@"icon":@"tv",@"value":@"hd"},
        @{@"title":@"超清",@"sub":@"高码率画质优先，峰值约 8 Mbps",@"val":@"8M",@"icon":@"4k.tv",@"value":@"uhd"}
    ];
    NSMutableArray<HostGlassSheetAction *> *rows=[NSMutableArray array];
    NSString *activeTitle=@"自动";
    for(NSDictionary *option in options){
        NSString *title=option[@"title"],*value=option[@"value"];
        BOOL selected=[current isEqual:value];
        if(selected)activeTitle=title;
        [rows addObject:[HostGlassSheetAction actionWithTitle:title subtitle:option[@"sub"] value:option[@"val"] icon:option[@"icon"] tint:HostAccent() destructive:NO selected:selected handler:^{
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaPreferredQuality.v1"];
            [self refreshHeroSummaryChips];
            [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaPreferredQuality.v1",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认清晰度已设为%@",title]);
        }]];
    }
    UITableViewCell *cell=[self.table cellForRowAtIndexPath:ip];
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"默认清晰度"
                                         subtitle:@"对多码率 HLS 流生效（影视页与直播 AVPlayer 回退）；央视直播走 SDK 时由 VDN 自动选线；单文件 MP4 无多码率可选。"
                                        badgeText:[NSString stringWithFormat:@"当前 · %@",activeTitle]
                                       badgeColor:HostAccent()
                                         sections:@[[HostGlassSheetSection sectionWithTitle:@"码率偏好" actions:rows]]
                                       sourceView:cell?:self.view];
}

- (void)presentDecodeModePicker:(NSIndexPath *)ip {
    if(self.presentedViewController)return;
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaDecodeMode.v1"]?:@"auto";
    NSArray<NSDictionary *> *options=@[
        @{@"title":@"自动（AVPlayer → MPV）",@"sub":@"按容器与编码智能选路：AVPlayer 优先，非原生容器与失败自动切换 MPV",@"val":@"推荐",@"icon":@"sparkles",@"value":@"auto"},
        @{@"title":@"优先 MPV 播放",@"sub":@"跳过 AVPlayer，直接由 MPV (FFmpeg + VideoToolbox) 全能内核起播",@"val":@"MPV",@"icon":@"cpu",@"value":@"mpv"},
        @{@"title":@"旧引擎兼容（Cicada 软解）",@"sub":@"仅在极少数异常流下手动启用，默认不参与点播路由",@"val":@"兼容",@"icon":@"wrench.and.screwdriver",@"value":@"cicada_soft"}
    ];
    NSMutableArray<HostGlassSheetAction *> *rows=[NSMutableArray array];
    NSString *activeTitle=@"自动（AVPlayer → MPV）";
    __weak typeof(self) weakSelf=self;
    for(NSDictionary *option in options){
        NSString *title=option[@"title"],*value=option[@"value"];
        BOOL selected=[current isEqualToString:value];
        if(selected)activeTitle=title;
        [rows addObject:[HostGlassSheetAction actionWithTitle:title subtitle:option[@"sub"] value:option[@"val"] icon:option[@"icon"] tint:HostAccent() destructive:NO selected:selected handler:^{
            SettingsViewController *owner=weakSelf;if(!owner)return;
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaDecodeMode.v1"];
            [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(owner.onPreferenceChanged)owner.onPreferenceChanged(@"cctv.mediaDecodeMode.v1",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"点播解码引擎偏好已设为%@",title]);
        }]];
    }
    UITableViewCell *cell=[self.table cellForRowAtIndexPath:ip];
    [HostGlassActionSheetViewController presentOn:self
                                            title:@"点播解码引擎偏好"
                                         subtitle:@"全局控制点播初始解码引擎；在播放器右上角菜单中也可随时临时切换。"
                                        badgeText:[NSString stringWithFormat:@"当前 · %@",activeTitle]
                                       badgeColor:HostAccent()
                                         sections:@[[HostGlassSheetSection sectionWithTitle:@"解码策略" actions:rows]]
                                       sourceView:cell?:self.view];
}

- (void)presentSettingsAlert:(UIAlertController *)alert {
    if (!alert || !self.isViewLoaded || !self.view.window || self.presentedViewController) return;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyVersionDiagnosticsFromIndexPath:(NSIndexPath *)ip {
    if (ip) [self.table deselectRowAtIndexPath:ip animated:YES];
    NSString *version = [([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"开发版") description];
    NSString *build = [([NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?") description];
    NSString *variant = [([NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"] ?: @"full") description];
    NSString *variantName = [variant isEqualToString:@"no-python"] ? @"无 Python 诊断版" : @"完整版";
    NSString *themeName = [HostThemePalette currentPalette].displayName ?: @"晨光白";
    NSInteger fontStep = [NSUserDefaults.standardUserDefaults integerForKey:@"cctv.appFontSize.v1"];
    NSString *fontTitle = fontStep == 2 ? @"特大" : (fontStep == 1 ? @"大" : @"标准");
    NSUInteger serviceCount = [ServiceStore services].count;
    NSString *cacheSummary = SettingsAllCachesSummaryText();
    NSString *snapshot = [NSString stringWithFormat:@"CCTVHost %@ (%@) · %@\n外观主题：%@ · 字号：%@\n已装脚本服务：%lu 个\n缓存状态：%@",
                          version, build, variantName, themeName, fontTitle, (unsigned long)serviceCount, cacheSummary];
    UIPasteboard.generalPasteboard.string = snapshot;
    [RuntimeDiagnostics.shared recordEvent:@"settings_version_diagnostics_copied"
                                  category:@"diagnostics"
                                    fields:@{@"version": version, @"build": build, @"variant": variant, @"service_count": @(serviceCount)}];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"已复制版本与运行环境摘要");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已复制运行环境摘要"
                                                                   message:snapshot
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentSettingsAlert:alert];
}

- (void)checkForUpdateFromIndexPath:(NSIndexPath *)ip {
    if(self.checkingUpdate)return;self.checkingUpdate=YES;
    self.lastUpdateCheckText=@"正在检查…";[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    NSURL *url=[NSURL URLWithString:@"https://api.github.com/repos/joeshu/yqk-forward-widget/releases/latest"];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [request setValue:@"CCTVHost" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf=self;
    NSURLSession *updateSession=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[updateSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        [updateSession finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(),^{
            SettingsViewController *owner=weakSelf;
            if(!owner)return;
            owner.checkingUpdate=NO;
            NSDictionary *json=(data.length&&data.length<=1024*1024)?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
            NSString *name=[json isKindOfClass:NSDictionary.class]&&[json[@"name"] isKindOfClass:NSString.class]?json[@"name"]:@"";
            NSString *htmlURL=[json isKindOfClass:NSDictionary.class]&&[json[@"html_url"] isKindOfClass:NSString.class]?json[@"html_url"]:@"";
            NSString *published=[json isKindOfClass:NSDictionary.class]&&[json[@"published_at"] isKindOfClass:NSString.class]?json[@"published_at"]:@"";
            NSString *latestVersion=nil,*latestBuild=nil;
            static NSRegularExpression *versionPattern=nil;
            static NSRegularExpression *buildPattern=nil;
            static dispatch_once_t updateRegexOnce;
            dispatch_once(&updateRegexOnce,^{
                versionPattern=[NSRegularExpression regularExpressionWithPattern:@"\\d+(\\.\\d+){1,2}" options:0 error:NULL];
                buildPattern=[NSRegularExpression regularExpressionWithPattern:@"\\((\\d+)\\)" options:0 error:NULL];
            });
            NSTextCheckingResult *versionMatch=[versionPattern firstMatchInString:name options:0 range:NSMakeRange(0,name.length)];
            if(versionMatch)latestVersion=[name substringWithRange:versionMatch.range];
            NSTextCheckingResult *buildMatch=[buildPattern firstMatchInString:name options:0 range:NSMakeRange(0,name.length)];
            if(buildMatch&&buildMatch.numberOfRanges>1)latestBuild=[name substringWithRange:[buildMatch rangeAtIndex:1]];
            NSString *installed=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"开发版";
            NSString *installedBuild=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?";
            if(error||!latestVersion){
                owner.lastUpdateCheckText=@"检查失败 · 点按重试";
                [owner.table reloadData];
                if (!owner.view.window || owner.presentedViewController) return;
                UIAlertController *failed=[UIAlertController alertControllerWithTitle:@"检查更新失败" message:@"无法获取最新发布信息，请检查网络后重试。" preferredStyle:UIAlertControllerStyleAlert];
                [failed addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [owner presentViewController:failed animated:YES completion:nil];return;
            }
            NSComparisonResult compared=[latestVersion compare:installed options:NSNumericSearch];
            NSString *buildInfo=latestBuild?[NSString stringWithFormat:@"（构建 %@）",latestBuild]:@"";
            NSString *dateInfo=published.length>10?[NSString stringWithFormat:@"，发布于 %@",[published substringToIndex:10]]:@"";
            if(compared==NSOrderedDescending){
                owner.lastUpdateCheckText=[NSString stringWithFormat:@"发现新版本 %@%@",latestVersion,buildInfo];
                [owner.table reloadData];
                if (!owner.view.window || owner.presentedViewController) return;
                UIAlertController *found=[UIAlertController alertControllerWithTitle:@"发现新版本" message:[NSString stringWithFormat:@"最新版本 %@%@%@，当前版本 %@ (%@)。请前往 GitHub 发布页下载安装包。",latestVersion,buildInfo,dateInfo,installed,installedBuild] preferredStyle:UIAlertControllerStyleAlert];
                [found addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                if(htmlURL.length)[found addAction:[UIAlertAction actionWithTitle:@"去下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSURL *u=[NSURL URLWithString:htmlURL];if(u&&[u.scheme.lowercaseString isEqualToString:@"https"])[UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];}]];
                [owner presentViewController:found animated:YES completion:nil];return;
            }
            if(compared==NSOrderedSame&&latestBuild&&latestBuild.integerValue>installedBuild.integerValue){
                owner.lastUpdateCheckText=[NSString stringWithFormat:@"发现新构建 %@%@",latestVersion,buildInfo];
                [owner.table reloadData];
                if (!owner.view.window || owner.presentedViewController) return;
                UIAlertController *found=[UIAlertController alertControllerWithTitle:@"发现新构建" message:[NSString stringWithFormat:@"同一版本 %@ 有新构建 %@%@，当前构建 %@。请前往 GitHub 发布页下载安装包。",latestVersion,buildInfo,dateInfo,installedBuild] preferredStyle:UIAlertControllerStyleAlert];
                [found addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                if(htmlURL.length)[found addAction:[UIAlertAction actionWithTitle:@"去下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSURL *u=[NSURL URLWithString:htmlURL];if(u&&[u.scheme.lowercaseString isEqualToString:@"https"])[UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];}]];
                [owner presentViewController:found animated:YES completion:nil];return;
            }
            owner.lastUpdateCheckText=[NSString stringWithFormat:@"已是最新版本 %@%@",latestVersion,buildInfo];
            [owner.table reloadData];
            if (!owner.view.window || owner.presentedViewController) return;
            UIAlertController *uptodate=[UIAlertController alertControllerWithTitle:@"已是最新版本" message:[NSString stringWithFormat:@"当前版本 %@ (%@)，最新发布 %@%@%@。同一版本号内的新构建请以发布页为准。",installed,installedBuild,latestVersion,buildInfo,dateInfo] preferredStyle:UIAlertControllerStyleAlert];
            [uptodate addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [owner presentViewController:uptodate animated:YES completion:nil];
        });
    }] resume];
}

- (void)presentThemePicker:(NSIndexPath *)ip {
    HostThemePalette *current=[HostThemePalette currentPalette];
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetAction *> *lightActions=[NSMutableArray array];
    NSMutableArray<HostGlassSheetAction *> *darkActions=[NSMutableArray array];
    for(HostThemePalette *theme in HostThemePalette.allThemes){
        BOOL active=[theme.identifier isEqualToString:current.identifier];
        NSString *icon=theme.dark?@"moon.stars.fill":([theme.identifier isEqualToString:@"snow"]?@"sparkles":@"sun.max.fill");
        HostGlassSheetAction *act=[HostGlassSheetAction actionWithTitle:theme.displayName subtitle:theme.tagline value:(active?@"当前使用":nil) icon:icon tint:theme.accent destructive:NO selected:active handler:^{
            SettingsViewController *owner=weakSelf;if(!owner)return;
            [HostThemePalette setCurrentPaletteIdentifier:theme.identifier];
            NSString *mode=theme.dark?@"dark":@"light";
            [NSUserDefaults.standardUserDefaults setObject:mode forKey:HostThemeModePreferenceKey];
            [NSUserDefaults.standardUserDefaults setBool:theme.dark forKey:HostDarkThemePreferenceKey];
            UIWindow *window=owner.view.window;
            if(window){HostApplyThemeToWindow(window);HostStyleNavigation(owner.navigationController);dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);});}
            [owner reloadThemeAppearance];
            [owner.table reloadData];
            if(owner.onPreferenceChanged)owner.onPreferenceChanged(HostThemePaletteIdentifierPreferenceKey,theme.dark);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"HostThemeDidChangeNotification" object:nil];
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"主题已切换为%@",theme.displayName]);
        }];
        if(theme.dark)[darkActions addObject:act];
        else [lightActions addObject:act];
    }
    UITableViewCell *anchorCell=ip?[self.table cellForRowAtIndexPath:ip]:nil;
    [HostGlassActionSheetViewController presentOn:self title:@"主题色板" subtitle:@"浅色通透与深色沉浸共 6 套主题，切换立即全端生效。" badgeText:[NSString stringWithFormat:@"当前 · %@",current.displayName] badgeColor:current.accent sections:@[
        [HostGlassSheetSection sectionWithTitle:@"浅色主题（默认）" actions:lightActions],
        [HostGlassSheetSection sectionWithTitle:@"深色沉浸" actions:darkActions]
    ] sourceView:(anchorCell?:self.view)];
}

- (void)confirmResetDefaultPreferences {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"恢复默认偏好设置？" message:@"将把主题、字号、频道布局、播放速度和超时等设置恢复为出厂默认值。收藏、观看历史、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [ProfileStore setChannelLogoEnabled:NO forSource:@""];
        [ProfileStore setPlayerCornerLogoEnabled:NO forSource:@""];
        [ProfileStore setChannelPreviewEnabled:NO forSource:@""];
        [ProfileStore setChannelTelemetryEnabled:NO forSource:@""];
        NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
        NSArray<NSString *> *keysToReset=@[
            HostThemeModePreferenceKey, HostDarkThemePreferenceKey, HostThemePaletteIdentifierPreferenceKey,
            @"cctv.appFontSize.v1", @"cctv.restoreLastTab.v1", @"cctv.lastBottomTab.v1",
            @"nativeChannelsEnabled", @"nativeChannelLogoEnabled", @"nativePlayerCornerLogoEnabled", @"nativeChannelPreviewEnabled", @"nativeChannelTelemetryEnabled", @"enabledChannelLogoSources", @"enabledPlayerCornerLogoSources", @"enabledChannelPreviewSources", @"enabledChannelTelemetrySources", @"disabledChannelLogoSources", @"disabledPlayerCornerLogoSources", @"disabledChannelPreviewSources", @"disabledChannelTelemetrySources", @"channelGridMode", @"cctv.channelGridColumns.v1", @"cctv.channelSortMode.v1",
            @"cctv.mediaEpisodeLayoutStyle.v1", @"cctv.mediaEpisodeShowBadge.v1", @"cctv.mediaEpisodeAutoExpand.v1",
            @"cctv.mediaKeepScreenAwake", @"allowBackgroundAudio", @"autoPiP", @"autoLoadEPG",
            @"rememberLastChannel", @"resumeLastChannel", @"cctv.mediaPreferredQuality.v1",
            @"cctv.mediaGridColumns.v1", @"cctv.mediaHome.modules.v1", @"cctv.mediaAutoPlayNext", @"cctv.mediaAutoSkipIntroOutro",
            @"cctv.mediaPlaybackRate", @"cctv.mediaVideoGravity", @"cctv.mediaDecodeMode.v1", @"media.globalSearchHistoryEnabled.v1",
            @"fastNativeStartup", @"preloadNativeChannel", @"legacyNativePlayback",
            @"cctv.networkTimeout.v1", @"nativeSDKVerboseLogs", @"runtimeDiagnosticsEnabled", @"cctv.adaptationMonitor.enabled", @"cctv.allowPublicMediaResolvers"
        ];
        for(NSString *k in keysToReset)[d removeObjectForKey:k];
        MediaAdaptationMonitor.shared.monitoringEnabled=YES;
        UIWindow *window=self.view.window;
        if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);HostRefreshAppearanceLayers(window);}
        [self reloadThemeAppearance];
        [self.table reloadData];
        if(self.onPreferenceChanged)self.onPreferenceChanged(@"resetDefaultPreferences",YES);
        [NSNotificationCenter.defaultCenter postNotificationName:@"HostThemeDidChangeNotification" object:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaDisplayConfigurationDidChangeNotification" object:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:CCTVMediaEpisodeLayoutStyleDidChangeNotification object:@0];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"已恢复默认偏好设置");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearMediaMetadata:(NSIndexPath *)indexPath {
    NSDictionary *summary=[MediaMetadataCache.shared summary];
    NSString *size=[NSByteCountFormatter stringFromByteCount:[summary[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleMemory];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理影视元数据缓存？" message:[NSString stringWithFormat:@"将清理 %lu 项影视元数据缓存（%@）。详情仅短时保留在内存中，播放地址不持久化；收藏、观看历史、订阅和插件数据会保留。",(unsigned long)[summary[@"entries"] unsignedIntegerValue],size] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [MediaMetadataCache.shared clear];
        [self refreshHeroSummaryChips];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"影视元数据缓存已清理");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearAllCaches {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理全部缓存？" message:@"将清理节目单缓存、台标缓存与影视元数据缓存。收藏、观看历史、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        SettingsRemoveEPGCacheFile();
        if(self.onClearEPG)self.onClearEPG();
        [HostImageLoader.shared clearCache];
        [HostImageLoader.shared clearDiskCache];
        self.clearedImagesState=YES;
        [MediaMetadataCache.shared clear];
        [self refreshHeroSummaryChips];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"全部缓存已清理");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearWatchHistory {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除观看历史？" message:@"将清除本机最近观看的频道记录与影视点播观看历史。收藏、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if(self.onClearWatchHistory)self.onClearWatchHistory();
        [MediaPlaybackStateStore clearWatchHistory];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.mediaSkipPoints.v1"];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"观看历史已清除");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearFavorites {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除收藏？" message:@"将清除全部频道收藏与影视点播收藏。观看历史、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除收藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if(self.onClearFavorites)self.onClearFavorites();
        [HostLibraryStore.shared replaceMediaFavorites:@{}];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"收藏已清除");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearProgramReminders {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除节目单预约提醒？" message:@"将清空所有已设置的频道节目单开播提醒记录并取消待触发的系统本地通知。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除预约" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        NSDictionary *stored=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.epgReminders.v1"];
        if([stored isKindOfClass:NSDictionary.class]&&stored.count){
            NSMutableArray<NSString *> *identifiers=[NSMutableArray arrayWithCapacity:stored.count*3];
            for(id rawKey in stored.allKeys){
                if(![rawKey isKindOfClass:NSString.class])continue;
                NSString *key=(NSString *)rawKey;
                [identifiers addObject:key];
                [identifiers addObject:[@"epg.reminder." stringByAppendingString:key]];
                [identifiers addObject:[@"cctv.epg." stringByAppendingString:key]];
            }
            if(identifiers.count){
                [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:identifiers];
            }
        }
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.epgReminders.v1"];
        [NSNotificationCenter.defaultCenter postNotificationName:@"CCTVEpgRemindersDidChangeNotification" object:nil];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"节目单预约提醒已清除");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearSearchHistory {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除搜索历史？" message:@"将清除本机保存的搜索关键词，以及影视浏览状态里保存的关键词。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];
        id rawBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];
        NSMutableDictionary *browse=[rawBrowse isKindOfClass:NSDictionary.class]?[rawBrowse mutableCopy]:[NSMutableDictionary dictionary];
        for(NSString *key in browse.allKeys){NSMutableDictionary *state=[browse[key] mutableCopy];if([state isKindOfClass:NSDictionary.class]){state[@"keyword"]=@"";browse[key]=state;}}
        [NSUserDefaults.standardUserDefaults setObject:browse forKey:@"media.browseStates.v1"];
        BOOL enabled=[[NSUserDefaults standardUserDefaults] boolForKey:@"media.globalSearchHistoryEnabled.v1"];
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaGlobalSearchHistoryDidChange" object:nil userInfo:@{@"enabled":@(enabled),@"cleared":@YES}];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"搜索历史已清除");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showPrivacyStatement {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"隐私说明" message:@"收藏、观看历史和偏好保存在本机。订阅、节目单、播放和插件会按配置访问对应的网络来源，来源可能收到请求中的地址和认证信息。第三方公共视频解析默认关闭；开启后，商业视频网页地址、片名或分集信息可能发送给外部解析服务。合集内由你选择的解析接口仍只使用对应合集声明的地址。诊断记录保存在本机，可导出或清空；导出前请检查内容，备份和原始资源可能包含完整地址及凭据。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)appearanceChanged:(UISegmentedControl *)sender {
    SettingsTriggerHapticSelection();
    NSString *mode=sender.selectedSegmentIndex==0?@"system":(sender.selectedSegmentIndex==1?@"light":@"dark");
    BOOL dark=[mode isEqual:@"dark"];
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:HostThemeModePreferenceKey];
    if(![mode isEqual:@"system"]){
        [NSUserDefaults.standardUserDefaults setBool:dark forKey:HostDarkThemePreferenceKey];
        HostThemePalette *palette=[HostThemePalette currentPalette];
        if(dark && !palette.dark){
            [HostThemePalette setCurrentPaletteIdentifier:HostThemePalette.defaultDarkPalette.identifier];
        } else if(!dark && palette.dark){
            [HostThemePalette setCurrentPaletteIdentifier:HostThemePalette.defaultLightPalette.identifier];
        }
    }
    UIWindow *window=self.view.window;
    if(window){
        HostApplyThemeToWindow(window);
        HostStyleNavigation(self.navigationController);
        dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);[self.table reloadData];});
    }
    [self reloadThemeAppearance];
    [self.table reloadData];
    if(self.onPreferenceChanged)self.onPreferenceChanged(HostThemeModePreferenceKey,HostIsDarkThemeSelected());
    [[NSNotificationCenter defaultCenter] postNotificationName:@"HostThemeDidChangeNotification" object:nil];
}

- (NSIndexPath *)indexPathForRowAction:(NSString *)action {
    for(NSInteger s=0;s<self.sections.count;s++){
        NSArray *rows=self.sections[s][@"rows"];
        for(NSInteger r=0;r<rows.count;r++)
            if([rows[r][@"action"] isEqualToString:action])return [NSIndexPath indexPathForRow:r inSection:s];
    }
    return nil;
}

- (void)confirmClearEPG {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理节目单缓存" message:@"缓存将在下次访问频道时重新获取。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        BOOL ok=SettingsRemoveEPGCacheFile();
        if(ok&&self.onClearEPG) self.onClearEPG();
        if(ok){
            [self refreshHeroSummaryChips];
            NSIndexPath *epgRow=[self indexPathForRowAction:@"clearEPG"];
            if(epgRow)[self.table reloadRowsAtIndexPaths:@[epgRow] withRowAnimation:UITableViewRowAnimationNone];
        }
        UIAlertController *done=[UIAlertController alertControllerWithTitle:@"缓存" message:ok?@"节目单缓存已清理。":@"节目单缓存清理失败，请重试。" preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
