#import "ServicesViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "PyHost.h"
#import "ServiceEditorViewController.h"
#import "ServiceStore.h"
#import "M3UParser.h"
static NSString *ServiceEngineName(NSDictionary *service){return [service[@"engine"] isEqual:@"node"]?@"Node.js Mobile":([service[@"engine"] isEqual:@"javascript"]?@"JavaScriptCore":@"Python");}
static NSString *ServiceProtocolName(NSDictionary *service){
    NSString *protocol=service[@"protocol"]?:@"";
    NSDictionary *names=@{@"catvod-spider":@"CatPaw JS Spider",@"catvod-js":@"CatVod / TVBox JS",@"drpy":@"drpy 规则",@"iptv-extractor":@"IPTV JS Extractor",@"catpaw-http":@"CatPaw Node 服务",@"widget-extractor":@"Widget 影视解析脚本",@"cctvhost.media/1":@"CCTVHost JS API",@"python-spider":@"Python Spider",@"python-http":@"Python HTTP 服务"};
    NSString *name=names[protocol]?: (protocol.length?protocol:@"未识别");
    NSDictionary *manifest=[service[@"manifest"] isKindOfClass:NSDictionary.class]?service[@"manifest"]:@{};
    NSString *moduleType=manifest[@"moduleType"];
    if(moduleType.length)name=[name stringByAppendingFormat:@" · %@",[moduleType isEqual:@"esm"]?@"ESM":([moduleType isEqual:@"commonjs"]?@"CommonJS":@"脚本")];
    return name;
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
@property(nonatomic, copy) void (^onApplyService)(NSDictionary *, NSDictionary *, void (^)(NSError * _Nullable));
@property(nonatomic, copy) void (^onLog)(NSDictionary * _Nullable service);
@property(nonatomic, copy) void (^onSubscribe)(NSString *);
@property(nonatomic, copy) void (^onBrowseService)(NSDictionary *);
@property(nonatomic, copy) NSString *health;
@property(nonatomic, strong) NSURLSessionDataTask *probeTask;
@property(nonatomic,strong) NSURLSession *probeSession;
@property(nonatomic, assign) BOOL probing;
@property(nonatomic, assign) BOOL displayedRunning;
@property(nonatomic, copy) NSString *displayedRuntimeStatus;
@property(nonatomic, assign) NSUInteger probeGeneration;
@property(nonatomic,strong) NSDate *lastProbeResponseAt;
@end
@implementation ServiceDetailViewController
- (BOOL)opensMedia {NSArray *caps=self.service[@"capabilities"];return [ServiceStore isMediaService:self.service] && (![caps isKindOfClass:NSArray.class] || !caps.count || [caps containsObject:@"detail"] || [caps containsObject:@"play"]);}
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.service[@"name"];
    self.tableView.backgroundColor = HostBackground();
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    __weak typeof(self) w=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"pencil",@"title":@"编辑服务",@"action":[UIAction actionWithHandler:^(UIAction *a){[w edit];}]}])];
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
    [self.tableView reloadData];
    self.displayedRunning=[self running];
    self.displayedRuntimeStatus=[self currentRuntimeStatus];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeStateDidChange) name:PyHostRuntimeStateDidChangeNotification object:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];
    self.probeGeneration++;
    [self.probeTask cancel];
    self.probeTask=nil;
    [self.probeSession invalidateAndCancel];self.probeSession=nil;
    self.probing = NO;
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.probeTask cancel];[self.probeSession invalidateAndCancel];}
- (NSString *)currentRuntimeStatus {return [PyHost runtimeStatusDescriptionForServiceIdentifier:self.service[@"id"]];}
- (void)runtimeStateDidChange {
    BOOL running=[self running];NSString *status=[self currentRuntimeStatus];
    BOOL changed=running!=self.displayedRunning||![status isEqualToString:self.displayedRuntimeStatus];
    self.displayedRunning=running;self.displayedRuntimeStatus=status;
    if(changed)[self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0,2)] withRowAnimation:UITableViewRowAnimationNone];
    if(!running&&self.probing){self.probeGeneration++;[self.probeTask cancel];self.probeTask=nil;[self.probeSession invalidateAndCancel];self.probeSession=nil;self.probing=NO;self.health=@"服务已停止 · 未完成检测";[self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];}
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0   ? 2
           : section == 1 ? 3
           : section == 2 ? 7
           : section == 3 ? 4
                          : ([self.service[@"builtin"] boolValue] ? 0 : 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSArray<NSString *> *titles = @[
        [NSString stringWithFormat:@"%@ · 服务状态", ServiceEngineName(self.service)],
        @"本机访问", @"服务信息", @"操作"
    ];
    return section >= 0 && section < (NSInteger)titles.count ? titles[(NSUInteger)section] : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return [@[ @"每个服务可独立启停。运行时活跃不代表 HTTP 健康或视频已完成解码；可在服务详情中分别检测接口。", self.service[@"manifest"][@"compatibilityNote"]?:@"" ] componentsJoinedByString:@"\n"];
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"service.detail.row"];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"service.detail.row"];
    c.backgroundColor = HostCard();
    c.textLabel.textColor = HostText();
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 3;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.accessoryView=nil;c.accessoryType=UITableViewCellAccessoryNone;c.imageView.image=nil;c.detailTextLabel.text=@"";c.textLabel.textAlignment=NSTextAlignmentNatural;
    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = [self currentRuntimeStatus];
            c.textLabel.textColor = [self running] ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
            c.detailTextLabel.text = [self running]?@"HTTP 健康状态未知 · 点按“检测服务接口”":[self currentRuntimeStatus];
            UISwitch *sw = [UISwitch new];
            sw.on = [PyHost isManagedServiceIdentifier:self.service[@"id"]];
            sw.onTintColor = HostAccent();
            [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else {
            c.textLabel.text = @"允许局域网访问";
            c.detailTextLabel.text = [self.service[@"lan"] boolValue] ? @"已开启" : @"仅本机";
        }
    } else if (ip.section == 1) {
        c.textLabel.text = @[ @"本机端口", @"复制访问地址", @"检测服务接口" ][ip.row];
        c.detailTextLabel.text = ip.row == 0   ? [self.service[@"port"] description]
                                 : ip.row == 1 ? [self baseURL]
                                               : (self.health ?: @"GET / · 点击检测");
        if (ip.row > 0)
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 2) {
        c.textLabel.text = @[ @"运行引擎", @"资源协议识别", @"版本", @"代码来源", @"入口文件", @"上次更新", @"源地址" ][ip.row];
        NSDate *updated = [NSDate dateWithTimeIntervalSince1970:[self.service[@"updated"] doubleValue]];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        NSDictionary *manifest=[self.service[@"manifest"] isKindOfClass:NSDictionary.class]?self.service[@"manifest"]:@{};
        id rawVersion=manifest[@"version"]?:self.service[@"version"];
        NSString *version=[rawVersion isKindOfClass:NSString.class]&&[rawVersion length]?rawVersion:@"未知";
        NSArray *values = @[
            ServiceEngineName(self.service),
            ServiceProtocolName(self.service),
            version,
            [self.service[@"builtin"] boolValue]
                ? @"内置"
                : ([self.service[@"url"] length] ? @"远程链接" : @"本地文件 / 代码"),
            [ServiceStore codePath:self.service].lastPathComponent ?: @"—",
            [self.service[@"updated"] doubleValue] > 0 ? [fmt stringFromDate:updated] : @"随应用更新",
            self.service[@"url"] ?: @"随应用提供"
        ];
        c.detailTextLabel.text = values[ip.row];
    } else if (ip.section == 3) {
        c.textLabel.text = @[ @"查看日志", @"编辑服务", @"查看 / 导出代码", @"添加到直播订阅" ][ip.row];
        if(ip.row==3 && [self opensMedia])c.textLabel.text=@"打开影视";
        c.imageView.image = [UIImage systemImageNamed:@[
            @"doc.text", @"square.and.pencil", @"square.and.arrow.up", @"plus.rectangle.on.rectangle"
        ][ip.row]];
        c.imageView.tintColor = HostAccent();
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"删除服务";
        c.textLabel.textColor = HostAccent();
    }
    return c;
}
- (void)toggle:(UISwitch *)sender {
    if (self.onToggle)
        self.onToggle(self.service, sender.on);
    [self.tableView reloadData];
}
- (void)edit {
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
    [self.tableView reloadData];
    BOOL manifestService=[ServiceStore isMediaService:self.service];BOOL builtin=[self.service[@"builtin"] boolValue];
    NSString *path=manifestService?@"/health":(builtin?@"/all.m3u":@"/");
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
              else if(builtin){NSString *text=data.length<=10*1024*1024?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;NSArray *channels=text.length?[M3UParser parse:text baseURL:probeURL]:@[];w.health=[(channels.count?[NSString stringWithFormat:@"频道清单可读取 · %lu 个频道",(unsigned long)channels.count]:@"HTTP 可访问 · 没有有效频道清单") stringByAppendingString:time];}
              else w.health=[[NSString stringWithFormat:@"HTTP 可访问 · GET / 返回 %ld · 健康状态未知",(long)status] stringByAppendingString:time];
              [w.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
            });
          }];
    [self.probeTask resume];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && ip.row == 1) {
        UIPasteboard.generalPasteboard.string = [self baseURL];
        self.health = @"地址已复制";
        [tableView reloadData];
    } else if (ip.section == 1 && ip.row == 2)
        [self probe];
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
                                       UIActivityViewController *v =
                                           [[UIActivityViewController alloc] initWithActivityItems:@[
                                               [NSURL fileURLWithPath:[self.service[@"archivePath"] length]?self.service[@"archivePath"]:[ServiceStore codePath:self.service]]
                                           ]
                                                                             applicationActivities:nil];
                                       v.popoverPresentationController.sourceView = self.view;
                                       v.popoverPresentationController.sourceRect =
                                           CGRectMake(self.view.bounds.size.width / 2,
                                                      self.view.bounds.size.height / 2, 1, 1);
                                       [self presentViewController:v animated:YES completion:nil];
                                     }]];
            [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            a.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:ip];
            a.popoverPresentationController.sourceRect = [tableView cellForRowAtIndexPath:ip].bounds;
            [self presentViewController:a animated:YES completion:nil];
        } else {
            if([self opensMedia]){if(self.onBrowseService)self.onBrowseService(self.service);return;}
            NSString *u = [[self baseURL] stringByAppendingString:@"/all.m3u"];
            if (self.onSubscribe)
                self.onSubscribe(u);
        }
    } else if (ip.section == 4) {
        if ([PyHost isManagedServiceIdentifier:self.service[@"id"]])
            return;
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
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) NSArray<NSDictionary *> *services;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sections;
@property(nonatomic, copy) NSString *displayedRunningID;
@property(nonatomic, copy) NSString *displayedRuntimeStatus;
@end
@implementation ServicesViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"服务";
    self.view.backgroundColor = HostBackground();
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = HostBackground();
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight=88;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    __weak typeof(self) w=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"plus",@"title":@"添加服务",@"action":[UIAction actionWithHandler:^(UIAction *a){[w add];}]},
        @{@"icon":@"doc.text",@"title":@"总日志",@"action":[UIAction actionWithHandler:^(UIAction *a){if(w.onOpenLog)w.onOpenLog(nil);}]}])];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索服务";
    self.navigationItem.searchController = self.search;
    [self refresh];
}
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
- (void)runtimeStateDidChange {[self refresh];}
- (void)refresh {
    NSArray *all = [ServiceStore services];
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSArray *filtered =
        q.length ? [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s,
                                                                                          NSDictionary *b) {
                          return [[s[@"name"] lowercaseString] containsString:q];
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
    self.sections=@[running,pending,stopped];
    [self.table reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self refresh];
}
- (void)add {
    if(self.onImportResource){UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"添加资源" message:nil preferredStyle:UIAlertControllerStyleActionSheet];[sheet addAction:[UIAlertAction actionWithTitle:@"导入影视包 · JS / Python / ZIP" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.onImportResource();}]];[sheet addAction:[UIAlertAction actionWithTitle:@"添加 Python HTTP 服务" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ServiceEditorViewController *editor=[ServiceEditorViewController new];[self.navigationController pushViewController:editor animated:YES];}]];[sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.firstObject;[self presentViewController:sheet animated:YES completion:nil];return;}
    ServiceEditorViewController *v = [ServiceEditorViewController new];
    [self.navigationController pushViewController:v animated:YES];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}
