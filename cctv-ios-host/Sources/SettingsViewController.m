#import "SettingsViewController.h"
#import "HostTheme.h"

@interface SettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@end
@implementation SettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title=@"设置"; self.view.backgroundColor=UIColor.blackColor; self.navigationController.navigationBar.tintColor=UIColor.systemPinkColor;
    self.sections=@[
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
        @{ @"title":@"内置插件", @"detail":@"CPython 3.13 · 本机服务", @"icon":@"curlybraces" }
      ]},
      @{ @"title":@"数据与关于", @"footer":@"iOS 可能在应用退到后台时挂起本地插件服务。", @"rows":@[
        @{ @"title":@"导出本机配置", @"action":@"export", @"icon":@"square.and.arrow.up" },
        @{ @"title":@"导入配置文件", @"action":@"import", @"icon":@"square.and.arrow.down" },
        @{ @"title":@"清理节目单缓存", @"detail":@"下次打开频道时重新获取", @"icon":@"trash", @"action":@"clearEPG" },
        @{ @"title":@"CCTVHost", @"detail":[NSString stringWithFormat:@"0.17.0 · %@",[[NSBundle.mainBundle objectForInfoDictionaryKey:@"CCTVHostBuildVariant"] isEqual:@"no-python"]?@"无 Python 诊断版":@"完整版"], @"icon":@"info.circle" },
        @{ @"title":@"日志", @"action":@"logs", @"detail":@"播放器与插件运行日志可导出", @"icon":@"doc.text.magnifyingglass" }
      ]}
    ];
    self.table=[[UITableView alloc]initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped]; self.table.translatesAutoresizingMaskIntoConstraints=NO; self.table.backgroundColor=UIColor.blackColor; self.table.dataSource=self; self.table.delegate=self; self.table.rowHeight=58; self.table.tintColor=UIColor.systemPinkColor; [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[[self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return [self.sections[section][@"rows"] count];}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return self.sections[section][@"title"];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section{return self.sections[section][@"footer"];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"setting.row"]; if(!cell)cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"setting.row"];
    NSDictionary *row=self.sections[ip.section][@"rows"][ip.row]; cell.textLabel.text=row[@"title"]; cell.textLabel.textColor=UIColor.whiteColor; cell.textLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]; cell.detailTextLabel.text=row[@"detail"]; cell.detailTextLabel.textColor=UIColor.secondaryLabelColor; cell.imageView.image=[UIImage systemImageNamed:row[@"icon"]]; cell.imageView.tintColor=UIColor.systemPinkColor; cell.backgroundColor=[UIColor colorWithWhite:0.12 alpha:1]; cell.accessoryView=nil; cell.accessoryType=UITableViewCellAccessoryNone;
    NSString *key=row[@"key"];
    if(key){ UISwitch *sw=[UISwitch new]; sw.onTintColor=UIColor.systemPinkColor; id saved=[[NSUserDefaults standardUserDefaults] objectForKey:key]; sw.on=saved? [saved boolValue]:[row[@"default"] boolValue]; sw.accessibilityIdentifier=key; [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView=sw; cell.selectionStyle=UITableViewCellSelectionStyleNone; }
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
    else if([row[@"action"] isEqualToString:@"export"]){if(self.onExportData)self.onExportData();}
    else if([row[@"action"] isEqualToString:@"import"]){if(self.onImportData)self.onImportData();}
    else if([row[@"action"] isEqualToString:@"logs"]){if(self.onOpenLog)self.onOpenLog();}
    else if([row[@"title"] isEqualToString:@"日志"]) { UIAlertController *a=[UIAlertController alertControllerWithTitle:@"日志导出" message:@"请在播放器页打开日志面板，使用“导出”保存完整诊断日志。" preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil]; }
}
- (void)confirmClearEPG {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清理节目单缓存" message:@"缓存将在下次访问频道时重新获取。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){ NSArray *dirs=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES); NSString *p=[[dirs firstObject] stringByAppendingPathComponent:@"epg-cache.json"]; NSError *error=nil; BOOL ok=![NSFileManager.defaultManager fileExistsAtPath:p]||[NSFileManager.defaultManager removeItemAtPath:p error:&error]; if(ok&&self.onClearEPG) self.onClearEPG(); UIAlertController *done=[UIAlertController alertControllerWithTitle:@"缓存" message:ok?@"节目单缓存已清理。":error.localizedDescription preferredStyle:UIAlertControllerStyleAlert]; [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:done animated:YES completion:nil]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
