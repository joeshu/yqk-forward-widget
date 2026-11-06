#import "ServicesViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "HostLocalPort.h"
#import "PluginLogStore.h"
#import "PyHost.h"
#import "ServiceEditorViewController.h"
#import "ServiceStore.h"
#import "M3UParser.h"
#import "ProfileStore.h"
static NSString *ServiceEngineName(NSDictionary *service){return [service[@"engine"] isEqual:@"node"]?@"Node.js Mobile":([service[@"engine"] isEqual:@"javascript"]?@"JavaScriptCore":@"Python");}
static NSString *ServiceProtocolName(NSDictionary *service){
    NSString *protocol=service[@"protocol"]?:@"";
    NSDictionary *names=@{@"catvod-spider":@"CatPaw JS Spider",@"catvod-js":@"CatVod / TVBox JS",@"drpy":@"drpy 规则",@"iptv-extractor":@"IPTV JS Extractor",@"catpaw-http":@"CatPaw Node 服务",@"widget-extractor":@"Widget 影视解析脚本",@"nanotv-service-v2":@"NanoTV 实时频道服务",@"hamo-source-v3":@"Hamo v3 影视源",@"cctvhost.media/1":@"CCTVHost JS API",@"python-spider":@"Python Spider",@"python-http":@"Python HTTP 服务"};
    NSString *name=names[protocol]?: (protocol.length?protocol:@"未识别");
    NSDictionary *manifest=[service[@"manifest"] isKindOfClass:NSDictionary.class]?service[@"manifest"]:@{};
    NSString *moduleType=manifest[@"moduleType"];
    if(moduleType.length)name=[name stringByAppendingFormat:@" · %@",[moduleType isEqual:@"esm"]?@"ESM":([moduleType isEqual:@"commonjs"]?@"CommonJS":@"脚本")];
    return name;
}
static NSString *ServiceHealthDisplay(NSDictionary *snapshot){
    NSString *result=[snapshot[@"result"] isKindOfClass:NSString.class]?snapshot[@"result"]:@"";NSTimeInterval checked=[snapshot[@"checkedAt"] doubleValue];if(!checked)return result;NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"MM-dd HH:mm";return [NSString stringWithFormat:@"%@ · %@",result,[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:checked]]];
}
@interface ServiceProbeRedirectGuard : NSObject <NSURLSessionTaskDelegate>
@end
@implementation ServiceProbeRedirectGuard
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    completionHandler(nil);
}
@end
@interface ServiceDetailViewController : UITableViewController
@property(nonatomic, copy) NSDictionary *service;
@property(nonatomic, copy) void (^onToggle)(NSDictionary *, BOOL);
@property(nonatomic, copy) void (^onChangeService)(NSDictionary *, BOOL, void (^)(NSError * _Nullable));
@property(nonatomic) BOOL changingService;
@property(nonatomic) BOOL changingServiceTarget;
@property(nonatomic, copy) void (^onRestart)(NSDictionary *, void (^)(NSError * _Nullable));
@property(nonatomic, copy) void (^onApplyService)(NSDictionary *, NSDictionary *, void (^)(NSError * _Nullable));
@property(nonatomic, copy) void (^onLog)(NSDictionary * _Nullable service);
@property(nonatomic, copy) void (^onSubscribe)(NSString *);
@property(nonatomic, copy) void (^onOpenResource)(NSDictionary *);
@property(nonatomic, copy) void (^onBrowseService)(NSDictionary *);
@property(nonatomic, copy) NSString *health;
@property(nonatomic, strong) NSURLSessionDataTask *probeTask;
@property(nonatomic,strong) NSURLSession *probeSession;
@property(nonatomic, assign) BOOL probing;
@property(nonatomic, assign) BOOL displayedRunning;
@property(nonatomic, copy) NSString *displayedRuntimeStatus;
@property(nonatomic, assign) NSUInteger probeGeneration;
@property(nonatomic,strong) NSDate *lastProbeResponseAt;
@property(nonatomic,assign) BOOL probePlaylistChecked;
@property(nonatomic,assign) NSUInteger probeChannelCount;
@property(nonatomic, copy, nullable) NSNumber *stopPortState; // 0 端口已释放，1 仍可访问，-1 未知
@property(nonatomic, assign) NSUInteger stopVerifyGeneration;
@property(nonatomic, copy, nullable) NSString *currentRunStartedAt;
- (void)reloadThemeAppearance;
@end
@implementation ServiceDetailViewController
- (BOOL)opensMedia {return [ServiceStore isVODMediaService:self.service];}
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = self.service[@"name"];
    self.tableView.backgroundColor = HostBackground();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.navigationItem.rightBarButtonItems=nil;
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    [self.tableView reloadData];
}
- (BOOL)running {
    return [PyHost isRunningServiceIdentifier:self.service[@"id"]];
}
- (NSString *)baseURL {
    return [NSString stringWithFormat:@"http://127.0.0.1:%@", self.service[@"port"] ?: @8767];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    for (NSDictionary *s in [ServiceStore services])
        if ([s[@"id"] isEqualToString:self.service[@"id"]])
            self.service = s;
    self.title = self.service[@"name"];
    NSDictionary *healthSnapshot=[ServiceStore healthSnapshotForServiceIdentifier:self.service[@"id"]];self.health=ServiceHealthDisplay(healthSnapshot);NSTimeInterval checked=[healthSnapshot[@"checkedAt"] doubleValue];self.lastProbeResponseAt=checked>0?[NSDate dateWithTimeIntervalSince1970:checked]:nil;self.probePlaylistChecked=[ServiceStore playlistPathForService:self.service].length>0&&[healthSnapshot[@"channelCount"] respondsToSelector:@selector(unsignedIntegerValue)];self.probeChannelCount=self.probePlaylistChecked?[healthSnapshot[@"channelCount"] unsignedIntegerValue]:0;
    [self.tableView reloadData];
    self.displayedRunning=[self running];
    self.displayedRuntimeStatus=[self currentRuntimeStatus];
    self.stopPortState=nil;
    [self refreshCurrentRunStart];
    // 打开详情即自动检测一次接口健康：运行中才探测，60 秒内已有成功
    // 响应时不再重复探测，避免来回进出页面反复打接口。
    if([self running])[self probeIfStale];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeStateDidChange) name:PyHostRuntimeStateDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(subscriptionMetadataDidChange) name:ProfileStoreMetadataDidChangeNotification object:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:ProfileStoreMetadataDidChangeNotification object:nil];
    self.probeGeneration++;
    self.stopVerifyGeneration++;
    [self.probeTask cancel];
    self.probeTask=nil;
    [self.probeSession invalidateAndCancel];self.probeSession=nil;
    self.probing = NO;
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.probeTask cancel];[self.probeSession invalidateAndCancel];}
- (NSString *)currentRuntimeStatus {return [PyHost runtimeStatusDescriptionForServiceIdentifier:self.service[@"id"]];}
- (void)subscriptionMetadataDidChange {if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self subscriptionMetadataDidChange];});return;}if(self.isViewLoaded&&self.view.window)[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];}
- (void)runtimeStateDidChange {
    BOOL wasRunning=self.displayedRunning;
    BOOL running=[self running];NSString *status=[self currentRuntimeStatus];
    BOOL changed=running!=self.displayedRunning||![status isEqualToString:self.displayedRuntimeStatus];
    self.displayedRunning=running;self.displayedRuntimeStatus=status;
    if(changed){[self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0,2)] withRowAnimation:UITableViewRowAnimationNone];[self refreshCurrentRunStart];}
    if(!wasRunning&&running)self.stopPortState=nil;
    // 运行 → 已停止：停止只代表会话结束，不代表监听端口已释放。
    // 后台确认一次端口状态，让“已停止”有实测依据；结果只改文案。
    if(wasRunning&&!running)[self verifyPortReleasedAfterStop];
    if(!running&&self.probing){self.probeGeneration++;[self.probeTask cancel];self.probeTask=nil;[self.probeSession invalidateAndCancel];self.probeSession=nil;self.probing=NO;self.health=@"服务已停止 · 未完成检测";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];}
}
- (void)probeIfStale {
    if(self.probing)return;
    if(self.lastProbeResponseAt&&-[self.lastProbeResponseAt timeIntervalSinceNow]<60)return;
    [self probe];
}
- (void)verifyPortReleasedAfterStop {
    NSInteger port=[self.service[@"port"] integerValue];
    if(port<1||port>65535)return;
    NSUInteger generation=++self.stopVerifyGeneration;
    __weak typeof(self) w=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        int state=HostLocalPortState((int)port);
        dispatch_async(dispatch_get_main_queue(),^{ServiceDetailViewController *owner=w;if(!owner||generation!=owner.stopVerifyGeneration||[owner running])return;owner.stopPortState=@(state);[owner.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];});
    });
}
- (NSString *)stopDetailText {
    if(!self.stopPortState)return @"已停止 · 点按开关启动服务";
    if([self.stopPortState integerValue]==0)return @"已停止 · 本机端口已释放";
    if([self.stopPortState integerValue]==1)return @"已停止 · 端口仍可访问，请检查是否有其他程序占用";
    return @"已停止 · 端口状态未知";
}
- (void)refreshCurrentRunStart {
    NSString *value=nil;
    if([self running]){
        NSArray<NSDictionary *> *runs=[PluginLogStore.shared runsForIdentifier:self.service[@"id"]];
        for(NSDictionary *record in runs){
            if([record[@"legacy"] boolValue])continue;
            NSTimeInterval started=[record[@"startedAt"] doubleValue];
            if(started>0){NSDateFormatter *fmt=[NSDateFormatter new];fmt.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];fmt.dateFormat=@"yyyy-MM-dd HH:mm";value=[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:started]];break;}
        }
    }
    if((value&&![value isEqualToString:self.currentRunStartedAt])||(!value&&self.currentRunStartedAt)){self.currentRunStartedAt=value;if(self.isViewLoaded&&self.view.window)[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];}
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0   ? 2
           : section == 1 ? 3
           : section == 2 ? ([ServiceStore isLiveMediaService:self.service]?13:7)
           : section == 3 ? 5
                          : ([self.service[@"builtin"] boolValue] ? 0 : 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray<NSString *> *titles = @[
        [NSString stringWithFormat:@"%@ · 服务状态", ServiceEngineName(self.service)],
        @"本机访问", @"服务信息", @"运行与使用"
    ];
    return section >= 0 && section < (NSInteger)titles.count ? titles[(NSUInteger)section] : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return [@[ @"每个服务可独立启停。运行时活跃不代表 HTTP 健康或视频已完成解码；可在服务详情中分别检测接口。", self.service[@"manifest"][@"compatibilityNote"]?:@"" ] componentsJoinedByString:@"\n"];
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    BOOL addressRow=ip.section==2&&(ip.row==7||ip.row==8);NSString *reuse=addressRow?@"service.detail.address":@"service.detail.row";
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:reuse];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:addressRow?UITableViewCellStyleSubtitle:UITableViewCellStyleValue1 reuseIdentifier:reuse];
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 14;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.clipsToBounds = YES;
    c.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(c, HostBorder());
    c.textLabel.textColor = HostText();
    c.detailTextLabel.textColor = HostSecondaryText();
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.accessoryView=nil;c.accessoryType=UITableViewCellAccessoryNone;c.imageView.image=nil;c.detailTextLabel.text=@"";c.textLabel.textAlignment=NSTextAlignmentNatural;
    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = [self currentRuntimeStatus];
            c.textLabel.textColor = [self running] ? UIColor.systemGreenColor : HostSecondaryText();
            c.detailTextLabel.text = [self running]?@"HTTP 健康状态未知 · 点按“检测服务接口”":[self stopDetailText];
            UIButton *control=[UIButton buttonWithType:UIButtonTypeSystem];
            BOOL managed=[PyHost isManagedServiceIdentifier:self.service[@"id"]];
            BOOL starting=[PyHost isStartingServiceIdentifier:self.service[@"id"]],uncertain=[PyHost hasUncertainSessionForServiceIdentifier:self.service[@"id"]];
            NSString *controlTitle=self.changingService?(self.changingServiceTarget?@"正在启动…":@"正在停止…"):(starting?@"启动中…":(uncertain?@"停止并清理":(managed?@"停止":@"启动")));
            [control setTitle:controlTitle forState:UIControlStateNormal];
            control.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];control.frame=CGRectMake(0,0,112,44);control.enabled=!self.changingService&&!starting;control.accessibilityLabel=self.changingService?(self.changingServiceTarget?@"正在启动服务":@"正在停止服务"):(starting?@"服务启动中":(uncertain?@"停止并清理不确定会话":(managed?@"停止服务":@"启动服务")));
            [control addTarget:self action:@selector(changeService:) forControlEvents:UIControlEventTouchUpInside];c.accessoryView=control;
        } else {
            c.textLabel.text = @"允许局域网访问";
            c.detailTextLabel.text = [self.service[@"lan"] boolValue] ? @"已开启" : @"仅本机";
            // 只读展示会让人误以为点按可改：给出去编辑器的入口。
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (ip.section == 1) {
        NSString *playlistPath=[ServiceStore playlistPathForService:self.service];
        NSString *probePath=[ServiceStore isMediaService:self.service]?@"/health":([self.service[@"builtin"] boolValue]?@"/all.m3u":(playlistPath?:@"/"));
        c.textLabel.text = @[ @"本机端口", @"复制访问地址", @"检测服务接口" ][ip.row];
        c.detailTextLabel.text = ip.row == 0   ? [ServiceStore portRecognitionSummaryForService:self.service]
                                 : ip.row == 1 ? [self baseURL]
                                               : (self.health ?: [NSString stringWithFormat:@"GET %@ · 点击检测",probePath]);
        if (ip.row > 0)
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 2) {
        c.textLabel.text = @[ @"运行引擎", @"资源协议识别", @"版本", @"代码来源", @"入口文件", @"上次更新", @"源地址", @"服务订阅地址", @"节目单地址", @"订阅清单状态", @"频道数量", @"最近成功刷新", @"本次启动时间" ][ip.row];
        NSDate *updated = [NSDate dateWithTimeIntervalSince1970:[self.service[@"updated"] doubleValue]];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        NSDictionary *manifest=[self.service[@"manifest"] isKindOfClass:NSDictionary.class]?self.service[@"manifest"]:@{};
        id rawVersion=manifest[@"version"]?:manifest[@"pluginVersion"]?:self.service[@"version"];
        NSString *version=[rawVersion isKindOfClass:NSString.class]&&[rawVersion length]?rawVersion:@"未知";
        NSString *playlistURL=[ServiceStore subscriptionURLForService:self.service];NSDictionary *playlistMetadata=playlistURL.length?[ProfileStore metadata:playlistURL]:@{};NSArray *cachedChannels=[playlistMetadata[@"cachedChannels"] isKindOfClass:NSArray.class]?playlistMetadata[@"cachedChannels"]:@[];
        NSString *playlistStatus=[playlistMetadata[@"status"] isKindOfClass:NSString.class]?playlistMetadata[@"status"]:(playlistURL.length?([self running]?@"等待读取订阅清单":@"服务已停止 · 保留最近频道"):@"未配置播放列表路径");
        NSString *lastRefresh=[playlistMetadata[@"updatedAt"] doubleValue]>0?[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:[playlistMetadata[@"updatedAt"] doubleValue]]]:@"尚无成功记录";
        NSString *sourceURL=[self.service[@"url"] length]?self.service[@"url"]:@"随应用提供";
        NSString *epgURL=[ServiceStore epgURLForService:self.service];
        NSString *codeName=[ServiceStore codePath:self.service].lastPathComponent;
        NSArray *values = @[
            ServiceEngineName(self.service),
            ServiceProtocolName(self.service),
            version,
            [self.service[@"builtin"] boolValue]
                ? @"内置"
                : ([self.service[@"url"] length] ? @"远程链接" : @"本地文件 / 代码"),
            codeName.length ? codeName : @"—",
            [self.service[@"updated"] doubleValue] > 0 ? [fmt stringFromDate:updated] : @"随应用更新",
            sourceURL,
            playlistURL.length ? playlistURL : @"未声明或未识别播放列表路径",
            epgURL.length ? epgURL : @"尚未从订阅清单中识别",
            playlistStatus,
            cachedChannels.count? [NSString stringWithFormat:@"%lu 个缓存频道",(unsigned long)cachedChannels.count]:(self.probePlaylistChecked?[NSString stringWithFormat:@"%ld 个 · 接口探测",(long)self.probeChannelCount]:@"未知 · 尚未读取有效清单"),
            lastRefresh,
            self.currentRunStartedAt?:([self running]?@"未知 · 无运行记录":@"未运行")
        ];
        c.detailTextLabel.text = values[ip.row];
        NSString *address=ip.row==7?values[7]:(ip.row==8?values[8]:nil);
        if(address){c.detailTextLabel.textAlignment=NSTextAlignmentLeft;if([address hasPrefix:@"http://"]||[address.lowercaseString hasPrefix:@"https://"]){c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;c.selectionStyle=UITableViewCellSelectionStyleDefault;}}
    } else if (ip.section == 3) {
        c.textLabel.text = @[ @"查看日志", @"打开资源详情与配置", @"查看 / 导出代码", @"添加到直播订阅", @"重启服务" ][ip.row];
        if(ip.row==3){if([self opensMedia])c.textLabel.text=@"打开影视";else if([ServiceStore subscriptionURLForService:self.service].length)c.textLabel.text=@"打开直播频道";else c.textLabel.text=@"配置直播列表路径";}
        if(ip.row==4){c.detailTextLabel.text=[self running]?@"先停止再启动，端口不变":@"服务未运行 · 请先启动";c.textLabel.textColor=[self running]?HostText():HostSecondaryText();}
        c.imageView.image = [UIImage systemImageNamed:@[
            @"doc.text", @"square.and.pencil", @"square.and.arrow.up", @"plus.rectangle.on.rectangle", @"arrow.triangle.2.circlepath"
        ][ip.row]];
        c.imageView.tintColor = HostAccent();
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"删除服务";
        c.textLabel.textColor = UIColor.systemRedColor;
    }
    return c;
}
- (void)changeService:(UIButton *)sender {
    if(self.changingService)return;BOOL uncertain=[PyHost hasUncertainSessionForServiceIdentifier:self.service[@"id"]];[self performServiceChange:uncertain?NO:![PyHost isManagedServiceIdentifier:self.service[@"id"]]];
}
- (void)performServiceChange:(BOOL)enabled {
    if(!self.onChangeService){if(self.onToggle)self.onToggle(self.service,enabled);return;}
    self.changingService=YES;self.changingServiceTarget=enabled;[self.tableView reloadData];__weak typeof(self) weakSelf=self;NSDictionary *service=self.service;
    self.onChangeService(service,enabled,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{
        ServiceDetailViewController *owner=weakSelf;if(!owner)return;owner.changingService=NO;[owner.tableView reloadData];
        if(error){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"服务操作失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            if(owner.onChangeService)[alert addAction:[UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner performServiceChange:enabled];}]];
            if(owner.onLog)[alert addAction:[UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){owner.onLog(service);}]];
            [alert addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];[owner presentViewController:alert animated:YES completion:nil];}
    });});
}
- (void)toggle:(UISwitch *)sender {
    if (self.onToggle)
        self.onToggle(self.service, sender.on);
    [self.tableView reloadData];
}
- (void)edit {
    if(self.onOpenResource){self.onOpenResource(self.service);return;}
    ServiceEditorViewController *v = [ServiceEditorViewController new];
    v.service = self.service;
    v.onApplyService = self.onApplyService;
    [self.navigationController pushViewController:v animated:YES];
}
- (void)probe {
    if (self.probing)
        return;
    if(![self running]){self.health=@"服务未运行 · 未检测";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];return;}
    self.probing = YES;
    self.health = @"检测中…";
    self.probePlaylistChecked=NO;self.probeChannelCount=0;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
    BOOL manifestService=[ServiceStore isMediaService:self.service];
    NSString *playlistPath=[ServiceStore playlistPathForService:self.service];
    NSString *path=manifestService?@"/health":(playlistPath?:@"/");
    NSURL *probeURL=[NSURL URLWithString:[[self baseURL] stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:probeURL];
    r.timeoutInterval = 5;
    r.cachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    NSUInteger generation=++self.probeGeneration;
    __weak typeof(self) w = self;
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    self.probeSession=[NSURLSession sessionWithConfiguration:configuration delegate:[ServiceProbeRedirectGuard new] delegateQueue:nil];
    self.probeTask = [self.probeSession
        dataTaskWithRequest:r
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              if(!w||generation!=w.probeGeneration)return;
              w.probing = NO;
              w.probeTask=nil;
              [w.probeSession finishTasksAndInvalidate];w.probeSession=nil;
              NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
              if(!error&&status)w.lastProbeResponseAt=NSDate.date;
              NSDateFormatter *clock=[NSDateFormatter new];clock.dateFormat=@"HH:mm";NSString *time=w.lastProbeResponseAt?[NSString stringWithFormat:@" · 最近 HTTP 响应 %@",[clock stringFromDate:w.lastProbeResponseAt]]:@"";
              if(error)w.health=[NSString stringWithFormat:@"连接失败：%@",error.localizedDescription?:@"未知错误"];
              else if(status<200||status>=300)w.health=[NSString stringWithFormat:@"HTTP 可达 · 返回 %ld · 服务状态未知%@",(long)status,time];
              else if(manifestService){id json=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;BOOL healthy=[json isKindOfClass:NSDictionary.class]&&[json[@"ok"] isKindOfClass:NSNumber.class]&&[json[@"ok"] boolValue];w.health=[(healthy?@"健康检查通过 · GET /health":@"HTTP 可访问 · /health 未确认健康字段") stringByAppendingString:time];}
              else if(playlistPath.length){NSString *text=data.length<=10*1024*1024?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;NSArray *channels=text.length?[M3UParser parse:text baseURL:probeURL]:@[];BOOL format=[text containsString:@"#EXTM3U"]||[text containsString:@"#EXTINF"]||channels.count>0;if(format){w.probePlaylistChecked=YES;w.probeChannelCount=channels.count;NSString *detectedEPG=text.length?[M3UParser epgURL:text baseURL:probeURL]:nil;if(!detectedEPG.length){NSString *epgPath=[ServiceStore epgPathForService:w.service];if(epgPath.length)detectedEPG=[[w baseURL] stringByAppendingString:epgPath];}NSString *subURL=[ServiceStore subscriptionURLForService:w.service];if(subURL.length&&detectedEPG.length){[ProfileStore update:subURL values:@{@"managedServiceID":w.service[@"id"]?:@"",@"detectedEPGURL":detectedEPG}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:subURL];}}w.health=[(format?[NSString stringWithFormat:@"频道清单可读取 · %lu 个频道",(unsigned long)channels.count]:[NSString stringWithFormat:@"HTTP %ld · 响应不是有效频道清单",(long)status]) stringByAppendingString:time];}
              else w.health=[[NSString stringWithFormat:@"HTTP 可访问 · GET %@ 返回 %ld · 健康状态未知",path,(long)status] stringByAppendingString:time];
              NSMutableDictionary *snapshot=[@{@"status":error?@"failed":((status>=200&&status<300)?@"reachable":@"http-error"),@"result":w.health?:@"检测完成",@"httpStatus":@(status),@"checkedAt":@(NSDate.date.timeIntervalSince1970),@"path":path?:@"/"} mutableCopy];if(w.probePlaylistChecked)snapshot[@"channelCount"]=@(w.probeChannelCount);[ServiceStore recordHealthSnapshot:snapshot forServiceIdentifier:w.service[@"id"]];
              [w.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1,2)] withRowAnimation:UITableViewRowAnimationNone];
            });
          }];
    [self.probeTask resume];
}
- (void)restart {
    // 重启只对运行中的服务有意义：已停止的服务用第 0 区的开关启动，
    // 避免“重启”被误读成启动。进行中用 prompt 反馈，失败弹明确原因。
    if(![self running]){self.navigationItem.prompt=@"服务未运行 · 请先启动";__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ServiceDetailViewController *owner=weakSelf;if(owner&&[owner.navigationItem.prompt isEqual:@"服务未运行 · 请先启动"])owner.navigationItem.prompt=nil;});return;}
    if(!self.onRestart){self.navigationItem.prompt=@"当前版本不支持重启此服务";__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ServiceDetailViewController *owner=weakSelf;if(owner&&[owner.navigationItem.prompt isEqual:@"当前版本不支持重启此服务"])owner.navigationItem.prompt=nil;});return;}
    self.navigationItem.prompt=@"正在重启服务…";__weak typeof(self) w=self;
    self.onRestart(self.service,^(NSError *error){
        ServiceDetailViewController *owner=w;if(!owner)return;owner.navigationItem.prompt=nil;
        if(error){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"重启失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[owner presentViewController:a animated:YES completion:nil];return;}
        [owner.tableView reloadData];
    });
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0 && ip.row == 1) {
        [self edit];
        return;
    }
    if (ip.section == 1 && ip.row == 1) {
        UIPasteboard.generalPasteboard.string = [self baseURL];
        self.navigationItem.prompt = @"地址已复制";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if([self.navigationItem.prompt isEqual:@"地址已复制"])self.navigationItem.prompt=nil;});
        [tableView reloadData];
    } else if (ip.section == 1 && ip.row == 2)
        [self probe];
    else if(ip.section==2 && (ip.row==7||ip.row==8)) {
        NSString *value=[ServiceStore subscriptionURLForService:self.service];
        if(ip.row==8)value=[ServiceStore epgURLForService:self.service];
        if(value.length){UIPasteboard.generalPasteboard.string=value;NSString *message=ip.row==7?@"服务订阅地址已复制":@"节目单地址已复制";self.navigationItem.prompt=message;__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ServiceDetailViewController *owner=weakSelf;if(owner&&[owner.navigationItem.prompt isEqual:message])owner.navigationItem.prompt=nil;});}
    }
    else if (ip.section == 3) {
        if (ip.row == 0) {
            if (self.onLog)
                self.onLog(self.service);
        } else if (ip.row == 1)
            [self edit];
        else if (ip.row == 2) {
            UIAlertController *a =
                [UIAlertController alertControllerWithTitle:@"资源代码"
                                                    message:nil
                                             preferredStyle:UIAlertControllerStyleActionSheet];
            [a addAction:[UIAlertAction
                             actionWithTitle:@"查看代码"
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *action) {
                                       ServiceCodeViewController *v = [ServiceCodeViewController new];
                                       v.path = [ServiceStore codePath:self.service];
                                       v.readOnly = YES;
                                       [self.navigationController pushViewController:v animated:YES];
                                     }]];
            [a addAction:[UIAlertAction
                             actionWithTitle:@"导出文件"
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *action) {
                                       // archivePath 为空且 codePath 校验失败返回 nil 时，
                                       // @[nil] 会直接崩溃；先判空并提示。
                                       NSString *exportPath=[self.service[@"archivePath"] length]?self.service[@"archivePath"]:[ServiceStore codePath:self.service];
                                       if(!exportPath.length){UIAlertController *notice=[UIAlertController alertControllerWithTitle:@"无法导出" message:@"未找到可导出的资源文件。" preferredStyle:UIAlertControllerStyleAlert];[notice addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:notice animated:YES completion:nil];return;}
                                       UIActivityViewController *v =
                                           [[UIActivityViewController alloc] initWithActivityItems:@[
                                               [NSURL fileURLWithPath:exportPath]
                                           ]
                                                                             applicationActivities:nil];
                                       v.popoverPresentationController.sourceView = self.view;
                                       v.popoverPresentationController.sourceRect =
                                           CGRectMake(self.view.bounds.size.width / 2,
                                                      self.view.bounds.size.height / 2, 1, 1);
                                       [self presentViewController:v animated:YES completion:nil];
                                     }]];
            [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            // 行已滑出可视区时 cell 为 nil：iPad 上 sourceView 为 nil 会崩溃，用 self.view 兜底。
            UITableViewCell *actionCell=[tableView cellForRowAtIndexPath:ip];a.popoverPresentationController.sourceView=actionCell?:self.view;a.popoverPresentationController.sourceRect=actionCell?actionCell.bounds:CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);
            [self presentViewController:a animated:YES completion:nil];
        } else if (ip.row == 3) {
            if([self opensMedia]){if(self.onBrowseService)self.onBrowseService(self.service);return;}
            NSString *u = [ServiceStore subscriptionURLForService:self.service];
            if (self.onSubscribe)
                if(u.length)self.onSubscribe(u);else{UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"未配置直播列表" message:@"请编辑服务，填写或修复播放列表路径后再添加频道。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"编辑服务" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self edit];}]];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
        } else if (ip.row == 4) {
            [self restart];
        }
    } else if (ip.section == 4) {
        if ([PyHost isManagedServiceIdentifier:self.service[@"id"]]) {
            // 运行中的服务点“删除”此前静默无反应：明确告诉用户先停止再删。
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"请先停止服务" message:@"该服务正在运行、停止或清理中，停止后才能删除本机保存的服务与代码文件。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        UIAlertController *a =
            [UIAlertController alertControllerWithTitle:@"删除服务？"
                                                message:@"这会删除本机保存的服务与代码文件。"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"删除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                              [ServiceStore remove:self.service[@"id"]];
                                              [self.navigationController popViewControllerAnimated:YES];
                                            }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
@end

@interface ServicesViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property(nonatomic,strong) NSMutableSet<NSString *> *changingServiceIDs;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *changingServiceTargets;
@property(nonatomic,strong) UISegmentedControl *statusFilter;
@property(nonatomic,strong) UILabel *runtimeSummary;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) NSArray<NSDictionary *> *services;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@property(nonatomic, copy) NSArray<NSString *> *sectionTitles;
@property(nonatomic, copy) NSString *displayedRunningID;
@property(nonatomic, copy) NSString *displayedRuntimeStatus;
@property(nonatomic, strong) UILabel *emptyLabel;
@end
@implementation ServicesViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.title = @"资源服务";
    self.view.backgroundColor = HostBackground();
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = HostBackground();
    // The table is already constrained inside the safe area. Disable UIKit's
    // automatic scroll-view inset as well, otherwise the navigation/status
    // inset may be applied a second time and leave a blank band above services.
    self.table.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight=88;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    __weak typeof(self) w=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"plus",@"title":@"添加服务",@"action":[UIAction actionWithHandler:^(UIAction *a){[w add];}]},
        @{@"icon":@"doc.text",@"title":@"总日志",@"action":[UIAction actionWithHandler:^(UIAction *a){if(w.onOpenLog)w.onOpenLog(nil);}]}])];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索名称、端口或协议";
    self.navigationItem.searchController = self.search;
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,self.view.bounds.size.width,88)];self.runtimeSummary=[[UILabel alloc] initWithFrame:CGRectMake(16,4,MAX(1,header.bounds.size.width-32),28)];self.runtimeSummary.autoresizingMask=UIViewAutoresizingFlexibleWidth;self.runtimeSummary.textColor=HostSecondaryText();self.runtimeSummary.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];[header addSubview:self.runtimeSummary];self.statusFilter=[[UISegmentedControl alloc] initWithItems:@[@"全部",@"运行中",@"待处理",@"已停止"]];self.statusFilter.frame=CGRectMake(16,36,MAX(1,header.bounds.size.width-32),44);self.statusFilter.autoresizingMask=UIViewAutoresizingFlexibleWidth;self.statusFilter.selectedSegmentIndex=0;self.statusFilter.selectedSegmentTintColor=HostAccent();[self.statusFilter addTarget:self action:@selector(statusFilterChanged) forControlEvents:UIControlEventValueChanged];[header addSubview:self.statusFilter];self.table.tableHeaderView=header;
    self.emptyLabel=[UILabel new];self.emptyLabel.text=@"还没有服务\n点右上角 + 添加服务，或从资源页导入脚本";self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.numberOfLines=0;self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.emptyLabel.adjustsFontForContentSizeCategory=YES;self.table.backgroundView=self.emptyLabel;
    [self refresh];
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();
    self.table.backgroundColor=HostBackground();
    self.runtimeSummary.textColor=HostSecondaryText();
    self.statusFilter.selectedSegmentTintColor=HostAccent();
    self.emptyLabel.textColor=HostSecondaryText();
    [self.table reloadData];
}
- (void)statusFilterChanged {self.displayedRunningID=nil;[self refresh];}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeStateDidChange) name:PyHostRuntimeStateDidChangeNotification object:nil];
    [self refresh];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)runtimeStateDidChange {if(!self.changingServiceIDs.count)[self refresh];}
