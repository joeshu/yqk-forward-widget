#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "ProfileStore.h"
#import "PyHost.h"
#import <math.h>
@interface ConfigCenterViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<NSDictionary *> *profiles;
@property(nonatomic, strong) NSArray<NSDictionary *> *allProfiles;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) UISegmentedControl *kindFilter;
@property(nonatomic, strong) UILabel *emptyLabel;
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
    self.kindFilter=[[UISegmentedControl alloc] initWithItems:@[@"全部",@"影视",@"直播",@"待处理"]];self.kindFilter.selectedSegmentIndex=0;[self.kindFilter addTarget:self action:@selector(kindChanged) forControlEvents:UIControlEventValueChanged];self.kindFilter.frame=CGRectMake(0,0,self.tableView.bounds.size.width,42);self.tableView.tableHeaderView=self.kindFilter;
    self.emptyLabel=[UILabel new];self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=UIColor.secondaryLabelColor;self.emptyLabel.numberOfLines=0;self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.tableView.backgroundView=self.emptyLabel;
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
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];CGRect frame=self.kindFilter.frame;if(fabs(frame.size.width-self.tableView.bounds.size.width)>0.5){frame.size.width=self.tableView.bounds.size.width;self.kindFilter.frame=frame;self.tableView.tableHeaderView=self.kindFilter;}}
- (void)reloadProfiles {
    NSArray *all = self.profilesProvider ? self.profilesProvider() : @[];
    self.allProfiles=all;
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSInteger kind=self.kindFilter.selectedSegmentIndex;
    NSArray *profiles=[all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,NSDictionary *bindings){
        NSString *name=[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"";NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";NSString *url=[p[@"url"] isKindOfClass:NSString.class]?p[@"url"]:@"";NSString *status=[p[@"status"] isKindOfClass:NSString.class]?p[@"status"]:@"";BOOL plugin=[p[@"type"] isEqual:@"plugin"],tvbox=[p[@"type"] isEqual:@"tvbox"],live=[p[@"resourceKind"] isEqual:@"live"],vod=[p[@"resourceKind"] isEqual:@"vod"],pending=[p[@"resourceKind"] isEqual:@"unknown"]||[status containsString:@"失败"]||[status containsString:@"异常"];
        if(kind==1 && !vod && ![p[@"resourceKind"] isEqual:@"both"])return NO;if(kind==2 && !live && ![p[@"resourceKind"] isEqual:@"both"])return NO;if(kind==3 && !pending)return NO;
        if(q.length && [name rangeOfString:q options:NSCaseInsensitiveSearch].location==NSNotFound && [source.lowercaseString rangeOfString:q].location==NSNotFound && [url.lowercaseString rangeOfString:q].location==NSNotFound)return NO;
    return plugin||tvbox||source.length>0||[p[@"native"] boolValue];
    }]];
    if([self.profiles isEqualToArray:profiles]){self.emptyLabel.text=profiles.count?@"":(q.length?@"没有匹配的资源\n清除搜索或更换筛选条件":@"还没有导入资源\n点击右上角 + 添加影视脚本、直播服务或订阅列表");return;}self.profiles=profiles;self.emptyLabel.text=profiles.count?@"":(q.length?@"没有匹配的资源\n清除搜索或更换筛选条件":@"还没有导入资源\n点击右上角 + 添加影视脚本、直播服务或订阅列表");
    [self.tableView reloadData];
}
- (void)kindChanged {[self reloadProfiles];}
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
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.profiles.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSUInteger enabledSubscriptions=0,runningServices=0,catalogs=0;
    for(NSDictionary *p in self.profiles){if([p[@"type"] isEqual:@"plugin"]){if([p[@"enabled"] boolValue])runningServices++;}else if([p[@"type"] isEqual:@"tvbox"])catalogs++;else if([p[@"enabled"] boolValue])enabledSubscriptions++;}
    return [NSString stringWithFormat:@"%lu 项资源 · %lu 个目录 · %lu 个订阅启用 · %lu 个服务运行中",(unsigned long)self.profiles.count,(unsigned long)catalogs,(unsigned long)enabledSubscriptions,(unsigned long)runningServices];
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
    c.detailTextLabel.numberOfLines = 0;
    c.imageView.tintColor = HostAccent();
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    {
        NSDictionary *p = self.profiles[ip.row];
        c.textLabel.text = p[@"name"];
        NSTimeInterval updated=[p[@"updatedAt"] doubleValue];
        NSString *refreshInfo=@"尚无成功刷新记录";
        if(updated>0){NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"MM-dd HH:mm";refreshInfo=[NSString stringWithFormat:@"最近成功 %@",[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]];}
        c.detailTextLabel.text =
            [NSString stringWithFormat:@"%@ 个频道 · EPG %@\n%@ · %@", p[@"count"], p[@"epgStatus"]?:@"自动匹配", [p[@"source"] hasPrefix:@"local-playlist:"]?@"本机文件 · 长按可编辑、排序":([p[@"source"] length]?p[@"source"]:@"官方频道目录"),refreshInfo];
        c.imageView.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        BOOL plugin=[p[@"type"] isEqual:@"plugin"],tvbox=[p[@"type"] isEqual:@"tvbox"];
        NSString *current=[p[@"current"] boolValue]?@"当前使用 · ":@"";
        if(plugin){NSString *kind=[p[@"resourceKind"] isEqual:@"live"]?@"直播服务":([p[@"resourceKind"] isEqual:@"vod"]?@"影视服务":([p[@"resourceKind"] isEqual:@"both"]?@"影视 / 直播服务":@"待识别能力"));c.detailTextLabel.text=[NSString stringWithFormat:@"%@%@ · %@ · %@",current,kind,p[@"runtime"]?:@"引擎未知",p[@"status"]?:@"未启动"];c.imageView.image=[UIImage systemImageNamed:[p[@"resourceKind"] isEqual:@"live"]?@"dot.radiowaves.left.and.right":@"play.rectangle"];}else if(tvbox){c.detailTextLabel.text=[NSString stringWithFormat:@"%@TVBox 配置 · %@ 个可用站点 · %@ 个直播列表",current,p[@"supportedCount"]?:@0,p[@"liveCount"]?:@0];c.imageView.image=[UIImage systemImageNamed:@"square.stack.3d.up"];}else{c.detailTextLabel.text=[NSString stringWithFormat:@"%@%@",current,c.detailTextLabel.text?:@""];UISwitch *s=[UISwitch new];s.onTintColor=HostAccent();s.on=[p[@"enabled"] boolValue];s.tag=ip.row;s.accessibilityLabel=[NSString stringWithFormat:@"加入频道 %@",p[@"name"]];[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}
        if(plugin||tvbox){__weak typeof(self) weakSelf=self;NSString *source=p[@"source"]?:@"";UIAction *manage=[UIAction actionWithTitle:tvbox?@"打开站点与直播列表":@"资源能力与设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(tvbox){if(weakSelf.onOpenTVBoxCatalog)weakSelf.onOpenTVBoxCatalog([source substringFromIndex:6]);}else if(weakSelf.onOpenResource)weakSelf.onOpenResource(source);}];UIAction *remove=[UIAction actionWithTitle:tvbox?@"移除 TVBox 目录":@"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[weakSelf confirmRemoveProfile:source];}];UIButton *more=[UIButton buttonWithType:UIButtonTypeSystem];more.frame=CGRectMake(0,0,36,36);[more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];more.menu=[UIMenu menuWithChildren:@[manage,remove]];more.showsMenuAsPrimaryAction=YES;more.accessibilityLabel=@"更多资源操作";c.accessoryView=more;}
    }
    if([self.profiles[ip.row][@"status"] length] && ![self.profiles[ip.row][@"type"] isEqual:@"plugin"] && ![self.profiles[ip.row][@"type"] isEqual:@"tvbox"])c.detailTextLabel.text=[NSString stringWithFormat:@"%@\n%@",c.detailTextLabel.text?:@"",self.profiles[ip.row][@"status"]];
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
    NSDictionary *profile=self.profiles[ip.row];NSString *source=profile[@"source"]?:@"";
    if([profile[@"type"] isEqual:@"plugin"]){NSString *kind=profile[@"resourceKind"];if(self.onUseResource && ![kind isEqual:@"unknown"])self.onUseResource(source,[kind isEqual:@"both"]?@"choose":kind);else if(self.onOpenResource)self.onOpenResource(source);}
    else if([profile[@"type"] isEqual:@"tvbox"]){if(self.onOpenTVBoxCatalog)self.onOpenTVBoxCatalog([source substringFromIndex:6]);}
    else if(self.onSelectProfile)self.onSelectProfile(source);
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (![self.profiles[ip.row][@"source"] length] || [self.profiles[ip.row][@"type"] isEqual:@"plugin"] || [self.profiles[ip.row][@"type"] isEqual:@"tvbox"])
        return nil;
    NSString *source = self.profiles[ip.row][@"source"];
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
    if(![self.profiles[ip.row][@"source"] length]||[self.profiles[ip.row][@"type"] isEqual:@"plugin"]||[self.profiles[ip.row][@"type"] isEqual:@"tvbox"])return nil;
    NSString *source=self.profiles[ip.row][@"source"];
    UIContextualAction *refresh=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"刷新" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){if(self.onRefreshProfile)self.onRefreshProfile(source);done(YES);}];
    refresh.backgroundColor=HostAccent();
    return [UISwipeActionsConfiguration configurationWithActions:@[refresh]];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(![self.profiles[ip.row][@"source"] length]||[self.profiles[ip.row][@"type"] isEqual:@"tvbox"])return nil;
    NSString *source=self.profiles[ip.row][@"source"];__weak typeof(self) w=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:source previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        NSMutableArray *actions=[NSMutableArray arrayWithObject:[UIAction actionWithTitle:[source hasPrefix:@"plugin:"]?@"编辑资源":@"编辑配置与 EPG" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a){if(w.onEditProfile)w.onEditProfile(source);}]];
        if([source hasPrefix:@"plugin:"]){[actions addObject:[UIAction actionWithTitle:@"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];return [UIMenu menuWithTitle:@"资源操作" children:actions];}
        [actions addObject:[UIAction actionWithTitle:@"刷新此订阅" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshProfile)w.onRefreshProfile(source);}]];
        for(NSNumber *offset in @[@(-1),@1]){[actions addObject:[UIAction actionWithTitle:offset.integerValue<0?@"上移":@"下移" image:[UIImage systemImageNamed:offset.integerValue<0?@"arrow.up":@"arrow.down"] identifier:nil handler:^(UIAction *a){NSArray *sources=[w.allProfiles valueForKey:@"source"];sources=[sources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *s,NSDictionary *b){return s.length>0;}]];[ProfileStore move:source offset:offset.integerValue sources:sources];[w reloadProfiles];}]];}
        [actions addObject:[UIAction actionWithTitle:@"移除订阅" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];
        return [UIMenu menuWithTitle:@"订阅操作" children:actions];
    }];
}
- (void)confirmRemoveProfile:(NSString *)source {
    BOOL plugin=[source hasPrefix:@"plugin:"],tvbox=[source hasPrefix:@"tvbox:"];
    NSString *message=plugin?@"这会从本机移除该服务配置和对应的资源代码。":(tvbox?@"这会移除 TVBox 目录；已导入的脚本和直播订阅会保留。":@"这会移除订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。");
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:tvbox?@"移除 TVBox 目录？":(plugin?@"移除资源？":@"移除订阅？") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:tvbox?@"移除目录":(plugin?@"移除资源":@"移除订阅") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onDeleteProfile)self.onDeleteProfile(source);[self reloadProfiles];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return UITableViewAutomaticDimension;}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return 4;}
@end
