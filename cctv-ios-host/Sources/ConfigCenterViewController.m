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
@property(nonatomic, strong) UIScrollView *kindScroll;
@property(nonatomic, strong) UIStackView *kindStack;
@property(nonatomic, copy) NSString *selectedKind;
@property(nonatomic, strong) UILabel *emptyLabel;
- (void)confirmRemoveProfile:(NSString *)source;
- (void)selectKind:(UIButton *)sender;
- (void)updateKindFilters;
@end
@implementation ConfigCenterViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"资源";
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 116;
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜索资源";
    self.navigationItem.searchController = self.search;
    self.selectedKind=@"all";
    UIView *filterHeader=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),52)];
    self.kindScroll=[UIScrollView new];self.kindScroll.translatesAutoresizingMaskIntoConstraints=NO;self.kindScroll.showsHorizontalScrollIndicator=NO;self.kindScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.kindStack=[UIStackView new];self.kindStack.translatesAutoresizingMaskIntoConstraints=NO;self.kindStack.axis=UILayoutConstraintAxisHorizontal;self.kindStack.spacing=8;[self.kindScroll addSubview:self.kindStack];[filterHeader addSubview:self.kindScroll];
    [NSLayoutConstraint activateConstraints:@[[self.kindScroll.leadingAnchor constraintEqualToAnchor:filterHeader.leadingAnchor constant:10],[self.kindScroll.trailingAnchor constraintEqualToAnchor:filterHeader.trailingAnchor],[self.kindScroll.topAnchor constraintEqualToAnchor:filterHeader.topAnchor constant:4],[self.kindScroll.bottomAnchor constraintEqualToAnchor:filterHeader.bottomAnchor constant:-4],[self.kindStack.leadingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.leadingAnchor],[self.kindStack.trailingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.trailingAnchor constant:-10],[self.kindStack.topAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.topAnchor],[self.kindStack.bottomAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.bottomAnchor],[self.kindStack.heightAnchor constraintEqualToAnchor:self.kindScroll.frameLayoutGuide.heightAnchor]]];
    self.tableView.tableHeaderView=filterHeader;
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
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];UIView *header=self.tableView.tableHeaderView;if(header&&fabs(header.frame.size.width-self.tableView.bounds.size.width)>0.5){CGRect frame=header.frame;frame.size.width=self.tableView.bounds.size.width;header.frame=frame;self.tableView.tableHeaderView=header;}}
- (BOOL)profile:(NSDictionary *)profile matchesKind:(NSString *)kind {
    NSString *resourceKind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"unknown";
    NSString *status=[profile[@"status"] isKindOfClass:NSString.class]?profile[@"status"]:@"";
    BOOL pending=[resourceKind isEqual:@"unknown"]||[status containsString:@"失败"]||[status containsString:@"异常"]||[status containsString:@"错误"];
    if([kind isEqual:@"all"])return YES;
    if([kind isEqual:@"vod"])return [resourceKind isEqual:@"vod"]||[resourceKind isEqual:@"both"];
    if([kind isEqual:@"live"])return [resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"];
    if([kind isEqual:@"catalog"])return [profile[@"type"] isEqual:@"tvbox"];
    if([kind isEqual:@"script"])return [profile[@"type"] isEqual:@"plugin"];
    if([kind isEqual:@"attention"])return pending;
    return YES;
}
- (void)updateKindFilters {
    if(!self.kindStack)return;
    NSArray *definitions=@[@{@"id":@"all",@"name":@"全部"},@{@"id":@"vod",@"name":@"影视"},@{@"id":@"live",@"name":@"直播"},@{@"id":@"catalog",@"name":@"目录"},@{@"id":@"script",@"name":@"脚本"},@{@"id":@"attention",@"name":@"待检查"}];
    for(UIView *view in self.kindStack.arrangedSubviews.copy){[self.kindStack removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSDictionary *definition in definitions){NSString *identifier=definition[@"id"];NSUInteger count=[[self.allProfiles filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *profile,NSDictionary *bindings){return [self profile:profile matchesKind:identifier];}]] count];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.accessibilityIdentifier=[@"resource-filter-" stringByAppendingString:identifier];button.accessibilityLabel=[NSString stringWithFormat:@"%@，%lu 项",definition[@"name"],(unsigned long)count];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];HostStylePillButton(button,[identifier isEqual:self.selectedKind]);[button setTitle:[NSString stringWithFormat:@"%@ %lu",definition[@"name"],(unsigned long)count] forState:UIControlStateNormal];[button addTarget:self action:@selector(selectKind:) forControlEvents:UIControlEventTouchUpInside];[self.kindStack addArrangedSubview:button];}
}
- (void)selectKind:(UIButton *)sender {NSString *kind=[sender.accessibilityIdentifier stringByReplacingOccurrencesOfString:@"resource-filter-" withString:@""];if(!kind.length||[kind isEqual:self.selectedKind])return;self.selectedKind=kind;[self reloadProfiles];}
- (void)reloadProfiles {
    NSArray *all = self.profilesProvider ? self.profilesProvider() : @[];
    self.allProfiles=all;
    [self updateKindFilters];
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSArray *profiles=[all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,NSDictionary *bindings){
        NSString *name=[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"";NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";NSString *url=[p[@"url"] isKindOfClass:NSString.class]?p[@"url"]:@"";
        if(![self profile:p matchesKind:self.selectedKind?:@"all"])return NO;
        if(q.length && [name rangeOfString:q options:NSCaseInsensitiveSearch].location==NSNotFound && [source.lowercaseString rangeOfString:q].location==NSNotFound && [url.lowercaseString rangeOfString:q].location==NSNotFound)return NO;
        return [p[@"type"] isEqual:@"plugin"]||[p[@"type"] isEqual:@"tvbox"]||source.length>0||[p[@"native"] boolValue];
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
    return [NSString stringWithFormat:@"显示 %lu / %lu 项 · %lu 个目录 · %lu 个订阅启用 · %lu 个服务运行中",(unsigned long)self.profiles.count,(unsigned long)self.allProfiles.count,(unsigned long)catalogs,(unsigned long)enabledSubscriptions,(unsigned long)runningServices];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"profile"];
    if (!c)
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"profile"];
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 18;
    c.clipsToBounds = YES;
    c.textLabel.textColor = HostText();
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
        if(plugin){NSString *kind=[p[@"resourceKind"] isEqual:@"live"]?@"直播服务":([p[@"resourceKind"] isEqual:@"vod"]?@"影视服务":([p[@"resourceKind"] isEqual:@"both"]?@"影视 / 直播服务":@"待识别能力"));c.detailTextLabel.text=[NSString stringWithFormat:@"%@%@ · %@ · %@",current,kind,p[@"runtime"]?:@"引擎未知",p[@"status"]?:@"未启动"];c.imageView.image=[UIImage systemImageNamed:[p[@"resourceKind"] isEqual:@"live"]?@"dot.radiowaves.left.and.right":@"play.rectangle"];}else if(tvbox){BOOL macCMS=[p[@"catalogKind"] isEqual:@"maccms"];NSString *catalogTitle=macCMS?@"MacCMS 接口目录":@"TVBox 配置";c.detailTextLabel.text=[NSString stringWithFormat:@"%@%@ · %@ 个可用影视接口 · %@ 个直播列表",current,catalogTitle,p[@"supportedCount"]?:@0,p[@"liveCount"]?:@0];c.imageView.image=[UIImage systemImageNamed:macCMS?@"film":@"square.stack.3d.up"];}else{c.detailTextLabel.text=[NSString stringWithFormat:@"%@%@",current,c.detailTextLabel.text?:@""];UISwitch *s=[UISwitch new];s.onTintColor=HostAccent();s.on=[p[@"enabled"] boolValue];s.tag=ip.row;s.accessibilityLabel=[NSString stringWithFormat:@"加入频道 %@",p[@"name"]];[s addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}
        if(plugin||tvbox){__weak typeof(self) weakSelf=self;NSString *source=p[@"source"]?:@"";BOOL macCMS=[p[@"catalogKind"] isEqual:@"maccms"];UIAction *manage=[UIAction actionWithTitle:tvbox?(macCMS?@"打开影视接口":@"打开站点与直播列表"):@"资源能力与设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(tvbox){if(weakSelf.onOpenTVBoxCatalog)weakSelf.onOpenTVBoxCatalog([source substringFromIndex:6]);}else if(weakSelf.onOpenResource)weakSelf.onOpenResource(source);}];UIAction *remove=[UIAction actionWithTitle:tvbox?(macCMS?@"移除影视接口目录":@"移除 TVBox 目录"):@"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[weakSelf confirmRemoveProfile:source];}];UIButton *more=[UIButton buttonWithType:UIButtonTypeSystem];more.frame=CGRectMake(0,0,36,36);[more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];more.menu=[UIMenu menuWithChildren:@[manage,remove]];more.showsMenuAsPrimaryAction=YES;more.accessibilityLabel=@"更多资源操作";if(plugin){UISwitch *running=[UISwitch new];running.onTintColor=HostAccent();running.on=[p[@"enabled"] boolValue];running.tag=ip.row;running.accessibilityLabel=[NSString stringWithFormat:@"%@服务",running.isOn?@"停止":@"启动"];[running addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];UIStackView *actions=[[UIStackView alloc] initWithArrangedSubviews:@[running,more]];actions.axis=UILayoutConstraintAxisHorizontal;actions.alignment=UIStackViewAlignmentCenter;actions.spacing=4;c.accessoryView=actions;}else c.accessoryView=more;}
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
    BOOL macCMS=NO;for(NSDictionary *profile in self.profiles)if([profile[@"source"] isEqual:source]){macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];break;}
    NSString *message=plugin?@"这会从本机移除该服务配置和对应的资源代码。":(tvbox?@"这会移除 TVBox 目录；已导入的脚本和直播订阅会保留。":@"这会移除订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。");
    if(tvbox&&macCMS)message=@"这会移除 MacCMS 接口目录；其他脚本、影视来源和直播订阅会保留。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:tvbox?(macCMS?@"移除 MacCMS 接口目录？":@"移除 TVBox 目录？"):(plugin?@"移除资源？":@"移除订阅？") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:tvbox?(macCMS?@"移除接口目录":@"移除目录"):(plugin?@"移除资源":@"移除订阅") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onDeleteProfile)self.onDeleteProfile(source);[self reloadProfiles];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return UITableViewAutomaticDimension;}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return 4;}
@end
