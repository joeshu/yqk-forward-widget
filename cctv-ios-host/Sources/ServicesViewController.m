#import "ServicesViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "PyHost.h"
#import "ServiceEditorViewController.h"
#import "ServiceStore.h"
@interface ServiceDetailViewController : UITableViewController
@property(nonatomic, copy) NSDictionary *service;
@property(nonatomic, copy) void (^onToggle)(NSDictionary *, BOOL);
@property(nonatomic, copy) dispatch_block_t onLog;
@property(nonatomic, copy) void (^onSubscribe)(NSString *);
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *health;
@property(nonatomic, strong) NSURLSessionDataTask *probeTask;
@property(nonatomic, assign) BOOL probing;
@end
@implementation ServiceDetailViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.service[@"name"];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = 56;
    __weak typeof(self) w=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"pencil",@"title":@"编辑服务",@"action":[UIAction actionWithHandler:^(UIAction *a){[w edit];}]}])];
}
- (BOOL)running {
    return PyHost.running && [[ServiceStore activeIdentifier] isEqualToString:self.service[@"id"]];
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
    __weak typeof(self) w = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
                                                     [w.tableView reloadData];
                                                   }];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
    [self.probeTask cancel];
    self.probing = NO;
}
- (void)dealloc {
    [self.timer invalidate];
    [self.probeTask cancel];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0   ? 2
           : section == 1 ? 3
           : section == 2 ? 5
           : section == 3 ? 4
                          : ([self.service[@"builtin"] boolValue] ? 0 : 1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[ @"Python · 服务状态", @"本机访问", @"服务信息", @"操作", @"" ][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return @"本机一次运行一个服务。切换时自动停止旧服务；须等待后台线程和端口释放。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.backgroundColor = HostCard();
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.font = [UIFont systemFontOfSize:14];
    c.detailTextLabel.font = [UIFont systemFontOfSize:12];
    c.detailTextLabel.numberOfLines = 2;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = [self running] ? @"● 运行中" : @"● 已停止";
            c.textLabel.textColor = [self running] ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
            UISwitch *sw = [UISwitch new];
            sw.on = [self running];
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
        c.textLabel.text = @[ @"服务类型", @"代码来源", @"文件名称", @"上次更新", @"源地址" ][ip.row];
        NSDate *updated = [NSDate dateWithTimeIntervalSince1970:[self.service[@"updated"] doubleValue]];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        NSArray *values = @[
            @"Python",
            [self.service[@"builtin"] boolValue]
                ? @"内置"
                : ([self.service[@"url"] length] ? @"远程链接" : @"本地文件 / 代码"),
            [ServiceStore scriptPath:self.service].lastPathComponent ?: @"—",
            [self.service[@"updated"] doubleValue] > 0 ? [fmt stringFromDate:updated] : @"随应用更新",
            self.service[@"url"] ?: @"随应用提供"
        ];
        c.detailTextLabel.text = values[ip.row];
    } else if (ip.section == 3) {
        c.textLabel.text = @[ @"查看日志", @"编辑服务", @"查看 / 导出代码", @"添加到直播订阅" ][ip.row];
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
    [self.navigationController pushViewController:v animated:YES];
}
- (void)probe {
    if (self.probing)
        return;
    self.probing = YES;
    self.health = @"检测中…";
    [self.tableView reloadData];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self baseURL]]];
    r.timeoutInterval = 5;
    __weak typeof(self) w = self;
    self.probeTask = [NSURLSession.sharedSession
        dataTaskWithRequest:r
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              w.probing = NO;
              w.health = error ? error.localizedDescription
                               : [NSString stringWithFormat:@"GET / → HTTP %ld",
                                                            (long)[(NSHTTPURLResponse *)response statusCode]];
              [w.tableView reloadData];
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
                self.onLog();
        } else if (ip.row == 1)
            [self edit];
        else if (ip.row == 2) {
            UIAlertController *a =
                [UIAlertController alertControllerWithTitle:@"Python 代码"
                                                    message:nil
                                             preferredStyle:UIAlertControllerStyleActionSheet];
            [a addAction:[UIAlertAction
                             actionWithTitle:@"查看代码"
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *action) {
                                       ServiceCodeViewController *v = [ServiceCodeViewController new];
                                       v.path = [ServiceStore scriptPath:self.service];
                                       v.readOnly = YES;
                                       [self.navigationController pushViewController:v animated:YES];
                                     }]];
            [a addAction:[UIAlertAction
                             actionWithTitle:@"导出文件"
                                       style:UIAlertActionStyleDefault
                                     handler:^(UIAlertAction *action) {
                                       UIActivityViewController *v =
                                           [[UIActivityViewController alloc] initWithActivityItems:@[
                                               [NSURL fileURLWithPath:[ServiceStore scriptPath:self.service]]
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
            NSString *u = [[self baseURL] stringByAppendingString:@"/all.m3u"];
            if (self.onSubscribe)
                self.onSubscribe(u);
        }
    } else if (ip.section == 4) {
        if ([self running])
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
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) UISearchController *search;
@end
@implementation ServicesViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"服务";
    self.view.backgroundColor = UIColor.blackColor;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = UIColor.blackColor;
    self.table.rowHeight = 88;
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
        @{@"icon":@"doc.text",@"title":@"服务日志",@"action":[UIAction actionWithHandler:^(UIAction *a){if(w.onOpenLog)w.onOpenLog();}]}])];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索服务";
    self.navigationItem.searchController = self.search;
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
    __weak typeof(self) w = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
                                                     [w refresh];
                                                   }];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
}
- (void)dealloc {
    [self.timer invalidate];
}
- (void)refresh {
    NSArray *all = [ServiceStore services];
    NSString *q = self.search.searchBar.text.lowercaseString;
    self.services =
        q.length ? [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s,
                                                                                          NSDictionary *b) {
                          return [[s[@"name"] lowercaseString] containsString:q];
                        }]]
                 : all;
    [self.table reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self refresh];
}
- (void)add {
    ServiceEditorViewController *v = [ServiceEditorViewController new];
    [self.navigationController pushViewController:v animated:YES];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSArray *)rows:(NSInteger)section {
    return [self.services
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s, NSDictionary *b) {
          BOOL running = PyHost.running && [[ServiceStore activeIdentifier] isEqualToString:s[@"id"]];
          return section == 0 ? running : !running;
        }]];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self rows:section].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"运行中" : @"已关闭";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *s = [self rows:ip.section][ip.row];
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                reuseIdentifier:nil];
    c.backgroundColor =
        ip.section == 0 ? [UIColor colorWithRed:0.07 green:0.18 blue:0.13 alpha:1] : HostCard();
    c.textLabel.text = s[@"name"];
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    c.detailTextLabel.text =
        [NSString stringWithFormat:@"Python · %@\nhttp://127.0.0.1:%@",
                                   [s[@"builtin"] boolValue] ? @"内置服务" : @"本机脚本", s[@"port"]];
    c.detailTextLabel.numberOfLines = 2;
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = [UIImage systemImageNamed:@"terminal.fill"];
    c.imageView.tintColor = HostAccent();
    UISwitch *sw = [UISwitch new];
    sw.on = ip.section == 0;
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
    [self refresh];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    ServiceDetailViewController *v = [ServiceDetailViewController new];
    v.service = [self rows:ip.section][ip.row];
    v.onToggle = self.onToggleService;
    v.onLog = self.onOpenLog;
    v.onSubscribe = self.onSubscribe;
    [self.navigationController pushViewController:v animated:YES];
}
@end
