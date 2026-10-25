#import "SettingsViewController.h"
#import "HostTheme.h"
#import "HostImageLoader.h"
#import "MediaMetadataCache.h"

static NSString *MediaMetadataCacheSummaryText(void) {
    NSDictionary *summary=MediaMetadataCache.shared.summary;
    NSString *size=[NSByteCountFormatter stringFromByteCount:[summary[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleMemory];
    return [NSString stringWithFormat:@"%lu 项 · %@",(unsigned long)[summary[@"entries"] unsignedIntegerValue],size];
}

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@end
@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"设置"; self.view.backgroundColor=HostBackground(); self.navigationController.navigationBar.tintColor=HostAccent();
    self.sections=@[
      @{ @"title":@"外观", @"footer":@"黑色和白色主题会应用到频道、影视、资源、服务、播放器与设置页面。", @"rows":@[
        @{ @"title":@"全局主题", @"detail":@"黑色 / 白色", @"key":HostDarkThemePreferenceKey, @"appearance":@YES, @"icon":@"circle.lefthalf.filled" }
      ]},
      @{ @"title":@"播放", @"footer":@"快速起播仅降低首帧前的缓冲门槛，出画面后恢复 SDK 原值；关闭可恢复默认缓冲。预解析只缓存一个相邻频道的信息，有效期 15 秒，会额外请求频道元数据。播放选项下次选台生效。", @"rows":@[
        @{ @"title":@"预解析下一个 CCTV 频道", @"key":@"preloadNativeChannel", @"icon":@"forward.end", @"default":@YES },
        @{ @"title":@"SDK 详细日志（诊断）", @"key":@"nativeSDKVerboseLogs", @"icon":@"doc.text", @"default":@NO },
        @{ @"title":@"原生播放器快速起播", @"key":@"fastNativeStartup", @"icon":@"bolt", @"default":@YES },
        @{ @"title":@"复用原生播放器", @"key":@"legacyNativePlayback", @"icon":@"backward.end", @"default":@YES },
        @{ @"title":@"启动时续播上次频道", @"key":@"resumeLastChannel", @"icon":@"arrow.counterclockwise", @"default":@YES },
        @{ @"title":@"记住上次观看频道", @"key":@"rememberLastChannel", @"icon":@"bookmark", @"default":@YES },
        @{ @"title":@"自动获取节目单", @"key":@"autoLoadEPG", @"icon":@"list.bullet.rectangle", @"default":@YES },
        @{ @"title":@"允许后台音频播放", @"key":@"allowBackgroundAudio", @"icon":@"speaker.wave.2", @"default":@YES },
        @{ @"title":@"订阅流自动画中画", @"key":@"autoPiP", @"icon":@"pip", @"default":@NO }
      ]},
      @{ @"title":@"服务", @"footer":@"内置 Python 插件仅在前台运行；高码率并发已限制以降低闪退风险。", @"rows":@[
        @{ @"title":@"央视直播", @"detail":@"官方 CNPlayerSDK · VDN 自动选线", @"icon":@"tv" },
        @{ @"title":@"M3U / HLS 订阅", @"detail":@"AVPlayer · iOS 系统解码", @"icon":@"play.rectangle" },
        @{ @"title":@"内置插件", @"detail":@"Python / JavaScriptCore · 本机运行", @"icon":@"curlybraces" }
      ]},
      @{ @"title":@"运行诊断", @"footer":@"开启后记录应用生命周期、服务启停、订阅刷新、媒体接口与播放状态，最多保留约 1 MB。日志默认脱敏，不记录播放地址、查询参数、Cookie 或脚本内容。关闭后停止新增诊断记录，已有记录仍可导出。", @"rows":@[
        @{ @"title":@"运行诊断模式", @"detail":@"问题复现前开启", @"key":@"runtimeDiagnosticsEnabled", @"icon":@"waveform.path.ecg", @"default":@NO },
        @{ @"title":@"导出运行诊断日志", @"detail":@"JSONL · 可分享给开发者定位问题", @"action":@"exportRuntimeDiagnostics", @"icon":@"square.and.arrow.up" }
      ]},
      @{ @"title":@"数据与关于", @"footer":@"影视元数据缓存只保存目录、分类和搜索结果；影片详情与播放线路不缓存。", @"rows":@[
        @{ @"title":@"导出本机配置", @"action":@"export", @"icon":@"square.and.arrow.up" },
        @{ @"title":@"导入配置文件", @"action":@"import", @"icon":@"square.and.arrow.down" },
        @{ @"title":@"清理节目单缓存", @"detail":@"下次打开频道时重新获取", @"icon":@"trash", @"action":@"clearEPG" },
        @{ @"title":@"清理台标缓存", @"detail":@"清理内存中的缩略图", @"icon":@"photo", @"action":@"clearImages" },
        @{ @"title":@"清理影视元数据缓存", @"detail":MediaMetadataCacheSummaryText(), @"icon":@"film", @"action":@"clearMediaMetadata" },
        @{ @"title":@"CCTVHost", @"detail":[NSString stringWithFormat:@"%@ · %@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"开发版",[[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"] isEqual:@"no-python"]?@"无 Python 诊断版":@"完整版"], @"icon":@"info.circle" },
        @{ @"title":@"日志中心", @"action":@"logs", @"detail":@"总日志与各插件独立日志", @"icon":@"doc.text.magnifyingglass" }
      ]}
    ];
    self.table=[[UITableView alloc]initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; self.table.translatesAutoresizingMaskIntoConstraints=NO; self.table.backgroundColor=HostBackground(); self.table.dataSource=self; self.table.delegate=self; self.table.rowHeight=UITableViewAutomaticDimension; self.table.estimatedRowHeight=68; self.table.tintColor=HostAccent(); [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[[self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return [self.sections[section][@"rows"] count];}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return self.sections[section][@"title"];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section{return self.sections[section][@"footer"];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting.row"]; if(!cell)cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"setting.row"];
    NSDictionary *row=self.sections[ip.section][@"rows"][ip.row]; cell.textLabel.text=row[@"title"]; cell.textLabel.textColor=HostText(); cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0; cell.detailTextLabel.text=row[@"detail"]; cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0; cell.imageView.image=[UIImage systemImageNamed:row[@"icon"]]; cell.imageView.tintColor=HostAccent(); cell.backgroundColor=HostCard(); cell.accessoryView=nil; cell.accessoryType=UITableViewCellAccessoryNone;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    NSString *key=row[@"key"];
    if([row[@"appearance"] boolValue]){UISegmentedControl *style=[[UISegmentedControl alloc] initWithItems:@[@"黑色",@"白色"]];style.selectedSegmentIndex=HostIsDarkThemeSelected()?0:1;style.selectedSegmentTintColor=HostAccent();[style setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];[style setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];style.accessibilityIdentifier=HostDarkThemePreferenceKey;[style addTarget:self action:@selector(appearanceChanged:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=style;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
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
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES]; NSDictionary *row=self.sections[ip.section][@"rows"][ip.row];
    if([row[@"action"] isEqualToString:@"clearEPG"]) [self confirmClearEPG];
    else if([row[@"action"] isEqualToString:@"clearImages"]){[HostImageLoader.shared clearCache];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"台标缓存已清理");UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];cell.detailTextLabel.text=@"已清理，下次加载时重新获取";}
    else if([row[@"action"] isEqualToString:@"clearMediaMetadata"]) [self confirmClearMediaMetadata:ip];
    else if([row[@"action"] isEqualToString:@"export"]){if(self.onExportData)self.onExportData();}
    else if([row[@"action"] isEqualToString:@"exportRuntimeDiagnostics"]){if(self.onExportDebugLog)self.onExportDebugLog();}
    else if([row[@"action"] isEqualToString:@"import"]){if(self.onImportData)self.onImportData();}
    else if([row[@"action"] isEqualToString:@"logs"]){if(self.onOpenLog)self.onOpenLog();}
}
- (void)confirmClearMediaMetadata:(NSIndexPath *)indexPath {
    NSDictionary *summary=[MediaMetadataCache.shared summary];NSString *size=[NSByteCountFormatter stringFromByteCount:[summary[@"bytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleMemory];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理影视元数据缓存？" message:[NSString stringWithFormat:@"将清理 %lu 项影视目录、分类和搜索缓存（%@）。影片详情与播放线路不写入此缓存；收藏、观看历史、订阅和插件数据会保留。",(unsigned long)[summary[@"entries"] unsignedIntegerValue],size] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[MediaMetadataCache.shared clear];UITableViewCell *cell=[self.table cellForRowAtIndexPath:indexPath];cell.detailTextLabel.text=@"0 项 · 0 字节";UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"影视元数据缓存已清理");}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)appearanceChanged:(UISegmentedControl *)sender {
    BOOL dark=sender.selectedSegmentIndex==0;[NSUserDefaults.standardUserDefaults setBool:dark forKey:HostDarkThemePreferenceKey];
    UIWindow *window=self.view.window;
    if(window){window.overrideUserInterfaceStyle=dark?UIUserInterfaceStyleDark:UIUserInterfaceStyleLight;HostStyleNavigation(self.navigationController);dispatch_async(dispatch_get_main_queue(),^{[window layoutIfNeeded];HostRefreshAppearanceLayers(window);});}
    if(self.onPreferenceChanged)self.onPreferenceChanged(HostDarkThemePreferenceKey,dark);
}
- (void)confirmClearEPG {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理节目单缓存" message:@"缓存将在下次访问频道时重新获取。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){ NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES); NSString *p=[[dirs firstObject] stringByAppendingPathComponent:@"epg-cache.json"]; NSError *error=nil; BOOL ok=![NSFileManager.defaultManager fileExistsAtPath:p]||[NSFileManager.defaultManager removeItemAtPath:p error:&error]; if(ok&&self.onClearEPG) self.onClearEPG(); UIAlertController *done=[UIAlertController alertControllerWithTitle:@"缓存" message:ok?@"节目单缓存已清理。":error.localizedDescription preferredStyle:UIAlertControllerStyleAlert]; [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:done animated:YES completion:nil]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