- (NSArray *)rows:(NSInteger)section {
    return section<self.sections.count?self.sections[section]:@[];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rows:section].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section==0?@"运行时活跃 · HTTP 状态单独检测":(section==1?@"启停结果待确认 · 可关闭后清理":@"已停止");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *s = [self rows:ip.section][ip.row];
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"service.session"];
    if(!c)c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"service.session"];
    c.backgroundColor = ip.section == 0 ? HostSuccessSurface() : HostCard();
    c.accessoryView=nil;c.accessoryType=UITableViewCellAccessoryNone;c.imageView.image=nil;c.selectionStyle=UITableViewCellSelectionStyleDefault;
    c.textLabel.text = s[@"name"];
    c.textLabel.textColor = HostText();
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@\nhttp://127.0.0.1:%@",
                                   ServiceEngineName(s),
                                   [s[@"builtin"] boolValue] ? @"内置服务" : @"本机脚本",
                                   [PyHost runtimeStatusDescriptionForServiceIdentifier:s[@"id"]],
                                   s[@"port"]];
    c.detailTextLabel.numberOfLines = 3;
    c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:@"terminal.fill"];
    c.imageView.tintColor = HostAccent();
    UISwitch *sw = [UISwitch new];
    sw.on = [PyHost isManagedServiceIdentifier:s[@"id"]];
    sw.onTintColor = HostAccent();
    sw.accessibilityIdentifier = s[@"id"];
    [sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
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
    v.onApplyService = self.onApplyService;
    v.onLog = self.onOpenLog;
    v.onSubscribe = self.onSubscribe;
    v.onBrowseService=self.onBrowseService;
    [self.navigationController pushViewController:v animated:YES];
}
@end
