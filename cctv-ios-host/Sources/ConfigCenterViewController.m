#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "ProfileStore.h"
#import "PyHost.h"
@interface ConfigCenterViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<NSDictionary *> *profiles;
@property(nonatomic, strong) UISearchController *search;
- (void)confirmRemoveProfile:(NSString *)source;
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
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 116;
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
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeStateDidChange) name:PyHostRuntimeStateDidChangeNotification object:nil];
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)runtimeStateDidChange {[self reloadProfiles];}
- (void)reloadProfiles {
    NSArray *all = self.profilesProvider ? self.profilesProvider() : @[];
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSArray *profiles =
        q.length
            ? [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,
                                                                                     NSDictionary *bindings) {
                     return [p[@"name"] lowercaseString] && [[p[@"name"] lowercaseString] containsString:q];
                   }]]
            : all;
    if([self.profiles isEqualToArray:profiles])return;self.profiles=profiles;
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
    c.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    c.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    c.textLabel.numberOfLines=0;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.detailTextLabel.numberOfLines = 4;
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
        NSTimeInterval updated=[p[@"updatedAt"] doubleValue];
        NSString *refreshInfo=@"尚无成功刷新记录";
        if(updated>0){NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"MM-dd HH:mm";refreshInfo=[NSString stringWithFormat:@"最近成功 %@",[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]];}
        c.detailTextLabel.text =
            [NSString stringWithFormat:@"%@ 个频道 · EPG %@\n%@ · %@", p[@"count"], p[@"epgStatus"]?:@"自动匹配", [p[@"source"] hasPrefix:@"local-playlist:"]?@"本机文件 · 长按可编辑、排序":([p[@"source"] length]?p[@"source"]:@"官方频道目录"),refreshInfo];
        c.imageView.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        if([p[@"type"] isEqual:@"plugin"]){c.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",p[@"runtime"],p[@"protocol"]];c.imageView.image=[UIImage systemImageNamed:@"curlybraces"];}
        UISwitch *s = [UISwitch new];
        s.onTintColor = HostAccent();
        s.on = [p[@"enabled"] boolValue];
        s.tag = ip.section-1;
        s.accessibilityLabel = [NSString stringWithFormat:@"启用 %@", p[@"name"]];
        [s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = s;
    }
    if(ip.section>0&&[self.profiles[ip.section-1][@"status"] length])c.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@",c.detailTextLabel.text?:@"",self.profiles[ip.section-1][@"status"]];
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
                            done(NO);
                            [self confirmRemoveProfile:source];
                          }];
    UIContextualAction *edit=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"编辑" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){if(self.onEditProfile)self.onEditProfile(source);done(YES);}];
    return [UISwipeActionsConfiguration configurationWithActions:@[a,edit]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.section==0||![self.profiles[ip.section-1][@"source"] length]||[self.profiles[ip.section-1][@"source"] hasPrefix:@"plugin:"])return nil;
    NSString *source=self.profiles[ip.section-1][@"source"];
    UIContextualAction *refresh=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"刷新" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){if(self.onRefreshProfile)self.onRefreshProfile(source);done(YES);}];
    refresh.backgroundColor=HostAccent();
    return [UISwipeActionsConfiguration configurationWithActions:@[refresh]];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(ip.section==0||![self.profiles[ip.section-1][@"source"] length])return nil;
    NSString *source=self.profiles[ip.section-1][@"source"];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:source previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        NSMutableArray *actions=[NSMutableArray arrayWithObject:[UIAction actionWithTitle:[source hasPrefix:@"plugin:"]?@"编辑资源":@"编辑配置与 EPG" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a){if(w.onEditProfile)w.onEditProfile(source);}]];
        if([source hasPrefix:@"plugin:"]){[actions addObject:[UIAction actionWithTitle:@"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];return [UIMenu menuWithTitle:@"资源操作" children:actions];}
        [actions addObject:[UIAction actionWithTitle:@"刷新此订阅" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshProfile)w.onRefreshProfile(source);}]];
        for(NSNumber *offset in @[@(-1),@1]){[actions addObject:[UIAction actionWithTitle:offset.integerValue<0?@"上移":@"下移" image:[UIImage systemImageNamed:offset.integerValue<0?@"arrow.up":@"arrow.down"] identifier:nil handler:^(UIAction *a){NSArray *sources=[w.profiles valueForKey:@"source"];sources=[sources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *s,NSDictionary *b){return s.length>0;}]];[ProfileStore move:source offset:offset.integerValue sources:sources];[w reloadProfiles];}]];}
        [actions addObject:[UIAction actionWithTitle:@"移除订阅" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];
        return [UIMenu menuWithTitle:@"订阅操作" children:actions];
    }];
}
- (void)confirmRemoveProfile:(NSString *)source {
    BOOL plugin=[source hasPrefix:@"plugin:"];
    NSString *message=plugin?@"这会从本机移除该服务配置和对应的资源代码。":"这会移除订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:plugin?@"移除资源？":@"移除订阅？" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:plugin?@"移除资源":@"移除订阅" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onDeleteProfile)self.onDeleteProfile(source);[self reloadProfiles];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return section>1?12:UITableViewAutomaticDimension;}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return 4;}
@end
