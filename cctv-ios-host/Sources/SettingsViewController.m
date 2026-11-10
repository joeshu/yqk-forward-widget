#import "SettingsViewController.h"
#import "HostTheme.h"
#import "HostImageLoader.h"
#import "MediaMetadataCache.h"
#import "MediaPlaybackStateStore.h"
#import <math.h>
#import <AVFoundation/AVFoundation.h>

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

static NSString *SettingsEPGCacheFilePath(void) {
    NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES);
    return [[dirs firstObject] stringByAppendingPathComponent:@"epg-cache.json"];
}

static NSString *SettingsEPGCacheSizeText(void) {
    NSDictionary *attrs=[NSFileManager.defaultManager attributesOfItemAtPath:SettingsEPGCacheFilePath() error:NULL];
    if(!attrs)return @"无缓存 · 下次打开频道时重新获取";
    NSString *size=[NSByteCountFormatter stringFromByteCount:[attrs fileSize] countStyle:NSByteCountFormatterCountStyleMemory];
    return [NSString stringWithFormat:@"%@ · 下次打开频道时重新获取",size];
}

static BOOL SettingsRemoveEPGCacheFile(void) {
    NSString *p=SettingsEPGCacheFilePath();
    NSError *error=nil;
    return ![NSFileManager.defaultManager fileExistsAtPath:p]||[NSFileManager.defaultManager removeItemAtPath:p error:&error];
}

static NSString *SettingsMediaDisplaySummaryText(void) {
    NSInteger cols=[[NSUserDefaults standardUserDefaults] integerForKey:@"cctv.mediaGridColumns.v1"]==4?4:3;
    NSArray *saved=[[NSUserDefaults standardUserDefaults] arrayForKey:@"cctv.mediaHome.modules.v1"];
    NSUInteger moduleCount=saved?saved.count:3;
    return [NSString stringWithFormat:@"精选模块与海报布局 · %lu 模块 / %ld 列",(unsigned long)moduleCount,(long)cols];
}

static NSString *SettingsWatchHistorySummaryText(void) {
    NSUInteger liveCount=[[[NSUserDefaults standardUserDefaults] arrayForKey:@"recents"] count];
    NSUInteger vodCount=[MediaPlaybackStateStore.watchHistory count];
    return [NSString stringWithFormat:@"本机最近观看的频道与影视（频道 %lu · 影视 %lu）",(unsigned long)liveCount,(unsigned long)vodCount];
}

static NSString *SettingsFavoritesSummaryText(void) {
    NSUInteger liveCount=[[[NSUserDefaults standardUserDefaults] arrayForKey:@"favorites"] count];
    NSDictionary *vodFavs=[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"cctv.mediaFavorites.v1"];
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

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UIView *heroHeaderView;
@property(nonatomic,strong) UIView *settingsTopImmersiveScrim;
@property(nonatomic,strong) CAGradientLayer *settingsTopImmersiveGradient;
@property(nonatomic,strong) UIStackView *heroSummaryChipsStack;
@property(nonatomic,strong) UIScrollView *categoryFilterScroll;
@property(nonatomic,strong) UIStackView *categoryFilterStack;
@property(nonatomic,copy) NSString *selectedCategoryKey;
@property(nonatomic) CGFloat bottomOverlayInset;
@property(nonatomic,strong) NSArray<NSDictionary *> *allSections;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@property(nonatomic,copy,nullable) NSString *lastUpdateCheckText;
@property(nonatomic,assign) BOOL checkingUpdate;
@property(nonatomic,assign) BOOL clearedImagesState;
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
        @{@"id":@"storage", @"title":@"数据与缓存", @"icon":@"externaldrive.fill.badge.checkmark"},
        @{@"id":@"about", @"title":@"服务与关于", @"icon":@"info.circle.fill"}
    ];
}