- (void)refresh {
    NSArray *all = [ServiceStore services];
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSArray *filtered =
        q.length ? [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s,
                                                                                          NSDictionary *b) {
                          // 排查端口冲突时常按端口或协议找服务：只按名称搜不到。
                          NSString *name=[s[@"name"] lowercaseString]?:@"";
                          NSString *identifier=[s[@"id"] lowercaseString]?:@"";
                          NSString *engine=[s[@"engine"] lowercaseString]?:@"";
                          NSString *protocol=[s[@"protocol"] lowercaseString]?:@"";
                          NSString *port=[s[@"port"] description]?:@"";
                          NSString *epg=[[ServiceStore epgURLForService:s] lowercaseString]?:@"";
                          return [name containsString:q]||[identifier containsString:q]||[engine containsString:q]||[protocol containsString:q]||[port containsString:q]||[epg containsString:q];
                        }]]
                 : all;
    NSMutableArray *runningIDs=[NSMutableArray array];for(NSDictionary *service in filtered)if([PyHost isRunningServiceIdentifier:service[@"id"]])[runningIDs addObject:service[@"id"]];[runningIDs sortUsingSelector:@selector(compare:)];
    NSString *runningID=[runningIDs componentsJoinedByString:@","];
    NSMutableArray *statuses=[NSMutableArray array];for(NSDictionary *service in filtered)[statuses addObject:[PyHost runtimeStatusDescriptionForServiceIdentifier:service[@"id"]]];
    NSString *runtimeStatus=[statuses componentsJoinedByString:@" · "];
    if([self.services isEqualToArray:filtered] && [self.displayedRunningID isEqualToString:runningID] && [self.displayedRuntimeStatus isEqualToString:runtimeStatus])return;
    self.services=filtered;self.displayedRunningID=runningID;self.displayedRuntimeStatus=runtimeStatus;
    NSMutableArray *running=[NSMutableArray array], *pending=[NSMutableArray array], *stopped=[NSMutableArray array];
    for(NSDictionary *service in filtered){NSString *identifier=service[@"id"];NSMutableArray *target=([PyHost isStartingServiceIdentifier:identifier]||[PyHost hasUncertainSessionForServiceIdentifier:identifier])?pending:([PyHost isRunningServiceIdentifier:identifier]?running:([PyHost isManagedServiceIdentifier:identifier]?pending:stopped));[target addObject:service];}
    NSMutableArray *visibleSections=[NSMutableArray array];NSMutableArray *titles=[NSMutableArray array];
    if(running.count){[visibleSections addObject:running];[titles addObject:@"运行时活跃 · HTTP 状态单独检测"];}
    if(pending.count){[visibleSections addObject:pending];[titles addObject:@"启停结果待确认 · 可关闭后清理"];}
    if(stopped.count){[visibleSections addObject:stopped];[titles addObject:@"已停止"];}
    self.runtimeSummary.text=[NSString stringWithFormat:@"运行 %lu · 待处理 %lu · 已停止 %lu",(unsigned long)running.count,(unsigned long)pending.count,(unsigned long)stopped.count];
    NSInteger scope=self.statusFilter.selectedSegmentIndex;if(scope>0){NSArray *chosen=@[running,pending,stopped][scope-1];visibleSections=[NSMutableArray array];titles=[NSMutableArray array];if(chosen.count){[visibleSections addObject:chosen];[titles addObject:@[@"运行时活跃 · HTTP 状态单独检测",@"启停结果待确认",@"已停止"][scope-1]];}}
    self.sections=visibleSections;self.sectionTitles=titles;
    self.emptyLabel.hidden=filtered.count>0;
    [self.table reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self refresh];
}
- (void)add {
    if(self.onImportResource){UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"添加资源" message:nil preferredStyle:UIAlertControllerStyleActionSheet];[sheet addAction:[UIAlertAction actionWithTitle:@"导入资源 · URL / 文件 / 文件夹" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.onImportResource();}]];[sheet addAction:[UIAlertAction actionWithTitle:@"添加 Python HTTP 服务" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ServiceEditorViewController *editor=[ServiceEditorViewController new];[self.navigationController pushViewController:editor animated:YES];}]];[sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.firstObject;[self presentViewController:sheet animated:YES completion:nil];return;}
    ServiceEditorViewController *v = [ServiceEditorViewController new];
    [self.navigationController pushViewController:v animated:YES];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}
