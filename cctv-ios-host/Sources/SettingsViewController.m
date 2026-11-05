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
@end
@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"设置"; self.view.backgroundColor=HostBackground(); self.navigationController.navigationBar.tintColor=HostAccent();
    self.sections=@[
      @{ @"title":@"外观", @"footer":@"主题会应用到全部页面。可跟随 iPhone 外观，也可固定使用浅色或深色。频道网格列数只在网格显示时生效。", @"rows":@[
        @{ @"title":@"全局主题", @"detail":@"系统 / 浅色 / 深色", @"key":HostThemeModePreferenceKey, @"appearance":@YES, @"icon":@"circle.lefthalf.filled" },
        @{ @"title":@"频道用网格显示", @"key":@"channelGridMode", @"icon":@"square.grid.2x2", @"default":@YES },
        @{ @"title":@"频道网格列数", @"key":@"cctv.channelGridColumns.v1", @"segmented":@YES, @"options":@[@"3 列",@"4 列"], @"values":@[@3,@4], @"default":@4, @"icon":@"rectangle.grid.3x2" }
      ]},
      @{ @"title":@"媒体", @"footer":@"调整精选内容与海报布局；资源站和内部站点仍在媒体页顶部选择。", @"rows":@[
        @{ @"title":@"媒体显示", @"detail":@"精选模块与海报布局", @"action":@"mediaDisplay", @"icon":@"rectangle.grid.2x2" }
      ]},
      @{ @"title":@"启动", @"footer":@"打开时回到上次离开的页面；关闭后每次打开都从央视直播开始。", @"rows":@[
        @{ @"title":@"启动时恢复上次打开的页面", @"key":@"cctv.restoreLastTab.v1", @"icon":@"arrow.uturn.left", @"default":@YES }
      ]},
      @{ @"title":@"播放", @"footer":@"启动时自动续播默认关闭，打开软件后由你点选频道播放。快速起播仅降低首帧前的缓冲门槛，出画面后恢复 SDK 原值；预解析只缓存一个相邻频道的信息，有效期 15 秒，会额外请求频道元数据。播放选项下次选台生效。影视的默认速度、画面比例、自动连播与屏幕常亮下次播放生效，也可在播放器右上角菜单里临时调整。", @"rows":@[
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
        @{ @"title":@"播放时屏幕常亮", @"key":@"cctv.mediaKeepScreenAwake", @"icon":@"sun.max", @"default":@YES },
        @{ @"title":@"默认播放速度", @"detail":SettingsPlaybackRateText(), @"action":@"defaultPlaybackRate", @"icon":@"speedometer" },
        @{ @"title":@"默认画面比例", @"detail":SettingsVideoGravityText(), @"action":@"defaultVideoGravity", @"icon":@"aspectratio" }
      ]},
      @{ @"title":@"服务", @"footer":@"内置 Python 插件仅在前台运行；高码率并发已限制以降低闪退风险。", @"rows":@[
        @{ @"title":@"央视直播", @"detail":@"官方 CNPlayerSDK · VDN 自动选线", @"action":@"openTabLive", @"icon":@"tv" },
        @{ @"title":@"M3U / HLS 订阅", @"detail":@"AVPlayer · iOS 系统解码", @"action":@"openTabChannels", @"icon":@"play.rectangle" },
        @{ @"title":@"内置插件", @"detail":@"Python / JavaScriptCore · 本机运行", @"action":@"openServices", @"icon":@"curlybraces" }
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
    cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0; cell.imageView.image=[UIImage systemImageNamed:row[@"icon"]]; cell.imageView.tintColor=HostAccent(); cell.backgroundColor=HostCard(); cell.accessoryView=nil; cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    NSString *key=row[@"key"];
    if([row[@"appearance"] boolValue]){UISegmentedControl *style=[[UISegmentedControl alloc] initWithItems:@[@"系统",@"浅色",@"深色"]];[style setTitleTextAttributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];NSString *mode=HostThemeMode();style.selectedSegmentIndex=[mode isEqual:@"system"]?0:([mode isEqual:@"light"]?1:2);style.selectedSegmentTintColor=HostAccent();[style setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];[style setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];style.accessibilityIdentifier=HostThemeModePreferenceKey;[style addTarget:self action:@selector(appearanceChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=style;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else if([row[@"segmented"] boolValue]){NSArray *options=row[@"options"];UISegmentedControl *seg=[[UISegmentedControl alloc] initWithItems:options];[seg setTitleTextAttributes:@{NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]} forState:UIControlStateNormal];NSInteger saved=[[NSUserDefaults standardUserDefaults] objectForKey:key]?[[NSUserDefaults standardUserDefaults] integerForKey:key]:[row[@"default"] integerValue];NSInteger index=[row[@"values"] indexOfObject:@(saved)];seg.selectedSegmentIndex=index==NSNotFound?0:index;seg.selectedSegmentTintColor=HostAccent();[seg setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];[seg setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];seg.accessibilityIdentifier=key;[seg addTarget:self action:@selector(segmentedChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=seg;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else if(key){ UISwitch *sw=[UISwitch new]; sw.onTintColor=HostAccent(); id saved=[[NSUserDefaults standardUserDefaults] objectForKey:key]; sw.on=saved? [saved boolValue]:[row[@"default"] boolValue]; sw.accessibilityIdentifier=key; [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw; cell.selectionStyle=UITableViewCellSelectionStyleNone; }
    else if(row[@"action"]){ cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator; cell.selectionStyle=UITableViewCellSelectionStyleDefault; }
    else cell.selectionStyle=UITableViewCellSelectionStyleNone;
    return cell;
}
- (void)toggle:(UISwitch *)sender {
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
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清除搜索历史？" message:@"将清除本机保存的搜索关键词。影视浏览记录不受影响。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清除历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"搜索历史已清除");}]];
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
    if(window){window.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();HostStyleNavigation(self.navigationController);dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);});}
    if(self.onPreferenceChanged)self.onPreferenceChanged(HostThemeModePreferenceKey,HostIsDarkThemeSelected());
}
- (void)confirmClearEPG {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理节目单缓存" message:@"缓存将在下次访问频道时重新获取。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){ BOOL ok=SettingsRemoveEPGCacheFile(); if(ok&&self.onClearEPG) self.onClearEPG(); UIAlertController *done=[UIAlertController alertControllerWithTitle:@"缓存" message:ok?@"节目单缓存已清理。":@"节目单缓存清理失败，请重试。" preferredStyle:UIAlertControllerStyleAlert]; [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self dismissViewControllerAnimated:YES completion:^{[self presentViewController:done animated:YES completion:nil];}]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