- (void)buildSettingsSchema {
    self.allSections=@[
      @{ @"category":@"appearance", @"title":@"外观与界面导航", @"footer":@"主题实时应用于全局；下方色板提供 6 套主题（4 套深色沉浸、2 套浅色），点选即时生效，无需重启。字号与底部导航偏好即时刷新生效。", @"rows":@[
        @{ @"title":@"全局主题", @"detail":@"系统 / 浅色 / 深色 · 全端即时响应", @"key":HostThemeModePreferenceKey, @"appearance":@YES, @"icon":@"circle.lefthalf.filled" },
        @{ @"title":@"主题色板", @"detail":@"午夜影院", @"action":@"themePalette", @"icon":@"paintpalette" },
        @{ @"title":@"字号", @"detail":@"应用内全局动态字号档位", @"key":@"cctv.appFontSize.v1", @"segmented":@YES, @"options":@[@"标准",@"大",@"特大"], @"values":@[@0,@1,@2], @"default":@0, @"icon":@"textformat.size" },
        @{ @"title":@"启动时恢复上次打开的页面", @"detail":@"关闭后每次启动默认进入央视直播页", @"key":@"cctv.restoreLastTab.v1", @"icon":@"arrow.uturn.left", @"default":@YES }
      ]},
      @{ @"category":@"live", @"title":@"直播与频道管理", @"footer":@"集中管理内置央视频道展示、频道网格/列表视图、排序方式及直播画中画。播放时屏幕常亮对央视与订阅直播同时生效。", @"rows":@[
        @{ @"title":@"显示内置央视频道", @"detail":@"在直播与频道列表中展示内置央视/卫视频道", @"key":@"nativeChannelsEnabled", @"icon":@"tv.badge.wifi", @"default":@YES },
        @{ @"title":@"频道用网格显示", @"detail":@"切换频道列表为海报卡片网格或紧凑列表", @"key":@"channelGridMode", @"icon":@"square.grid.2x2", @"default":@YES },
        @{ @"title":@"频道网格列数", @"detail":@"网格模式下的单行频道卡片数量", @"key":@"cctv.channelGridColumns.v1", @"segmented":@YES, @"options":@[@"3 列",@"4 列"], @"values":@[@3,@4], @"default":@4, @"icon":@"rectangle.grid.3x2" },
        @{ @"title":@"频道排序方式", @"detail":@"按默认频道分组顺序或按频道名称排序", @"key":@"cctv.channelSortMode.v1", @"segmented":@YES, @"options":@[@"默认",@"名称"], @"values":@[@0,@1], @"default":@0, @"icon":@"arrow.up.arrow.down" },
        @{ @"title":@"播放时屏幕常亮", @"detail":@"直播与点播播放期间防止自动锁屏息屏", @"key":@"cctv.mediaKeepScreenAwake", @"icon":@"sun.max", @"default":@YES },
        @{ @"title":@"允许后台音频播放", @"detail":@"切到后台或锁屏时保持直播声音输出", @"key":@"allowBackgroundAudio", @"icon":@"speaker.wave.2", @"default":@YES },
        @{ @"title":@"订阅流自动画中画", @"detail":@"退回主屏幕时自动开启系统内联画中画", @"key":@"autoPiP", @"icon":@"pip", @"default":@NO },
        @{ @"title":@"自动获取节目单", @"detail":@"打开频道时自动同步并刷新 EPG 节目预告", @"key":@"autoLoadEPG", @"icon":@"list.bullet.rectangle", @"default":@YES },
        @{ @"title":@"记住上次观看频道", @"detail":@"记录最后一次播放的直播频道", @"key":@"rememberLastChannel", @"icon":@"bookmark", @"default":@YES },
        @{ @"title":@"启动时自动续播上次频道", @"detail":@"进入应用时自动拉起上次记住的频道", @"key":@"resumeLastChannel", @"icon":@"arrow.counterclockwise", @"default":@NO },
        @{ @"title":@"默认清晰度", @"detail":SettingsPreferredQualityText(), @"action":@"defaultQuality", @"icon":@"4k.tv" }
      ]},
      @{ @"category":@"vod", @"title":@"影视与点播体验", @"footer":@"调整影视精选首页模块、海报网格列数与点播默认策略。自动跳过仅对已标记片头片尾位置的剧集生效；播放参数在播放器内也可随时调整。", @"rows":@[
        @{ @"title":@"媒体显示", @"detail":SettingsMediaDisplaySummaryText(), @"action":@"mediaDisplay", @"icon":@"rectangle.grid.2x2" },
        @{ @"title":@"影视海报网格列数", @"detail":@"分类浏览与聚合列表的海报卡片密度", @"key":@"cctv.mediaGridColumns.v1", @"segmented":@YES, @"options":@[@"3 列",@"4 列"], @"values":@[@3,@4], @"default":@3, @"icon":@"square.grid.3x2" },
        @{ @"title":@"自动连播下一集", @"detail":@"本集播放结束后自动切换并播放下一集", @"key":@"cctv.mediaAutoPlayNext", @"icon":@"forward.end.fill", @"default":@YES },
        @{ @"title":@"自动跳过片头片尾", @"detail":@"按本机已保存的片头片尾锚点自动跳过", @"key":@"cctv.mediaAutoSkipIntroOutro", @"icon":@"forward.end.circle", @"default":@NO },
        @{ @"title":@"默认播放速度", @"detail":SettingsPlaybackRateText(), @"action":@"defaultPlaybackRate", @"icon":@"speedometer" },
        @{ @"title":@"默认画面比例", @"detail":SettingsVideoGravityText(), @"action":@"defaultVideoGravity", @"icon":@"aspectratio" },
        @{ @"title":@"保存搜索历史", @"detail":@"在影视全局搜索与分类浏览中保留历史搜索词", @"key":@"media.globalSearchHistoryEnabled.v1", @"icon":@"magnifyingglass", @"default":@NO }
      ]},
      @{ @"category":@"engine", @"title":@"播放引擎与网络性能", @"footer":@"快速起播降低首帧前的缓冲门槛，出画面后恢复 SDK 原值；预解析提前缓存相邻频道信息。网络请求超时统一控制 Spider、TVBox、MacCMS 与全局搜索等待时间。", @"rows":@[
        @{ @"title":@"原生播放器快速起播", @"detail":@"降低首帧前缓冲水位，提升切台响应速度", @"key":@"fastNativeStartup", @"icon":@"bolt", @"default":@YES },
        @{ @"title":@"预解析下一个 CCTV 频道", @"detail":@"空闲时预热相邻央视频道线路信息", @"key":@"preloadNativeChannel", @"icon":@"forward.end", @"default":@YES },
        @{ @"title":@"复用原生播放器", @"detail":@"切台时复用已有播放器实例以减少重建开销", @"key":@"legacyNativePlayback", @"icon":@"backward.end", @"default":@YES },
        @{ @"title":@"网络请求超时", @"detail":@"影视接口、目录抓取与搜索请求超时上限", @"key":@"cctv.networkTimeout.v1", @"segmented":@YES, @"options":@[@"10 秒",@"20 秒",@"40 秒"], @"values":@[@10,@20,@40], @"default":@20, @"icon":@"network" },
        @{ @"title":@"SDK 详细日志（诊断）", @"detail":@"输出底层播放器 SDK 调试日志供排障分析", @"key":@"nativeSDKVerboseLogs", @"icon":@"doc.text", @"default":@NO }
      ]},
      @{ @"category":@"diagnostics", @"title":@"运行诊断与日志中心", @"footer":@"开启后记录应用启动、影视加载与播放阶段、海报失败和系统内存告警。每次 App 运行单独存档，单次最多 4 MiB。日志默认脱敏，不记录敏感参数。", @"rows":@[
        @{ @"title":@"运行诊断模式", @"detail":@"先开启再复现；若闪退，重开 App 后导出", @"key":@"runtimeDiagnosticsEnabled", @"icon":@"waveform.path.ecg", @"default":@NO },
        @{ @"title":@"运行诊断记录", @"detail":@"按 App 运行分开查看 · 可单次导出、删除或清空", @"action":@"runtimeDiagnostics", @"icon":@"list.bullet.rectangle" },
        @{ @"title":@"日志中心", @"action":@"logs", @"detail":@"总日志与各插件独立日志", @"icon":@"doc.text.magnifyingglass" }
      ]},
      @{ @"category":@"storage", @"title":@"数据备份与存储管理", @"footer":@"目录、分类和搜索结果可保存；影片详情仅短时缓存在内存中，播放地址不持久化。清理缓存或恢复默认偏好时，收藏、观看历史、订阅和插件数据会保留。", @"rows":@[
        @{ @"title":@"导出本机配置", @"detail":@"导出订阅、收藏、观看历史与全量偏好备份", @"action":@"export", @"icon":@"square.and.arrow.up" },
        @{ @"title":@"导入配置文件", @"detail":@"从 JSON 备份恢复配置并立即应用主题与字号", @"action":@"import", @"icon":@"square.and.arrow.down" },
        @{ @"title":@"恢复默认偏好设置", @"detail":@"重置界面与播放偏好为默认值（保留订阅与收藏）", @"action":@"resetDefaultPreferences", @"icon":@"arrow.counterclockwise.circle" },
        @{ @"title":@"清理全部缓存", @"detail":@"节目单、台标与影视元数据缓存", @"icon":@"trash.fill", @"action":@"clearAllCaches" },
        @{ @"title":@"清理节目单缓存", @"detail":SettingsEPGCacheSizeText(), @"icon":@"trash", @"action":@"clearEPG" },
        @{ @"title":@"清理台标缓存", @"detail":@"清理内存中的缩略图", @"icon":@"photo", @"action":@"clearImages" },
        @{ @"title":@"清理影视元数据缓存", @"detail":MediaMetadataCacheSummaryText(), @"icon":@"film", @"action":@"clearMediaMetadata" },
        @{ @"title":@"清除观看历史", @"detail":SettingsWatchHistorySummaryText(), @"icon":@"clock.arrow.circlepath", @"action":@"clearWatchHistory" },
        @{ @"title":@"清除收藏", @"detail":SettingsFavoritesSummaryText(), @"icon":@"heart.slash", @"action":@"clearFavorites" },
        @{ @"title":@"清除节目单预约提醒", @"detail":SettingsEPGRemindersSummaryText(), @"icon":@"bell.slash", @"action":@"clearEPGReminders" },
        @{ @"title":@"清除搜索历史", @"detail":SettingsSearchHistorySummaryText(), @"icon":@"magnifyingglass.circle", @"action":@"clearSearchHistory" }
      ]},
      @{ @"category":@"about", @"title":@"服务直达与关于", @"footer":@"只保存在本机，不会上传到任何服务器。内置 Python / Node.js Mobile / JavaScriptCore 引擎在本地沙盒安全运行。", @"rows":@[
        @{ @"title":@"央视直播", @"detail":@"官方 CNPlayerSDK · VDN 自动选线", @"action":@"openTabLive", @"icon":@"tv" },
        @{ @"title":@"M3U / HLS 订阅", @"detail":@"AVPlayer · iOS 系统解码", @"action":@"openTabChannels", @"icon":@"play.rectangle" },
        @{ @"title":@"影视点播库", @"detail":@"Spider / TVBox / MacCMS 聚合影院", @"action":@"openTabMedia", @"icon":@"film" },
        @{ @"title":@"资源与配置中心", @"detail":@"管理直播订阅、影视站点与插件包", @"action":@"openTabResources", @"icon":@"square.stack.3d.up" },
        @{ @"title":@"内置插件", @"detail":@"Python / JavaScriptCore · 本机运行", @"action":@"openServices", @"icon":@"curlybraces" },
        @{ @"title":@"隐私说明", @"detail":@"数据如何保存与使用", @"action":@"privacy", @"icon":@"hand.raised" },
        @{ @"title":@"CCTVHost", @"detail":[NSString stringWithFormat:@"%@ (%@) · %@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"开发版",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?",[[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"] isEqual:@"no-python"]?@"无 Python 诊断版":@"完整版"], @"icon":@"info.circle" },
        @{ @"title":@"检查更新", @"detail":@"点按检查最新发布", @"action":@"checkUpdate", @"icon":@"arrow.down.circle" }
      ]}
    ];
    [self applyCategoryFilter];
}

- (void)applyCategoryFilter {
    if(!self.selectedCategoryKey.length || [self.selectedCategoryKey isEqualToString:@"all"]){
        self.sections=self.allSections;
        return;
    }
    NSMutableArray<NSDictionary *> *filtered=[NSMutableArray array];
    for(NSDictionary *sec in self.allSections){
        if([sec[@"category"] isEqualToString:self.selectedCategoryKey]){
            [filtered addObject:sec];
        }
    }
    self.sections=filtered.count?filtered:self.allSections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"设置";
    self.selectedCategoryKey=@"all";
    self.view.backgroundColor=HostBackground();
    self.navigationController.navigationBar.tintColor=HostAccent();
    [self buildSettingsSchema];

    self.table=[[UITableView alloc]initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints=NO;
    self.table.backgroundColor=UIColor.clearColor;
    self.table.dataSource=self;
    self.table.delegate=self;
    self.table.rowHeight=UITableViewAutomaticDimension;
    self.table.estimatedRowHeight=68;
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
}

- (void)refreshHeroSummaryChips {
    if(!self.heroSummaryChipsStack)return;
    NSArray<UIView *> *chips=self.heroSummaryChipsStack.arrangedSubviews;
    NSArray<NSString *> *texts=@[
        [NSString stringWithFormat:@"  🎨 %@  ", [HostThemePalette currentPalette].displayName],
        [NSString stringWithFormat:@"  📺 画质·%@  ", SettingsPreferredQualityText()],
        @"  🛡️ 纯本地无上传  "
    ];
    for(NSUInteger i=0;i<chips.count&&i<texts.count;i++){
        if([chips[i] isKindOfClass:UILabel.class])((UILabel *)chips[i]).text=texts[i];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if(!self.heroHeaderView)[self setupHeroHeaderView];
    else [self refreshHeroSummaryChips];
    [self.table reloadData];
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

- (void)setupHeroHeaderView {
    if(self.heroHeaderView){
        [self.heroHeaderView removeFromSuperview];
        self.heroHeaderView=nil;
    }
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,CGRectGetWidth(self.view.bounds)?:390,180)];
    header.autoresizingMask=UIViewAutoresizingFlexibleWidth;

    UIView *card=[UIView new];
    card.translatesAutoresizingMaskIntoConstraints=NO;
    HostStyleGlassCard(card,18);
    [header addSubview:card];

    UIView *iconBox=[UIView new];
    iconBox.translatesAutoresizingMaskIntoConstraints=NO;
    iconBox.backgroundColor=[HostAccent() colorWithAlphaComponent:0.18];
    iconBox.layer.cornerRadius=14;
    iconBox.layer.cornerCurve=kCACornerCurveContinuous;
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
    [card addSubview:titleLabel];

    UILabel *subtitleLabel=[UILabel new];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints=NO;
    subtitleLabel.text=@"Spatial Glass 2.0 · 全域视听与系统设置中心";
    subtitleLabel.textColor=HostSecondaryText();
    subtitleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    [card addSubview:subtitleLabel];

    UIStackView *chipsStack=[UIStackView new];
    chipsStack.translatesAutoresizingMaskIntoConstraints=NO;
    chipsStack.axis=UILayoutConstraintAxisHorizontal;
    chipsStack.spacing=8;
    chipsStack.distribution=UIStackViewDistributionFillProportionally;
    [card addSubview:chipsStack];
    self.heroSummaryChipsStack=chipsStack;

    NSString *qualityLabel=SettingsPreferredQualityText();
    NSArray<NSDictionary *> *chipData=@[
        @{@"text":[NSString stringWithFormat:@"  🎨 %@  ", [HostThemePalette currentPalette].displayName]},
        @{@"text":[NSString stringWithFormat:@"  📺 画质·%@  ", qualityLabel]},
        @{@"text":@"  🛡️ 纯本地无上传  "}
    ];
    for(NSDictionary *item in chipData){
        UILabel *chip=[UILabel new];
        chip.text=item[@"text"];
        chip.font=HostRoundedFont(11,UIFontWeightSemibold,UIFontTextStyleCaption2);
        chip.textColor=HostSecondaryText();
        chip.backgroundColor=[HostText() colorWithAlphaComponent:0.06];
        chip.layer.cornerRadius=8;
        chip.layer.cornerCurve=kCACornerCurveContinuous;
        chip.layer.borderWidth=0.5;
        HostSetLayerBorderColor(chip,HostBorder());
        chip.clipsToBounds=YES;
        chip.textAlignment=NSTextAlignmentCenter;
        [chipsStack addArrangedSubview:chip];
    }

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
        BOOL selected=[cat[@"id"] isEqualToString:(self.selectedCategoryKey?:@"all")];
        UIButton *pill=[UIButton buttonWithType:UIButtonTypeSystem];
        pill.translatesAutoresizingMaskIntoConstraints=NO;
        pill.tag=(NSInteger)idx;
        pill.accessibilityIdentifier=[NSString stringWithFormat:@"settings.category.%@",cat[@"id"]];
        pill.accessibilityLabel=[NSString stringWithFormat:@"筛选%@",cat[@"title"]];
        UIImageSymbolConfiguration *symCfg=[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
        UIImage *icon=[UIImage systemImageNamed:cat[@"icon"] withConfiguration:symCfg];
        [pill setImage:icon forState:UIControlStateNormal];
        [pill setTitle:[NSString stringWithFormat:@" %@",cat[@"title"]] forState:UIControlStateNormal];
        pill.titleLabel.font=[UIFont systemFontOfSize:13 weight:selected?UIFontWeightSemibold:UIFontWeightMedium];
        pill.tintColor=selected?HostOnAccent():HostSecondaryText();
        [pill setTitleColor:selected?HostOnAccent():HostText() forState:UIControlStateNormal];
        pill.backgroundColor=selected?HostAccent():HostCard();
        pill.layer.cornerRadius=16;
        pill.layer.cornerCurve=kCACornerCurveContinuous;
        pill.layer.borderWidth=0.6;
        HostSetLayerBorderColor(pill,selected?HostAccent():HostBorder());
        pill.contentEdgeInsets=UIEdgeInsetsMake(6,12,6,12);
        [pill.heightAnchor constraintGreaterThanOrEqualToConstant:32].active=YES;
        HostInstallPressFeedback(pill);
        [pill addTarget:self action:@selector(selectCategoryPill:) forControlEvents:UIControlEventTouchUpInside];
        [filterStack addArrangedSubview:pill];
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [card.heightAnchor constraintEqualToConstant:120],

        [iconBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [iconBox.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [iconBox.widthAnchor constraintEqualToConstant:46],
        [iconBox.heightAnchor constraintEqualToConstant:46],

        [iconView.centerXAnchor constraintEqualToAnchor:iconBox.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconBox.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26],
        [iconView.heightAnchor constraintEqualToConstant:26],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconBox.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:3],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [chipsStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [chipsStack.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],
        [chipsStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [chipsStack.heightAnchor constraintEqualToConstant:24],

        [filterScroll.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:10],
        [filterScroll.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [filterScroll.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [filterScroll.heightAnchor constraintEqualToConstant:38],

        [filterStack.leadingAnchor constraintEqualToAnchor:filterScroll.contentLayoutGuide.leadingAnchor constant:16],
        [filterStack.trailingAnchor constraintEqualToAnchor:filterScroll.contentLayoutGuide.trailingAnchor constant:-16],
        [filterStack.centerYAnchor constraintEqualToAnchor:filterScroll.frameLayoutGuide.centerYAnchor]
    ]];

    self.heroHeaderView=header;
    self.table.tableHeaderView=header;
}

- (void)selectCategoryPill:(UIButton *)sender {
    NSArray<NSDictionary *> *categories=[self categoryFilterDefinitions];
    if(sender.tag<0 || sender.tag>=(NSInteger)categories.count)return;
    NSString *nextKey=categories[sender.tag][@"id"];
    if([self.selectedCategoryKey isEqualToString:nextKey])return;
    self.selectedCategoryKey=nextKey;
    [self applyCategoryFilter];
    NSArray<UIView *> *pills=self.categoryFilterStack.arrangedSubviews;
    for(NSUInteger idx=0; idx<pills.count && idx<categories.count; idx++){
        if(![pills[idx] isKindOfClass:UIButton.class])continue;
        UIButton *pill=(UIButton *)pills[idx];
        BOOL selected=[categories[idx][@"id"] isEqualToString:nextKey];
        pill.titleLabel.font=[UIFont systemFontOfSize:13 weight:selected?UIFontWeightSemibold:UIFontWeightMedium];
        pill.tintColor=selected?HostOnAccent():HostSecondaryText();
        [pill setTitleColor:selected?HostOnAccent():HostText() forState:UIControlStateNormal];
        pill.backgroundColor=selected?HostAccent():HostCard();
        HostSetLayerBorderColor(pill,selected?HostAccent():HostBorder());
    }
    if(self.categoryFilterScroll)[self.categoryFilterScroll scrollRectToVisible:CGRectInset(sender.frame,-16,0) animated:YES];
    [self.table reloadData];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
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
    if(previousTraitCollection&&![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self.table reloadData];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section][@"title"];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.sections[section][@"footer"];
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    HostStyleSectionHeaderView(view);
}
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
    HostStyleSectionFooterView(view);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting.row"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting.row"];
    NSDictionary *row=self.sections[ip.section][@"rows"][ip.row];
    cell.textLabel.text=row[@"title"];
    cell.textLabel.textColor=HostText();
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.textLabel.numberOfLines=0;
    cell.detailTextLabel.text=row[@"detail"];

    if([row[@"action"] isEqualToString:@"mediaDisplay"])cell.detailTextLabel.text=SettingsMediaDisplaySummaryText();
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
    if([row[@"action"] isEqualToString:@"themePalette"])cell.detailTextLabel.text=[HostThemePalette currentPalette].displayName;
    if([row[@"action"] isEqualToString:@"checkUpdate"])cell.detailTextLabel.text=self.lastUpdateCheckText?:@"点按检查最新发布";

    cell.detailTextLabel.textColor=HostSecondaryText();
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.numberOfLines=0;

    // 2026 Spatial Glass Squircle Icon Badge
    NSString *iconName=row[@"icon"]?:@"gearshape";
    UIImageSymbolConfiguration *symCfg=[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIImage *baseImg=[UIImage systemImageNamed:iconName withConfiguration:symCfg];
    cell.imageView.image=baseImg;
    cell.imageView.tintColor=HostAccent();

    cell.backgroundColor=HostCard(); cell.layer.cornerRadius=14; cell.layer.cornerCurve=kCACornerCurveContinuous; cell.clipsToBounds=YES; cell.layer.borderWidth=0.6; HostSetLayerBorderColor(cell,HostBorder());
    cell.accessoryView=nil;
    cell.accessoryType=UITableViewCellAccessoryNone;
    cell.selectionStyle=UITableViewCellSelectionStyleNone;

    NSString *key=row[@"key"];
    if([row[@"appearance"] boolValue]){
        UISegmentedControl *style=[[UISegmentedControl alloc] initWithItems:@[@"系统",@"浅色",@"深色"]];
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
        id saved=[[NSUserDefaults standardUserDefaults] objectForKey:key];
        sw.on=saved? [saved boolValue]:[row[@"default"] boolValue];
        sw.accessibilityIdentifier=key;
        sw.accessibilityLabel=row[@"title"];
        [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView=sw;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else if(row[@"action"]){
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    }
    else {
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)toggle:(UISwitch *)sender {
    if(!sender.accessibilityIdentifier.length)return;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults setBool:sender.on forKey:sender.accessibilityIdentifier];
    if ([sender.accessibilityIdentifier isEqualToString:@"rememberLastChannel"] && !sender.on) [defaults removeObjectForKey:@"lastChannel"];
    if ([sender.accessibilityIdentifier isEqualToString:@"cctv.restoreLastTab.v1"] && !sender.on) [defaults removeObjectForKey:@"cctv.lastBottomTab.v1"];
    if ([sender.accessibilityIdentifier isEqualToString:@"media.globalSearchHistoryEnabled.v1"]) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaGlobalSearchHistoryDidChange" object:nil userInfo:@{@"enabled":@(sender.on),@"cleared":@NO}];
    }
    if(self.onPreferenceChanged) self.onPreferenceChanged(sender.accessibilityIdentifier,sender.on);
}

- (void)segmentedChanged:(UISegmentedControl *)sender {
    NSArray *values=nil;
    for(NSDictionary *section in self.allSections)
        for(NSDictionary *row in section[@"rows"])
            if([row[@"key"] isEqualToString:sender.accessibilityIdentifier]&&[row[@"segmented"] boolValue])values=row[@"values"];
    if(!values||sender.selectedSegmentIndex<0||sender.selectedSegmentIndex>=(NSInteger)values.count)return;
    NSInteger value=[values[sender.selectedSegmentIndex] integerValue];
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:sender.accessibilityIdentifier];
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
    if([row[@"action"] isEqualToString:@"clearEPG"]) [self confirmClearEPG];
    else if([row[@"action"] isEqualToString:@"clearImages"]){
        [HostImageLoader.shared clearCache];
        self.clearedImagesState=YES;
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"台标缓存已清理");
        UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];
        cell.detailTextLabel.text=@"已清理，下次加载时重新获取";
    }
    else if([row[@"action"] isEqualToString:@"clearMediaMetadata"]) [self confirmClearMediaMetadata:ip];
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
    else if([row[@"action"] isEqualToString:@"themePalette"]) [self presentThemePicker:ip];
    else if([row[@"action"] isEqualToString:@"checkUpdate"]) [self checkForUpdateFromIndexPath:ip];
    else if([row[@"action"] isEqualToString:@"openTabLive"]){if(self.onOpenTab)self.onOpenTab(0);}
    else if([row[@"action"] isEqualToString:@"openTabChannels"]){if(self.onOpenTab)self.onOpenTab(1);}
    else if([row[@"action"] isEqualToString:@"openTabMedia"]){if(self.onOpenTab)self.onOpenTab(2);}
    else if([row[@"action"] isEqualToString:@"openTabResources"]){if(self.onOpenTab)self.onOpenTab(3);}
    else if([row[@"action"] isEqualToString:@"openServices"]){if(self.onOpenServices)self.onOpenServices();}
    else if([row[@"action"] isEqualToString:@"export"]){if(self.onExportData)self.onExportData();}
    else if([row[@"action"] isEqualToString:@"runtimeDiagnostics"]){if(self.onOpenDiagnostics)self.onOpenDiagnostics();}
    else if([row[@"action"] isEqualToString:@"mediaDisplay"]){if(self.onMediaDisplaySettings)self.onMediaDisplaySettings();}
    else if([row[@"action"] isEqualToString:@"import"]){if(self.onImportData)self.onImportData();}
    else if([row[@"action"] isEqualToString:@"logs"]){if(self.onOpenLog)self.onOpenLog();}
}

- (void)presentActionSheet:(UIAlertController *)sheet fromIndexPath:(NSIndexPath *)ip {
    if(self.presentedViewController)return;
    UITableViewCell *cell=[self.table cellForRowAtIndexPath:ip];
    sheet.popoverPresentationController.sourceView=cell?:self.view;
    sheet.popoverPresentationController.sourceRect=cell?cell.bounds:CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentPlaybackRatePicker:(NSIndexPath *)ip {
    double current=[[NSUserDefaults standardUserDefaults] objectForKey:@"cctv.mediaPlaybackRate"]?[[NSUserDefaults standardUserDefaults] doubleForKey:@"cctv.mediaPlaybackRate"]:1.0;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"默认播放速度" message:@"下次播放影视时生效，也可在播放器右上角菜单里临时调整。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSNumber *candidate in @[@0.5,@0.75,@1.0,@1.25,@1.5,@1.75,@2.0]){
        double rate=candidate.doubleValue;
        NSString *title=rate==1.0?@"正常速度":[NSString stringWithFormat:@"%.2gx",rate];
        [sheet addAction:[UIAlertAction actionWithTitle:fabs(current-rate)<0.01?[title stringByAppendingString:@" ✓"]:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            [NSUserDefaults.standardUserDefaults setDouble:rate forKey:@"cctv.mediaPlaybackRate"];
            [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaPlaybackRate",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认播放速度已设为%@",title]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}

- (void)presentVideoGravityPicker:(NSIndexPath *)ip {
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"默认画面比例" message:@"下次播放影视时生效，也可在播放器右上角菜单里临时调整。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *option in @[@{@"title":@"画面适应",@"value":AVLayerVideoGravityResizeAspect},@{@"title":@"铺满裁切",@"value":AVLayerVideoGravityResizeAspectFill},@{@"title":@"拉伸填满",@"value":AVLayerVideoGravityResize}]){
        NSString *title=option[@"title"],*value=option[@"value"];
        [sheet addAction:[UIAlertAction actionWithTitle:[current isEqual:value]?[title stringByAppendingString:@" ✓"]:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaVideoGravity"];
            [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaVideoGravity",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认画面比例已设为%@",title]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}

- (void)presentPreferredQualityPicker:(NSIndexPath *)ip {
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"默认清晰度" message:@"对多码率 HLS 流生效（影视页与直播 AVPlayer 回退）；央视直播走 SDK 时由 VDN 自动选线；单文件 MP4 无多码率可选。下次播放生效。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *option in @[@{@"title":@"自动",@"value":@"auto"},@{@"title":@"流畅",@"value":@"smooth"},@{@"title":@"高清",@"value":@"hd"},@{@"title":@"超清",@"value":@"uhd"}]){
        NSString *title=option[@"title"],*value=option[@"value"];
        [sheet addAction:[UIAlertAction actionWithTitle:[current isEqual:value]?[title stringByAppendingString:@" ✓"]:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaPreferredQuality.v1"];
            [self setupHeroHeaderView];
            [self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
            if(self.onPreferenceChanged)self.onPreferenceChanged(@"cctv.mediaPreferredQuality.v1",YES);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认清晰度已设为%@",title]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
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
            NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data?:[NSData data] options:0 error:NULL];
            NSString *name=[json isKindOfClass:NSDictionary.class]&&[json[@"name"] isKindOfClass:NSString.class]?json[@"name"]:@"";
            NSString *htmlURL=[json isKindOfClass:NSDictionary.class]&&[json[@"html_url"] isKindOfClass:NSString.class]?json[@"html_url"]:@"";
            NSString *published=[json isKindOfClass:NSDictionary.class]&&[json[@"published_at"] isKindOfClass:NSString.class]?json[@"published_at"]:@"";
            NSString *latestVersion=nil,*latestBuild=nil;
            NSRegularExpression *versionPattern=[NSRegularExpression regularExpressionWithPattern:@"\\d+(\\.\\d+){1,2}" options:0 error:NULL];
            NSTextCheckingResult *versionMatch=[versionPattern firstMatchInString:name options:0 range:NSMakeRange(0,name.length)];
            if(versionMatch)latestVersion=[name substringWithRange:versionMatch.range];
            NSRegularExpression *buildPattern=[NSRegularExpression regularExpressionWithPattern:@"\\((\\d+)\\)" options:0 error:NULL];
            NSTextCheckingResult *buildMatch=[buildPattern firstMatchInString:name options:0 range:NSMakeRange(0,name.length)];
            if(buildMatch&&buildMatch.numberOfRanges>1)latestBuild=[name substringWithRange:[buildMatch rangeAtIndex:1]];
            NSString *installed=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"开发版";
            NSString *installedBuild=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?";
            if(error||!latestVersion){
                owner.lastUpdateCheckText=@"检查失败 · 点按重试";
                [owner.table reloadData];
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
                UIAlertController *found=[UIAlertController alertControllerWithTitle:@"发现新版本" message:[NSString stringWithFormat:@"最新版本 %@%@%@，当前版本 %@ (%@)。请前往 GitHub 发布页下载安装包。",latestVersion,buildInfo,dateInfo,installed,installedBuild] preferredStyle:UIAlertControllerStyleAlert];
                [found addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                if(htmlURL.length)[found addAction:[UIAlertAction actionWithTitle:@"去下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[UIApplication.sharedApplication openURL:[NSURL URLWithString:htmlURL] options:@{} completionHandler:nil];}]];
                [owner presentViewController:found animated:YES completion:nil];return;
            }
            if(compared==NSOrderedSame&&latestBuild&&latestBuild.integerValue>installedBuild.integerValue){
                owner.lastUpdateCheckText=[NSString stringWithFormat:@"发现新构建 %@%@",latestVersion,buildInfo];
                [owner.table reloadData];
                UIAlertController *found=[UIAlertController alertControllerWithTitle:@"发现新构建" message:[NSString stringWithFormat:@"同一版本 %@ 有新构建 %@%@，当前构建 %@。请前往 GitHub 发布页下载安装包。",latestVersion,buildInfo,dateInfo,installedBuild] preferredStyle:UIAlertControllerStyleAlert];
                [found addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                if(htmlURL.length)[found addAction:[UIAlertAction actionWithTitle:@"去下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[UIApplication.sharedApplication openURL:[NSURL URLWithString:htmlURL] options:@{} completionHandler:nil];}]];
                [owner presentViewController:found animated:YES completion:nil];return;
            }
            owner.lastUpdateCheckText=[NSString stringWithFormat:@"已是最新版本 %@%@",latestVersion,buildInfo];
            [owner.table reloadData];
            UIAlertController *uptodate=[UIAlertController alertControllerWithTitle:@"已是最新版本" message:[NSString stringWithFormat:@"当前版本 %@ (%@)，最新发布 %@%@%@。同一版本号内的新构建请以发布页为准。",installed,installedBuild,latestVersion,buildInfo,dateInfo] preferredStyle:UIAlertControllerStyleAlert];
            [uptodate addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [owner presentViewController:uptodate animated:YES completion:nil];
        });
    }] resume];
}

- (void)presentThemePicker:(NSIndexPath *)ip {
    HostThemePalette *current=[HostThemePalette currentPalette];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"主题色板" message:@"深色沉浸：午夜影院、曜石黑、深海蓝、鎏金棕；浅色：晨光白、雪原白。切换立即生效，无需重启。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(HostThemePalette *theme in HostThemePalette.allThemes){
        NSString *dot=theme.dark?@"● ":@"○ ";
        NSString *title=[theme.identifier isEqualToString:current.identifier]?[NSString stringWithFormat:@"%@%@ · %@ ✓",dot,theme.displayName,theme.tagline]:[NSString stringWithFormat:@"%@%@ · %@",dot,theme.displayName,theme.tagline];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            [HostThemePalette setCurrentPaletteIdentifier:theme.identifier];
            NSString *mode=theme.dark?@"dark":@"light";
            [NSUserDefaults.standardUserDefaults setObject:mode forKey:HostThemeModePreferenceKey];
            [NSUserDefaults.standardUserDefaults setBool:theme.dark forKey:HostDarkThemePreferenceKey];
            UIWindow *window=self.view.window;
            if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);});}
            [self reloadThemeAppearance];
            [self.table reloadData];
            if(self.onPreferenceChanged)self.onPreferenceChanged(HostThemePaletteIdentifierPreferenceKey,theme.dark);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"HostThemeDidChangeNotification" object:nil];
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"主题已切换为%@",theme.displayName]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}

- (void)confirmResetDefaultPreferences {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"恢复默认偏好设置？" message:@"将把主题、字号、频道布局、播放速度和超时等设置恢复为出厂默认值。收藏、观看历史、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
        NSArray<NSString *> *keysToReset=@[
            HostThemeModePreferenceKey, HostDarkThemePreferenceKey, HostThemePaletteIdentifierPreferenceKey,
            @"cctv.appFontSize.v1", @"cctv.restoreLastTab.v1",
            @"nativeChannelsEnabled", @"channelGridMode", @"cctv.channelGridColumns.v1", @"cctv.channelSortMode.v1",
            @"cctv.mediaKeepScreenAwake", @"allowBackgroundAudio", @"autoPiP", @"autoLoadEPG",
            @"rememberLastChannel", @"resumeLastChannel", @"cctv.mediaPreferredQuality.v1",
            @"cctv.mediaGridColumns.v1", @"cctv.mediaAutoPlayNext", @"cctv.mediaAutoSkipIntroOutro",
            @"cctv.mediaPlaybackRate", @"cctv.mediaVideoGravity", @"media.globalSearchHistoryEnabled.v1",
            @"fastNativeStartup", @"preloadNativeChannel", @"legacyNativePlayback",
            @"cctv.networkTimeout.v1", @"nativeSDKVerboseLogs", @"runtimeDiagnosticsEnabled"
        ];
        for(NSString *k in keysToReset)[d removeObjectForKey:k];
        UIWindow *window=self.view.window;
        if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);HostRefreshAppearanceLayers(window);}
        [self reloadThemeAppearance];
        [self.table reloadData];
        if(self.onPreferenceChanged)self.onPreferenceChanged(@"resetDefaultPreferences",YES);
        [NSNotificationCenter.defaultCenter postNotificationName:@"HostThemeDidChangeNotification" object:nil];
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaDisplayConfigurationDidChangeNotification" object:nil];
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
        [self.table reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
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
        self.clearedImagesState=YES;
        [MediaMetadataCache.shared clear];
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
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.mediaFavorites.v1"];
        [self.table reloadData];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"收藏已清除");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearProgramReminders {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除节目单预约提醒？" message:@"将清空所有已设置的频道节目单开播提醒记录。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除预约" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.epgReminders.v1"];
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
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"隐私说明" message:@"订阅、收藏、观看历史、搜索历史与各项设置都只保存在本机，不会上传到任何服务器。运行诊断默认关闭；开启后的记录也只保存在本机，可随时导出或清空，日志中的播放地址、查询参数、Cookie 与脚本内容会被脱敏。节目单与订阅内容按你配置的地址获取，播放由央视 SDK 或系统播放器完成。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)appearanceChanged:(UISegmentedControl *)sender {
    NSString *mode=sender.selectedSegmentIndex==0?@"system":(sender.selectedSegmentIndex==1?@"light":@"dark");
    BOOL dark=[mode isEqual:@"dark"];
    [NSUserDefaults.standardUserDefaults setObject:mode forKey:HostThemeModePreferenceKey];
    if(![mode isEqual:@"system"]){
        [NSUserDefaults.standardUserDefaults setBool:dark forKey:HostDarkThemePreferenceKey];
        HostThemePalette *palette=[HostThemePalette currentPalette];
        if(dark && !palette.dark){
            [HostThemePalette setCurrentPaletteIdentifier:HostThemePaletteDefaultIdentifier];
        } else if(!dark && palette.dark){
            [HostThemePalette setCurrentPaletteIdentifier:@"daylight"];
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
