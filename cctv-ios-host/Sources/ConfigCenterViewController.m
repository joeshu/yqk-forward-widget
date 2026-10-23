#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "PyHost.h"
@interface ConfigCenterViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<NSDictionary *> *profiles;
@property(nonatomic, strong) UISearchController *search;
@end
@implementation ConfigCenterViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"配置中心";
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 100;
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索配置";
    self.navigationItem.searchController = self.search;
    UIRefreshControl *r = [UIRefreshControl new];
    [r addTarget:self action:@selector(refreshProfiles) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = r;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(add)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(refreshProfiles)]
    ];
    [self reloadProfiles];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadProfiles];
}
- (void)reloadProfiles {
    NSArray *all = self.profilesProvider ? self.profilesProvider() : @[];
    NSString *q = self.search.searchBar.text.lowercaseString;
    self.profiles =
        q.length
            ? [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,
                                                                                     NSDictionary *bindings) {
                     return [p[@"name"] lowercaseString] && [[p[@"name"] lowercaseString] containsString:q];
                   }]]
            : all;
    [self.tableView reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self reloadProfiles];
}
- (void)add {
    if (self.onAdd)
        self.onAdd();
}
- (void)refreshProfiles {
    if (self.onRefresh)
        self.onRefresh();
    [self reloadProfiles];
    [self.refreshControl endRefreshing];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.profiles.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0)
        return @"本机";
    NSUInteger n = 0;
    for (NSDictionary *p in self.profiles)
        if ([p[@"enabled"] boolValue])
            n++;
    return [NSString stringWithFormat:@"共 %lu 项配置 · 已启用 %lu 项", (unsigned long)self.profiles.count,
                                      (unsigned long)n];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"profile"];
    if (!c)
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"profile"];
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 18;
    c.clipsToBounds = YES;
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 3;
    c.imageView.tintColor = HostAccent();
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (ip.section == 0) {
        c.textLabel.text = @"服务";
        c.detailTextLabel.text = PyHost.running ? @"Python 运行中 · 管理本机服务" : @"管理本机 Python 服务";
        c.imageView.image = [UIImage systemImageNamed:@"externaldrive"];
    } else {
        NSDictionary *p = self.profiles[ip.row];
        c.textLabel.text = p[@"name"];
        c.detailTextLabel.text =
            [NSString stringWithFormat:@"%@ 个频道   EPG\n%@", p[@"count"], p[@"source"] ?: @"官方频道目录"];
        c.imageView.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        UISwitch *s = [UISwitch new];
        s.onTintColor = HostAccent();
        s.on = [p[@"enabled"] boolValue];
        s.tag = ip.row;
        s.accessibilityLabel = [NSString stringWithFormat:@"启用 %@", p[@"name"]];
        [s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = s;
    }
    return c;
}
- (void)toggle:(UISwitch *)sender {
    if (sender.tag >= self.profiles.count)
        return;
    NSDictionary *p = self.profiles[sender.tag];
    if (self.onToggleProfile)
        self.onToggleProfile(p[@"source"], sender.on);
    [self reloadProfiles];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) {
        if (self.onServices)
            self.onServices();
    } else if (self.onSelectProfile)
        self.onSelectProfile(self.profiles[ip.row][@"source"]);
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 || ![self.profiles[ip.row][@"source"] length])
        return nil;
    NSString *source = self.profiles[ip.row][@"source"];
    UIContextualAction *a = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                            if (self.onDeleteProfile)
                                self.onDeleteProfile(source);
                            [self reloadProfiles];
                            done(YES);
                          }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ a ]];
}
@end
