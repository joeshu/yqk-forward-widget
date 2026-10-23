#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "ProfileStore.h"
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
    self.title = @"资源";
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 100;
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索资源";
    self.navigationItem.searchController = self.search;
    UIRefreshControl *r = [UIRefreshControl new];
    [r addTarget:self action:@selector(refreshProfiles) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = r;
    __weak typeof(self) w=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"arrow.clockwise",@"title":@"刷新资源",@"action":[UIAction actionWithHandler:^(UIAction *a){[w refreshProfiles];}]},
        @{@"icon":@"plus",@"title":@"导入资源",@"action":[UIAction actionWithHandler:^(UIAction *a){[w add];}]},
        @{@"icon":@"ellipsis",@"title":@"资源操作",@"menu":[UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"脚本与服务" image:[UIImage systemImageNamed:@"hand.tap"] identifier:nil handler:^(UIAction *a){if(w.onServices)w.onServices();}]]]}])];
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
    return self.profiles.count+1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0)
        return @"脚本资源";
    if(section>1)return nil;
    NSUInteger n = 0;
    for (NSDictionary *p in self.profiles)
        if ([p[@"enabled"] boolValue])
            n++;
    return [NSString stringWithFormat:@"共 %lu 项资源 · 已启用 %lu 项", (unsigned long)self.profiles.count,
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
        c.textLabel.text = @"脚本与服务";
        c.detailTextLabel.text = PyHost.running ? @"Python 运行中 · 管理本机服务" : @"管理本机 Python 服务";
        c.imageView.image = [UIImage systemImageNamed:@"externaldrive"];
    } else {
        NSDictionary *p = self.profiles[ip.section-1];
        c.textLabel.text = p[@"name"];
        c.detailTextLabel.text =
            [NSString stringWithFormat:@"%@ 个频道 · EPG %@\n%@", p[@"count"], p[@"epgStatus"]?:@"自动匹配", [p[@"source"] hasPrefix:@"local-playlist:"]?@"本机文件 · 长按可编辑、排序":([p[@"source"] length]?p[@"source"]:@"官方频道目录")];
        c.imageView.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        UISwitch *s = [UISwitch new];
        s.onTintColor = HostAccent();
        s.on = [p[@"enabled"] boolValue];
        s.tag = ip.section-1;
        s.accessibilityLabel = [NSString stringWithFormat:@"启用 %@", p[@"name"]];
        [s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = s;
    }
    if(ip.section==1&&[self.profiles[ip.section-1][@"status"] length])c.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@",c.detailTextLabel.text?:@"",self.profiles[ip.section-1][@"status"]];
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
        self.onSelectProfile(self.profiles[ip.section-1][@"source"]);
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0 || ![self.profiles[ip.section-1][@"source"] length])
        return nil;
    NSString *source = self.profiles[ip.section-1][@"source"];
    UIContextualAction *a = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                            if (self.onDeleteProfile)
                                self.onDeleteProfile(source);
                            [self reloadProfiles];
                            done(YES);
                          }];
    UIContextualAction *edit=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"编辑" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){if(self.onEditProfile)self.onEditProfile(source);done(YES);}];
    return [UISwipeActionsConfiguration configurationWithActions:@[a,edit]];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(ip.section==0||![self.profiles[ip.section-1][@"source"] length])return nil;
    NSString *source=self.profiles[ip.section-1][@"source"];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:source previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        NSMutableArray *actions=[NSMutableArray arrayWithObject:[UIAction actionWithTitle:@"编辑配置与 EPG" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a){if(w.onEditProfile)w.onEditProfile(source);}]];
        for(NSNumber *offset in @[@(-1),@1]){[actions addObject:[UIAction actionWithTitle:offset.integerValue<0?@"上移":@"下移" image:[UIImage systemImageNamed:offset.integerValue<0?@"arrow.up":@"arrow.down"] identifier:nil handler:^(UIAction *a){NSArray *sources=[w.profiles valueForKey:@"source"];sources=[sources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *s,NSDictionary *b){return s.length>0;}]];[ProfileStore move:source offset:offset.integerValue sources:sources];[w reloadProfiles];}]];}
        return [UIMenu menuWithTitle:@"资源操作" children:actions];
    }];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return section>1?12:UITableViewAutomaticDimension;}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return 4;}
@end