- (NSArray *)rows:(NSInteger)section {
    return section<self.sections.count?self.sections[section]:@[];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rows:section].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section<self.sectionTitles.count?self.sectionTitles[section]:nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *s = [self rows:ip.section][ip.row];
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"service.session"];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"service.session"];
    // 运行中只代表进程/会话活跃，不代表接口健康或能播：不用绿色底暗示“健康”。
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 14;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.clipsToBounds = YES;
    c.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(c, HostBorder());
    c.accessoryView=nil;c.accessoryType=UITableViewCellAccessoryNone;c.imageView.image=nil;c.selectionStyle=UITableViewCellSelectionStyleDefault;
    c.textLabel.text = s[@"name"];
    c.textLabel.textColor = HostText();
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    NSString *epgURL=[ServiceStore epgURLForService:s];
    NSString *liveSummary=epgURL.length?[NSString stringWithFormat:@" · 节目单 %@",epgURL]:@"";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@\nhttp://127.0.0.1:%@（%@）%@",
                                   ServiceEngineName(s),
                                   [s[@"builtin"] boolValue] ? @"内置服务" : @"本机脚本",
                                   [PyHost runtimeStatusDescriptionForServiceIdentifier:s[@"id"]],
                                   s[@"port"],
                                   [ServiceStore portRecognitionSummaryForService:s],
                                   liveSummary];
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.textColor = HostSecondaryText();
    c.imageView.image = [UIImage systemImageNamed:@"terminal.fill"];
    c.imageView.tintColor = HostAccent();
    UIButton *control=[UIButton buttonWithType:UIButtonTypeSystem];NSString *identifier=s[@"id"]?:@"";
    BOOL busy=[self.changingServiceIDs containsObject:identifier],managed=[PyHost isManagedServiceIdentifier:identifier],starting=[PyHost isStartingServiceIdentifier:identifier],uncertain=[PyHost hasUncertainSessionForServiceIdentifier:identifier];
    BOOL target=[[self.changingServiceTargets objectForKey:identifier] boolValue];
    NSString *controlTitle=busy?(target?@"正在启动…":@"正在停止…"):(starting?@"启动中…":(uncertain?@"停止并清理":(managed?@"停止":@"启动")));
    [control setTitle:controlTitle forState:UIControlStateNormal];
    control.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];control.frame=CGRectMake(0,0,108,44);control.enabled=!busy&&!starting;control.accessibilityIdentifier=identifier;control.accessibilityLabel=busy?(target?@"正在启动服务":@"正在停止服务"):(starting?@"服务启动中":(uncertain?@"停止并清理不确定会话":(managed?@"停止服务":@"启动服务")));
    [control addTarget:self action:@selector(changeService:) forControlEvents:UIControlEventTouchUpInside];c.accessoryView=control;
    return c;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSArray *sectionRows=[self rows:ip.section];
    if(ip.row<0||ip.row>=(NSInteger)sectionRows.count)return nil;
    NSDictionary *service=sectionRows[ip.row];
    NSString *identifier=service[@"id"]?:@"";
    if(!identifier.length)return nil;
    __weak typeof(self) weakSelf=self;
    BOOL running=[PyHost isRunningServiceIdentifier:identifier];
    BOOL managed=[PyHost isManagedServiceIdentifier:identifier];
    return [UIContextMenuConfiguration configurationWithIdentifier:identifier previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        NSMutableArray<UIAction *> *actions=[NSMutableArray array];
        [actions addObject:[UIAction actionWithTitle:managed?@"停止服务":@"启动服务" image:[UIImage systemImageNamed:managed?@"stop.circle":@"play.circle"] identifier:nil handler:^(__unused UIAction *a){[weakSelf performServiceChange:service enabled:!managed];}]];
        if(running&&weakSelf.onRestartService){
            [actions addObject:[UIAction actionWithTitle:@"重启服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(__unused UIAction *a){weakSelf.onRestartService(service,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{weakSelf.displayedRunningID=nil;[weakSelf refresh];});});}]];
        }
        if(weakSelf.onOpenResource){
            [actions addObject:[UIAction actionWithTitle:@"打开资源详情与配置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(__unused UIAction *a){weakSelf.onOpenResource(service);}]];
        }
        if(weakSelf.onOpenLog){
            [actions addObject:[UIAction actionWithTitle:@"查看运行日志" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(__unused UIAction *a){weakSelf.onOpenLog(service);}]];
        }
        NSString *endpoint=[NSString stringWithFormat:@"http://127.0.0.1:%@",service[@"port"]?:@8767];
        [actions addObject:[UIAction actionWithTitle:@"复制本机访问地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=endpoint;}]];
        return [UIMenu menuWithTitle:service[@"name"]?:@"服务操作" children:actions];
    }];
}
- (void)changeService:(UIButton *)sender {
    NSString *identifier=sender.accessibilityIdentifier;if(!identifier.length||[self.changingServiceIDs containsObject:identifier])return;
    NSDictionary *service=nil;for(NSDictionary *candidate in self.services)if([candidate[@"id"] isEqual:identifier]){service=candidate;break;}if(!service)return;
    BOOL enabled=[PyHost hasUncertainSessionForServiceIdentifier:identifier]?NO:![PyHost isManagedServiceIdentifier:identifier];[self performServiceChange:service enabled:enabled];
}
- (void)performServiceChange:(NSDictionary *)service enabled:(BOOL)enabled {
    NSString *identifier=[service[@"id"] description];if(!identifier.length)return;
    if(!self.onChangeService){if(self.onToggleService)self.onToggleService(service,enabled);return;}
    if(!self.changingServiceIDs)self.changingServiceIDs=[NSMutableSet set];if(!self.changingServiceTargets)self.changingServiceTargets=[NSMutableDictionary dictionary];if([self.changingServiceIDs containsObject:identifier])return;
    [self.changingServiceIDs addObject:identifier];self.changingServiceTargets[identifier]=@(enabled);[self.table reloadData];__weak typeof(self) weakSelf=self;
    self.onChangeService(service,enabled,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{ServicesViewController *owner=weakSelf;if(!owner)return;[owner.changingServiceIDs removeObject:identifier];[owner.changingServiceTargets removeObjectForKey:identifier];owner.displayedRunningID=nil;[owner refresh];
        if(error){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"服务操作失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[owner performServiceChange:service enabled:enabled];}]];
            if(owner.onOpenLog)[alert addAction:[UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){owner.onOpenLog(service);}]];
            [alert addAction:[UIAlertAction actionWithTitle:@"完成" style:UIAlertActionStyleCancel handler:nil]];[owner presentViewController:alert animated:YES completion:nil];}
    });});
}
- (void)toggle:(UISwitch *)sender {
    for (NSDictionary *s in self.services)
        if ([s[@"id"] isEqualToString:sender.accessibilityIdentifier]) {
            if (self.onToggleService)
                self.onToggleService(s, sender.on);
            break;
        }
    self.displayedRunningID=nil; // Restore the switch while asynchronous start/stop completes.
    [self refresh];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    ServiceDetailViewController *v = [ServiceDetailViewController new];
    v.service = [self rows:ip.section][ip.row];
    v.onToggle = self.onToggleService;
    v.onChangeService=self.onChangeService;v.onOpenResource=self.onOpenResource;
    v.onRestart = self.onRestartService;
    v.onApplyService = self.onApplyService;
    v.onLog = self.onOpenLog;
    v.onSubscribe = self.onSubscribe;
    v.onBrowseService=self.onBrowseService;
    [self.navigationController pushViewController:v animated:YES];
}
@end
