#import "SettingsViewController.h"
#import "HostTheme.h"
#import "HostImageLoader.h"
#import "MediaMetadataCache.h"
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

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic) CGFloat bottomOverlayInset;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@property(nonatomic,copy,nullable) NSString *lastUpdateCheckText;
@property(nonatomic,assign) BOOL checkingUpdate;
@end
@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"设置"; self.view.backgroundColor=HostBackground(); self.navigationController.navigationBar.tintColor=HostAccent();
    self.sections=@[
      @{ @"title":@"外观", @"footer":@"主题会应用到全部页面。可跟随 iPhone 外观，也可固定使用浅色或深色；下方色板提供 6 套主题（4 套深色沉浸、2 套浅色），点选立即生效，无需重启。频道网格列数只在网格显示时生效。字号对五个主页面与后续打开的页面生效。", @"rows":@[
        @{ @"title":@"全局主题", @"detail":@"系统 / 浅色 / 深色", @"key":HostThemeModePreferenceKey, @"appearance":@YES, @"icon":@"circle.lefthalf.filled" },
        @{ @"title":@"主题色板", @"detail":@"午夜影院", @"action":@"themePalette", @"icon":@"paintpalette" },
        @{ @"title":@"字号", @"key":@"cctv.appFontSize.v1", @"segmented":@YES, @"options":@[@"标准",@"大",@"特大"], @"values":@[@0,@1,@2], @"default":@0, @"icon":@"textformat.size" },
        @{ @"title":@"频道用网格显示", @"key":@"channelGridMode", @"icon":@"square.grid.2x2", @"default":@YES },
        @{ @"title":@"频道网格列数", @"key":@"cctv.channelGridColumns.v1", @"segmented":@YES, @"options":@[@"3 列",@"4 列"], @"values":@[@3,@4], @"default":@4, @"icon":@"rectangle.grid.3x2" }
      ]},
      @{ @"title":@"媒体", @"footer":@"调整精选内容与海报布局；资源站和内部站点仍在媒体页顶部选择。", @"rows":@[
        @{ @"title":@"媒体显示", @"detail":@"精选模块与海报布局", @"action":@"mediaDisplay", @"icon":@"rectangle.grid.2x2" }
      ]},
      @{ @"title":@"启动", @"footer":@"打开时回到上次离开的页面；关闭后每次打开都从央视直播开始。", @"rows":@[
        @{ @"title":@"启动时恢复上次打开的页面", @"key":@"cctv.restoreLastTab.v1", @"icon":@"arrow.uturn.left", @"default":@YES }
      ]},
      @{ @"title":@"播放", @"footer":@"启动时自动续播默认关闭，打开软件后由你点选频道播放。快速起播仅降低首帧前的缓冲门槛，出画面后恢复 SDK 原值；预解析只缓存一个相邻频道的信息，有效期 15 秒，会额外请求频道元数据。播放选项下次选台生效。影视的默认速度、画面比例、自动连播与屏幕常亮下次播放生效，也可在播放器右上角菜单里临时调整。默认清晰度对多码率 HLS 流生效（影视页与直播 AVPlayer 回退路径），央视直播走 SDK 时由 VDN 自动选线。自动跳过仅对已记住片头片尾位置的影片生效，位置在播放器菜单里设置。", @"rows":@[
        @{ @"title":@"预解析下一个 CCTV 频道", @"key":@"preloadNativeChannel", @"icon":@"forward.end", @"default":@YES },
        @{ @"title":@"SDK 详细日志（诊断）", @"key":@"nativeSDKVerboseLogs", @"icon":@"doc.text", @"default":@NO },
        @{ @"title":@"原生播放器快速起播", @"key":@"fastNativeStartup", @"icon":@"bolt", @"default":@YES },
        @{ @"title":@"复用原生播放器", @"key":@"legacyNativePlayback", @"icon":@"backward.end", @"default":@YES },
        @{ @"title":@"启动时自动续播上次频道", @"key":@"resumeLastChannel", @"icon":@"arrow.counterclockwise", @"default":@NO },
        @{ @"title":@"记住上次观看频道", @"key":@"rememberLastChannel", @"icon":@"bookmark", @"default":@YES },
        @{ @"title":@"自动获取节目单", @"key":@"autoLoadEPG", @"icon":@"list.bullet.rectangle", @"default":@YES },
        @{ @"title":@"允许后台音频播放", @"key":@"allowBackgroundAudio", @"icon":@"speaker.wave.2", @"default":@YES },
        @{ @"title":@"订阅流自动画中画", @"key":@"autoPiP", @"icon":@"pip", @"default":@NO },
        @{ @"title":@"自动连播下一集", @"key":@"cctv.mediaAutoPlayNext", @"icon":@"forward.end.fill", @"default":@YES },
        @{ @"title":@"自动跳过片头片尾", @"key":@"cctv.mediaAutoSkipIntroOutro", @"icon":@"forward.end.circle", @"default":@NO },
        @{ @"title":@"播放时屏幕常亮", @"key":@"cctv.mediaKeepScreenAwake", @"icon":@"sun.max", @"default":@YES },
        @{ @"title":@"默认播放速度", @"detail":SettingsPlaybackRateText(), @"action":@"defaultPlaybackRate", @"icon":@"speedometer" },
        @{ @"title":@"默认画面比例", @"detail":SettingsVideoGravityText(), @"action":@"defaultVideoGravity", @"icon":@"aspectratio" },
        @{ @"title":@"默认清晰度", @"detail":SettingsPreferredQualityText(), @"action":@"defaultQuality", @"icon":@"4k.tv" }
      ]},
      @{ @"title":@"服务", @"footer":@"内置 Python 插件仅在前台运行；高码率并发已限制以降低闪退风险。网络请求超时控制影视数据请求的等待时间，偏短在弱网时更容易失败，偏长等待更久。", @"rows":@[
        @{ @"title":@"央视直播", @"detail":@"官方 CNPlayerSDK · VDN 自动选线", @"action":@"openTabLive", @"icon":@"tv" },
        @{ @"title":@"M3U / HLS 订阅", @"detail":@"AVPlayer · iOS 系统解码", @"action":@"openTabChannels", @"icon":@"play.rectangle" },
        @{ @"title":@"内置插件", @"detail":@"Python / JavaScriptCore · 本机运行", @"action":@"openServices", @"icon":@"curlybraces" },
        @{ @"title":@"网络请求超时", @"key":@"cctv.networkTimeout.v1", @"segmented":@YES, @"options":@[@"10 秒",@"20 秒",@"40 秒"], @"values":@[@10,@20,@40], @"default":@20, @"icon":@"network" }
      ]},
      @{ @"title":@"运行诊断", @"footer":@"开启后记录应用启动、影视加载与播放阶段、海报失败、服务启停和系统内存警告。每次 App 运行单独存档，单次最多 4 MiB；最多保留 24 次或 32 MiB，较旧记录会自动清理。重启后会标出上次未正常收尾及最后记录的状态；这不能单独证明崩溃原因，也不能替代 iOS .ips / JetsamEvent 报告。日志默认脱敏，不记录完整播放地址、查询参数值、Cookie 或脚本内容。", @"rows":@[
        @{ @"title":@"运行诊断模式", @"detail":@"先开启再复现；若闪退，重开 App 后导出", @"key":@"runtimeDiagnosticsEnabled", @"icon":@"waveform.path.ecg", @"default":@NO },
        @{ @"title":@"运行诊断记录", @"detail":@"按 App 运行分开查看 · 可单次导出、删除或清空", @"action":@"runtimeDiagnostics", @"icon":@"list.bullet.rectangle" }
      ]},
      @{ @"title":@"数据与关于", @"footer":@"影视元数据缓存只保存目录、分类和搜索结果；影片详情与播放线路不缓存。", @"rows":@[
        @{ @"title":@"保存搜索历史", @"key":@"media.globalSearchHistoryEnabled.v1", @"icon":@"magnifyingglass", @"default":@NO },
        @{ @"title":@"导出本机配置", @"action":@"export", @"icon":@"square.and.arrow.up" },
        @{ @"title":@"导入配置文件", @"action":@"import", @"icon":@"square.and.arrow.down" },
        @{ @"title":@"清理全部缓存", @"detail":@"节目单、台标与影视元数据缓存", @"icon":@"trash.fill", @"action":@"clearAllCaches" },
        @{ @"title":@"清理节目单缓存", @"detail":SettingsEPGCacheSizeText(), @"icon":@"trash", @"action":@"clearEPG" },
        @{ @"title":@"清理台标缓存", @"detail":@"清理内存中的缩略图", @"icon":@"photo", @"action":@"clearImages" },
        @{ @"title":@"清理影视元数据缓存", @"detail":MediaMetadataCacheSummaryText(), @"icon":@"film", @"action":@"clearMediaMetadata" },
        @{ @"title":@"清除观看历史", @"detail":@"本机最近观看的频道", @"icon":@"clock.arrow.circlepath", @"action":@"clearWatchHistory" },
        @{ @"title":@"清除收藏", @"detail":@"全部频道收藏", @"icon":@"heart.slash", @"action":@"clearFavorites" },
        @{ @"title":@"清除搜索历史", @"detail":@"本机保存的搜索关键词", @"icon":@"magnifyingglass.circle", @"action":@"clearSearchHistory" },
        @{ @"title":@"隐私说明", @"detail":@"数据如何保存与使用", @"action":@"privacy", @"icon":@"hand.raised" },
        @{ @"title":@"CCTVHost", @"detail":[NSString stringWithFormat:@"%@ (%@) · %@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"开发版",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"?",[[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"] isEqual:@"no-python"]?@"无 Python 诊断版":@"完整版"], @"icon":@"info.circle" },
        @{ @"title":@"检查更新", @"detail":@"点按检查最新发布", @"action":@"checkUpdate", @"icon":@"arrow.down.circle" },
        @{ @"title":@"日志中心", @"action":@"logs", @"detail":@"总日志与各插件独立日志", @"icon":@"doc.text.magnifyingglass" }
      ]}
    ];
    self.table=[[UITableView alloc]initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; self.table.translatesAutoresizingMaskIntoConstraints=NO; self.table.backgroundColor=HostBackground(); self.table.dataSource=self; self.table.delegate=self; self.table.rowHeight=UITableViewAutomaticDimension; self.table.estimatedRowHeight=68; self.table.tintColor=HostAccent();self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever; [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[[self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
    [self updateImmersiveTableInsets];
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updateImmersiveTableInsets];}
- (void)viewSafeAreaInsetsDidChange {[super viewSafeAreaInsetsDidChange];[self updateImmersiveTableInsets];}
- (void)updateImmersiveTableInsets {
    if(!self.isViewLoaded||!self.table)return;
    CGFloat top=MAX(0,self.view.safeAreaInsets.top),bottom=MAX(8,self.bottomOverlayInset);UIEdgeInsets old=self.table.contentInset,next=UIEdgeInsetsMake(top,0,bottom,0);
    if(fabs(old.top-top)<0.5&&fabs(old.bottom-bottom)<0.5)return;
    BOOL wasAtTop=self.table.contentOffset.y<=-old.top+1;self.table.contentInset=next;self.table.scrollIndicatorInsets=next;
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
    // 分段控件标题字号取自 preferredFont：大字体档位变化时旧字号不会自动跟随，重载一次让 cellForRow 用当前档位重算字号与行高。
    if(previousTraitCollection&&![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory])[self.table reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return [self.sections[section][@"rows"] count];}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return self.sections[section][@"title"];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section{return self.sections[section][@"footer"];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting.row"]; if(!cell)cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting.row"];
    NSDictionary *row=self.sections[ip.section][@"rows"][ip.row]; cell.textLabel.text=row[@"title"]; cell.textLabel.textColor=HostText(); cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0; cell.detailTextLabel.text=row[@"detail"];
    // 元数据缓存量与节目单缓存量是动态值：每次渲染时重算，否则清理后重载仍显示清理前的旧数字。
    if([row[@"action"] isEqualToString:@"clearMediaMetadata"])cell.detailTextLabel.text=MediaMetadataCacheSummaryText();
    if([row[@"action"] isEqualToString:@"clearEPG"])cell.detailTextLabel.text=SettingsEPGCacheSizeText();
    if([row[@"action"] isEqualToString:@"defaultPlaybackRate"])cell.detailTextLabel.text=SettingsPlaybackRateText();
    if([row[@"action"] isEqualToString:@"defaultVideoGravity"])cell.detailTextLabel.text=SettingsVideoGravityText();
    if([row[@"action"] isEqualToString:@"defaultQuality"])cell.detailTextLabel.text=SettingsPreferredQualityText();
    if([row[@"action"] isEqualToString:@"themePalette"])cell.detailTextLabel.text=[HostThemePalette currentPalette].displayName;
    if([row[@"action"] isEqualToString:@"checkUpdate"])cell.detailTextLabel.text=self.lastUpdateCheckText?:@"点按检查最新发布";
    cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0; cell.imageView.image=[UIImage systemImageNamed:row[@"icon"]]; cell.imageView.tintColor=HostAccent(); cell.backgroundColor=HostCard(); cell.accessoryView=nil; cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    NSString *key=row[@"key"];
    if([row[@"appearance"] boolValue]){UISegmentedControl *style=[[UISegmentedControl alloc] initWithItems:@[@"系统",@"浅色",@"深色"]];[style setTitleTextAttributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];NSString *mode=HostThemeMode();style.selectedSegmentIndex=[mode isEqual:@"system"]?0:([mode isEqual:@"light"]?1:2);style.selectedSegmentTintColor=HostAccent();[style setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];[style setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];style.accessibilityIdentifier=HostThemeModePreferenceKey;style.accessibilityLabel=row[@"title"];[style addTarget:self action:@selector(appearanceChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=style;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else if([row[@"segmented"] boolValue]){NSArray *options=row[@"options"];UISegmentedControl *seg=[[UISegmentedControl alloc] initWithItems:options];[seg setTitleTextAttributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];NSInteger saved=[[NSUserDefaults standardUserDefaults] objectForKey:key]?[[NSUserDefaults standardUserDefaults] integerForKey:key]:[row[@"default"] integerValue];NSInteger index=[row[@"values"] indexOfObject:@(saved)];seg.selectedSegmentIndex=index==NSNotFound?0:index;seg.selectedSegmentTintColor=HostAccent();[seg setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];[seg setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];seg.accessibilityIdentifier=key;seg.accessibilityLabel=row[@"title"];[seg addTarget:self action:@selector(segmentedChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=seg;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else if(key){ UISwitch *sw=[UISwitch new]; sw.onTintColor=HostAccent(); id saved=[[NSUserDefaults standardUserDefaults] objectForKey:key]; sw.on=saved? [saved boolValue]:[row[@"default"] boolValue]; sw.accessibilityIdentifier=key;sw.accessibilityLabel=row[@"title"]; [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw; cell.selectionStyle=UITableViewCellSelectionStyleNone; }
    else if(row[@"action"]){ cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle=UITableViewCellSelectionStyleDefault; }
    else cell.selectionStyle=UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)toggle:(UISwitch *)sender {
    if(!sender.accessibilityIdentifier.length)return;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults setBool:sender.on forKey:sender.accessibilityIdentifier];
    if ([sender.accessibilityIdentifier isEqualToString:@"rememberLastChannel"] && !sender.on) [defaults removeObjectForKey:@"lastChannel"];
    if(self.onPreferenceChanged) self.onPreferenceChanged(sender.accessibilityIdentifier,sender.on);
}
- (void)segmentedChanged:(UISegmentedControl *)sender {
    NSArray *values=nil;for(NSDictionary *section in self.sections)for(NSDictionary *row in section[@"rows"])if([row[@"key"] isEqualToString:sender.accessibilityIdentifier]&&[row[@"segmented"] boolValue])values=row[@"values"];
    if(!values||sender.selectedSegmentIndex<0||sender.selectedSegmentIndex>=(NSInteger)values.count)return;
    NSInteger value=[values[sender.selectedSegmentIndex] integerValue];
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:sender.accessibilityIdentifier];
    if(self.onIntegerPreferenceChanged) self.onIntegerPreferenceChanged(sender.accessibilityIdentifier,value);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES]; NSDictionary *row=self.sections[ip.section][@"rows"][ip.row];
    if([row[@"action"] isEqualToString:@"clearEPG"]) [self confirmClearEPG];
    else if([row[@"action"] isEqualToString:@"clearImages"]){[HostImageLoader.shared clearCache];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"台标缓存已清理");UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];cell.detailTextLabel.text=@"已清理，下次加载时重新获取";}
    else if([row[@"action"] isEqualToString:@"clearMediaMetadata"]) [self confirmClearMediaMetadata:ip];
    else if([row[@"action"] isEqualToString:@"clearAllCaches"]) [self confirmClearAllCaches];
    else if([row[@"action"] isEqualToString:@"clearWatchHistory"]) [self confirmClearWatchHistory];
    else if([row[@"action"] isEqualToString:@"clearFavorites"]) [self confirmClearFavorites];
    else if([row[@"action"] isEqualToString:@"clearSearchHistory"]) [self confirmClearSearchHistory];
    else if([row[@"action"] isEqualToString:@"privacy"]) [self showPrivacyStatement];
    else if([row[@"action"] isEqualToString:@"defaultPlaybackRate"]) [self presentPlaybackRatePicker:ip];
    else if([row[@"action"] isEqualToString:@"defaultVideoGravity"]) [self presentVideoGravityPicker:ip];
    else if([row[@"action"] isEqualToString:@"defaultQuality"]) [self presentPreferredQualityPicker:ip];
    else if([row[@"action"] isEqualToString:@"themePalette"]) [self presentThemePicker:ip];
    else if([row[@"action"] isEqualToString:@"checkUpdate"]) [self checkForUpdateFromIndexPath:ip];
    else if([row[@"action"] isEqualToString:@"openTabLive"]){if(self.onOpenTab)self.onOpenTab(0);}
    else if([row[@"action"] isEqualToString:@"openTabChannels"]){if(self.onOpenTab)self.onOpenTab(1);}
    else if([row[@"action"] isEqualToString:@"openServices"]){if(self.onOpenServices)self.onOpenServices();}
    else if([row[@"action"] isEqualToString:@"export"]){if(self.onExportData)self.onExportData();}
    else if([row[@"action"] isEqualToString:@"runtimeDiagnostics"]){if(self.onOpenDiagnostics)self.onOpenDiagnostics();}
    else if([row[@"action"] isEqualToString:@"mediaDisplay"]){if(self.onMediaDisplaySettings)self.onMediaDisplaySettings();}
    else if([row[@"action"] isEqualToString:@"import"]){if(self.onImportData)self.onImportData();}
    else if([row[@"action"] isEqualToString:@"logs"]){if(self.onOpenLog)self.onOpenLog();}
}
- (void)presentActionSheet:(UIAlertController *)sheet fromIndexPath:(NSIndexPath *)ip {
    // 快速连点同一行会重复 present，系统只会警告并丢掉后一个；直接拦截。
    if(self.presentedViewController)return;
    // iPad 上 action sheet 必须指定弹出位置，否则会崩溃；行滑出可视区时 cell 为 nil，用 self.view 兜底。
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
        [sheet addAction:[UIAlertAction actionWithTitle:fabs(current-rate)<0.01?[title stringByAppendingString:@" ✓"]:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[NSUserDefaults.standardUserDefaults setDouble:rate forKey:@"cctv.mediaPlaybackRate"];[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认播放速度已设为%@",title]);}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}
- (void)presentVideoGravityPicker:(NSIndexPath *)ip {
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaVideoGravity"]?:AVLayerVideoGravityResizeAspect;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"默认画面比例" message:@"下次播放影视时生效，也可在播放器右上角菜单里临时调整。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *option in @[@{@"title":@"画面适应",@"value":AVLayerVideoGravityResizeAspect},@{@"title":@"铺满裁切",@"value":AVLayerVideoGravityResizeAspectFill},@{@"title":@"拉伸填满",@"value":AVLayerVideoGravityResize}]){
        NSString *title=option[@"title"],*value=option[@"value"];
        [sheet addAction:[UIAlertAction actionWithTitle:[current isEqual:value]?[title stringByAppendingString:@" ✓"]:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaVideoGravity"];[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认画面比例已设为%@",title]);}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}
- (void)presentPreferredQualityPicker:(NSIndexPath *)ip {
    // 清晰度对多码率 HLS 流有效：影视页与直播 AVPlayer 回退路径按偏好约束码率；央视直播走 SDK 时由 VDN 自动选线，宿主没有可调的清晰度接口；单文件 MP4 只有一个码率。
    NSString *current=[[NSUserDefaults standardUserDefaults] stringForKey:@"cctv.mediaPreferredQuality.v1"]?:@"auto";
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"默认清晰度" message:@"对多码率 HLS 流生效（影视页与直播 AVPlayer 回退）；央视直播走 SDK 时由 VDN 自动选线；单文件 MP4 无多码率可选。下次播放生效。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSDictionary *option in @[@{@"title":@"自动",@"value":@"auto"},@{@"title":@"流畅",@"value":@"smooth"},@{@"title":@"高清",@"value":@"hd"},@{@"title":@"超清",@"value":@"uhd"}]){
        NSString *title=option[@"title"],*value=option[@"value"];
        [sheet addAction:[UIAlertAction actionWithTitle:[current isEqual:value]?[title stringByAppendingString:@" ✓"]:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[NSUserDefaults.standardUserDefaults setObject:value forKey:@"cctv.mediaPreferredQuality.v1"];[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"默认清晰度已设为%@",title]);}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}
- (void)checkForUpdateFromIndexPath:(NSIndexPath *)ip {
    // 连点会发重复请求并弹出重复提示；检查中直接返回。
    if(self.checkingUpdate)return;self.checkingUpdate=YES;
    // 手动检查 GitHub 最新发布：版本号用数字比较；同一版本号内的新构建无法仅凭版本号识别，提示里会同时给出最新构建号，由用户对照发布页判断。
    self.lastUpdateCheckText=@"正在检查…";[self.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    NSURL *url=[NSURL URLWithString:@"https://api.github.com/repos/joeshu/yqk-forward-widget/releases/latest"];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    [request setValue:@"CCTVHost" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf=self;
    NSURLSession *updateSession=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[updateSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        [updateSession finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(),^{SettingsViewController *owner=weakSelf;if(!owner)return;owner.checkingUpdate=NO;
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
                [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
                UIAlertController *failed=[UIAlertController alertControllerWithTitle:@"检查更新失败" message:@"无法获取最新发布信息，请检查网络后重试。" preferredStyle:UIAlertControllerStyleAlert];
                [failed addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [owner presentViewController:failed animated:YES completion:nil];return;
            }
            NSComparisonResult compared=[latestVersion compare:installed options:NSNumericSearch];
            NSString *buildInfo=latestBuild?[NSString stringWithFormat:@"（构建 %@）",latestBuild]:@"";
            NSString *dateInfo=published.length>10?[NSString stringWithFormat:@"，发布于 %@",[published substringToIndex:10]]:@"";
            if(compared==NSOrderedDescending){
                owner.lastUpdateCheckText=[NSString stringWithFormat:@"发现新版本 %@%@",latestVersion,buildInfo];
                [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
                UIAlertController *found=[UIAlertController alertControllerWithTitle:@"发现新版本" message:[NSString stringWithFormat:@"最新版本 %@%@%@，当前版本 %@ (%@)。请前往 GitHub 发布页下载安装包。",latestVersion,buildInfo,dateInfo,installed,installedBuild] preferredStyle:UIAlertControllerStyleAlert];
                [found addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                if(htmlURL.length)[found addAction:[UIAlertAction actionWithTitle:@"去下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[UIApplication.sharedApplication openURL:[NSURL URLWithString:htmlURL] options:@{} completionHandler:nil];}]];
                [owner presentViewController:found animated:YES completion:nil];return;
            }
            // 同版本号但构建号更新：标题不能再说“已是最新版本”，否则
            // 用户会错过同一版本内的修复构建（installedBuild 取不到时
            // 视作 0，任何新构建都会提示）。
            if(compared==NSOrderedSame&&latestBuild&&latestBuild.integerValue>installedBuild.integerValue){
                owner.lastUpdateCheckText=[NSString stringWithFormat:@"发现新构建 %@%@",latestVersion,buildInfo];
                [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
                UIAlertController *found=[UIAlertController alertControllerWithTitle:@"发现新构建" message:[NSString stringWithFormat:@"同一版本 %@ 有新构建 %@%@，当前构建 %@。请前往 GitHub 发布页下载安装包。",latestVersion,buildInfo,dateInfo,installedBuild] preferredStyle:UIAlertControllerStyleAlert];
                [found addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
                if(htmlURL.length)[found addAction:[UIAlertAction actionWithTitle:@"去下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[UIApplication.sharedApplication openURL:[NSURL URLWithString:htmlURL] options:@{} completionHandler:nil];}]];
                [owner presentViewController:found animated:YES completion:nil];return;
            }
            owner.lastUpdateCheckText=[NSString stringWithFormat:@"已是最新版本 %@%@",latestVersion,buildInfo];
            [owner.table reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
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
        NSString *title=[theme.identifier isEqualToString:current.identifier]?[theme.displayName stringByAppendingString:@" ✓"]:[NSString stringWithFormat:@"%@ · %@",theme.displayName,theme.tagline];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            [HostThemePalette setCurrentPaletteIdentifier:theme.identifier];
            // 主题自带深浅：选深色主题切深色模式，选浅色主题切浅色模式，保证点选立即生效；“跟随系统”仍可通过上方的全局主题切回。
            NSString *mode=theme.dark?@"dark":@"light";
            [NSUserDefaults.standardUserDefaults setObject:mode forKey:HostThemeModePreferenceKey];
            [NSUserDefaults.standardUserDefaults setBool:theme.dark forKey:HostDarkThemePreferenceKey];
            UIWindow *window=self.view.window;
            if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);});}
            // window 为 nil 时主题仍已写入偏好：照样刷新本行，否则色板副标题会一直显示旧主题。
            [self.table reloadData];
            if(self.onPreferenceChanged)self.onPreferenceChanged(HostThemePaletteIdentifierPreferenceKey,theme.dark);
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,[NSString stringWithFormat:@"主题已切换为%@",theme.displayName]);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentActionSheet:sheet fromIndexPath:ip];
}
- (void)confirmClearMediaMetadata:(NSIndexPath *)indexPath {
    NSDictionary *summary=[MediaMetadataCache.shared summary];NSString *size=[NSByteCountFormatter stringFromByteCount:[summary[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleMemory];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理影视元数据缓存？" message:[NSString stringWithFormat:@"将清理 %lu 项影视目录、分类和搜索缓存（%@）。影片详情与播放线路不写入此缓存；收藏、观看历史、订阅和插件数据会保留。",(unsigned long)[summary[@"entries"] unsignedIntegerValue],size] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[MediaMetadataCache.shared clear];[self.table reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"影视元数据缓存已清理");}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmClearAllCaches {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理全部缓存？" message:@"将清理节目单缓存、台标缓存与影视元数据缓存。收藏、观看历史、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){SettingsRemoveEPGCacheFile();if(self.onClearEPG)self.onClearEPG();[HostImageLoader.shared clearCache];[MediaMetadataCache.shared clear];[self.table reloadData];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"全部缓存已清理");}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmClearWatchHistory {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除观看历史？" message:@"将清除本机最近观看的频道记录。收藏、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onClearWatchHistory)self.onClearWatchHistory();UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"观看历史已清除");}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmClearFavorites {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除收藏？" message:@"将清除全部频道收藏。观看历史、订阅和插件数据会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除收藏" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onClearFavorites)self.onClearFavorites();UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"收藏已清除");}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmClearSearchHistory {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除搜索历史？" message:@"将清除本机保存的搜索关键词，以及影视浏览状态里保存的关键词。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];
        // 浏览状态里也存了搜索关键词：只清历史键的话，下次回到影视来源还会把旧关键词恢复出来。
        id rawBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];
        NSMutableDictionary *browse=[rawBrowse isKindOfClass:NSDictionary.class]?[rawBrowse mutableCopy]:[NSMutableDictionary dictionary];
        for(NSString *key in browse.allKeys){NSMutableDictionary *state=[browse[key] mutableCopy];if([state isKindOfClass:NSDictionary.class]){state[@"keyword"]=@"";browse[key]=state;}}
        [NSUserDefaults.standardUserDefaults setObject:browse forKey:@"media.browseStates.v1"];
        BOOL enabled=[[NSUserDefaults standardUserDefaults] boolForKey:@"media.globalSearchHistoryEnabled.v1"];
        [NSNotificationCenter.defaultCenter postNotificationName:@"MediaGlobalSearchHistoryDidChange" object:nil userInfo:@{@"enabled":@(enabled),@"cleared":@YES}];
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
    if(![mode isEqual:@"system"])[NSUserDefaults.standardUserDefaults setBool:dark forKey:HostDarkThemePreferenceKey];
    UIWindow *window=self.view.window;
    if(window){HostApplyThemeToWindow(window);HostStyleNavigation(self.navigationController);dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);[self.table reloadData];});}
    if(self.onPreferenceChanged)self.onPreferenceChanged(HostThemeModePreferenceKey,HostIsDarkThemeSelected());
}
// 按 action 在 sections 里找行位置（清理类行清理后要重刷本行 detail）。
- (NSIndexPath *)indexPathForRowAction:(NSString *)action {
    for(NSInteger s=0;s<self.sections.count;s++){NSArray *rows=self.sections[s][@"rows"];for(NSInteger r=0;r<rows.count;r++)if([rows[r][@"action"] isEqualToString:action])return [NSIndexPath indexPathForRow:r inSection:s];}
    return nil;
}
- (void)confirmClearEPG {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理节目单缓存" message:@"缓存将在下次访问频道时重新获取。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){ BOOL ok=SettingsRemoveEPGCacheFile(); if(ok&&self.onClearEPG) self.onClearEPG(); if(ok){NSIndexPath *epgRow=[self indexPathForRowAction:@"clearEPG"];if(epgRow)[self.table reloadRowsAtIndexPaths:@[epgRow] withRowAnimation:UITableViewRowAnimationNone];} UIAlertController *done=[UIAlertController alertControllerWithTitle:@"缓存" message:ok?@"节目单缓存已清理。":@"节目单缓存清理失败，请重试。" preferredStyle:UIAlertControllerStyleAlert]; [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self dismissViewControllerAnimated:YES completion:^{[self presentViewController:done animated:YES completion:nil];}]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
