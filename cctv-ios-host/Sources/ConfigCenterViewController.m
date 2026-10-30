#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "ProfileStore.h"
#import "PyHost.h"
#import <math.h>
@interface ConfigCenterViewController () <UITextFieldDelegate>
@property(nonatomic, strong) NSArray<NSDictionary *> *profiles;
@property(nonatomic, strong) NSArray<NSDictionary *> *allProfiles;
@property(nonatomic, strong) UIScrollView *kindScroll;
@property(nonatomic, strong) UIStackView *kindStack;
@property(nonatomic, strong) UIView *resourceHeader;
@property(nonatomic, strong) UIStackView *topActionsStack;
@property(nonatomic, strong) UILabel *resourceTitleLabel;
@property(nonatomic, strong) UITextField *resourceSearchField;
@property(nonatomic, copy) NSString *searchQuery;
@property(nonatomic, strong) NSLayoutConstraint *kindScrollHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *resourceHeaderTopConstraint;
@property(nonatomic, copy) NSString *selectedKind;
@property(nonatomic, strong) UILabel *emptyLabel;
- (void)confirmRemoveProfile:(NSString *)source;
- (void)selectKind:(UIButton *)sender;
- (void)searchTextChanged;
- (BOOL)textFieldShouldReturn:(UITextField *)textField;
- (void)refreshHomeContent;
- (void)updateKindFilters;
- (UISwitch *)compactSwitchForRow:(NSInteger)row enabled:(BOOL)enabled label:(NSString *)label;
- (UIView *)switchAccessoryForSwitch:(UISwitch *)toggle width:(CGFloat)width;
@end
@implementation ConfigCenterViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"";
    self.tableView.backgroundColor = HostBackground();
    self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 116;
    self.selectedKind=@"all";
    self.resourceHeader=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),220)];
    self.resourceHeader.backgroundColor=HostBackground();

    self.topActionsStack=[UIStackView new];self.topActionsStack.translatesAutoresizingMaskIntoConstraints=NO;self.topActionsStack.axis=UILayoutConstraintAxisHorizontal;self.topActionsStack.alignment=UIStackViewAlignmentCenter;self.topActionsStack.distribution=UIStackViewDistributionFillEqually;self.topActionsStack.spacing=0;self.topActionsStack.backgroundColor=HostRaisedSurface();self.topActionsStack.layer.cornerRadius=23;self.topActionsStack.layer.cornerCurve=kCACornerCurveContinuous;self.topActionsStack.layer.borderWidth=.7;HostSetLayerBorderColor(self.topActionsStack,HostBorder());[self.resourceHeader addSubview:self.topActionsStack];
    NSArray *actions=@[@{ @"icon":@"arrow.clockwise", @"label":@"刷新资源", @"selector":NSStringFromSelector(@selector(refreshProfiles)) },@{ @"icon":@"plus", @"label":@"添加资源", @"selector":NSStringFromSelector(@selector(add)) },@{ @"icon":@"play.rectangle", @"label":@"更新影视首页内容", @"selector":NSStringFromSelector(@selector(refreshHomeContent)) }];
    for(NSDictionary *item in actions){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityLabel=item[@"label"];button.accessibilityIdentifier=[@"resource-action." stringByAppendingString:item[@"label"]];UIButtonConfiguration *config=[UIButtonConfiguration plainButtonConfiguration];config.image=[UIImage systemImageNamed:item[@"icon"]];config.baseForegroundColor=HostText();config.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);button.configuration=config;HostInstallPressFeedback(button);SEL selector=NSSelectorFromString(item[@"selector"]);[button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];[self.topActionsStack addArrangedSubview:button];[button.widthAnchor constraintEqualToConstant:44].active=YES;[button.heightAnchor constraintEqualToConstant:44].active=YES;}
    UIButton *moreButton=[UIButton buttonWithType:UIButtonTypeSystem];moreButton.translatesAutoresizingMaskIntoConstraints=NO;moreButton.accessibilityLabel=@"更多资源操作";moreButton.accessibilityIdentifier=@"resource-action.more";UIButtonConfiguration *moreConfig=[UIButtonConfiguration plainButtonConfiguration];moreConfig.image=[UIImage systemImageNamed:@"ellipsis"];moreConfig.baseForegroundColor=HostText();moreConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);moreButton.configuration=moreConfig;HostInstallPressFeedback(moreButton);[moreButton.widthAnchor constraintEqualToConstant:44].active=YES;[moreButton.heightAnchor constraintEqualToConstant:44].active=YES;__weak typeof(self) weakSelf=self;UIAction *servicesAction=[UIAction actionWithTitle:@"脚本与服务" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *action){[weakSelf openServices];}];UIAction *importAction=[UIAction actionWithTitle:@"导入资源" image:[UIImage systemImageNamed:@"plus"] identifier:nil handler:^(UIAction *action){[weakSelf add];}];moreButton.menu=[UIMenu menuWithChildren:@[servicesAction,importAction]];moreButton.showsMenuAsPrimaryAction=YES;[self.topActionsStack addArrangedSubview:moreButton];

    self.resourceTitleLabel=[UILabel new];self.resourceTitleLabel.translatesAutoresizingMaskIntoConstraints=NO;self.resourceTitleLabel.text=@"资源";self.resourceTitleLabel.textColor=HostText();self.resourceTitleLabel.font=[UIFont systemFontOfSize:34 weight:UIFontWeightBold];self.resourceTitleLabel.adjustsFontForContentSizeCategory=YES;[self.resourceHeader addSubview:self.resourceTitleLabel];
    self.resourceSearchField=[UITextField new];self.resourceSearchField.translatesAutoresizingMaskIntoConstraints=NO;self.resourceSearchField.accessibilityIdentifier=@"resource-search-field";self.resourceSearchField.accessibilityLabel=@"搜索资源";self.resourceSearchField.placeholder=@"搜索资源";self.resourceSearchField.clearButtonMode=UITextFieldViewModeWhileEditing;self.resourceSearchField.returnKeyType=UIReturnKeySearch;self.resourceSearchField.delegate=self;self.resourceSearchField.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.resourceSearchField.adjustsFontForContentSizeCategory=YES;self.resourceSearchField.textColor=HostText();self.resourceSearchField.tintColor=HostAccent();self.resourceSearchField.backgroundColor=HostRaisedSurface();self.resourceSearchField.layer.cornerRadius=14;self.resourceSearchField.layer.cornerCurve=kCACornerCurveContinuous;self.resourceSearchField.leftViewMode=UITextFieldViewModeAlways;UIView *searchIconContainer=[[UIView alloc] initWithFrame:CGRectMake(0,0,38,44)];UIImageView *searchIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];searchIcon.tintColor=HostMutedText();searchIcon.frame=CGRectMake(12,13,18,18);searchIconContainer.userInteractionEnabled=NO;[searchIconContainer addSubview:searchIcon];self.resourceSearchField.leftView=searchIconContainer;[self.resourceSearchField addTarget:self action:@selector(searchTextChanged) forControlEvents:UIControlEventEditingChanged];[self.resourceHeader addSubview:self.resourceSearchField];

    self.kindScroll=[UIScrollView new];self.kindScroll.translatesAutoresizingMaskIntoConstraints=NO;self.kindScroll.showsHorizontalScrollIndicator=NO;self.kindScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.kindStack=[UIStackView new];self.kindStack.translatesAutoresizingMaskIntoConstraints=NO;self.kindStack.axis=UILayoutConstraintAxisHorizontal;self.kindStack.spacing=8;[self.kindScroll addSubview:self.kindStack];[self.resourceHeader addSubview:self.kindScroll];
    self.kindScrollHeightConstraint=[self.kindScroll.heightAnchor constraintEqualToConstant:48];
    self.resourceHeaderTopConstraint=[self.topActionsStack.topAnchor constraintEqualToAnchor:self.resourceHeader.topAnchor constant:8];
    [NSLayoutConstraint activateConstraints:@[self.resourceHeaderTopConstraint,[self.topActionsStack.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-16],[self.topActionsStack.widthAnchor constraintEqualToConstant:176],[self.topActionsStack.heightAnchor constraintEqualToConstant:44],[self.resourceTitleLabel.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.resourceTitleLabel.topAnchor constraintEqualToAnchor:self.topActionsStack.bottomAnchor constant:8],[self.resourceTitleLabel.heightAnchor constraintGreaterThanOrEqualToConstant:42],[self.resourceSearchField.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.resourceSearchField.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-20],[self.resourceSearchField.topAnchor constraintEqualToAnchor:self.resourceTitleLabel.bottomAnchor constant:6],[self.resourceSearchField.heightAnchor constraintEqualToConstant:44],[self.kindScroll.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:10],[self.kindScroll.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor],[self.kindScroll.topAnchor constraintEqualToAnchor:self.resourceSearchField.bottomAnchor constant:12],[self.kindScroll.bottomAnchor constraintEqualToAnchor:self.resourceHeader.bottomAnchor constant:-6],self.kindScrollHeightConstraint,[self.kindStack.leadingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.leadingAnchor],[self.kindStack.trailingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.trailingAnchor constant:-10],[self.kindStack.topAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.topAnchor],[self.kindStack.bottomAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.bottomAnchor],[self.kindStack.heightAnchor constraintEqualToAnchor:self.kindScroll.frameLayoutGuide.heightAnchor]]];
    self.tableView.tableHeaderView=self.resourceHeader;
    self.tableView.contentInset=UIEdgeInsetsMake(0,0,78,0);self.tableView.scrollIndicatorInsets=UIEdgeInsetsMake(0,0,78,0);
    self.emptyLabel=[UILabel new];self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=UIColor.secondaryLabelColor;self.emptyLabel.numberOfLines=0;self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.tableView.backgroundView=self.emptyLabel;
    UIRefreshControl *r = [UIRefreshControl new];
    [r addTarget:self action:@selector(refreshProfiles) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = r;
    __weak typeof(self) w=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"arrow.clockwise",@"title":@"刷新资源",@"action":[UIAction actionWithHandler:^(UIAction *a){[w refreshProfiles];}]},
        @{@"icon":@"plus",@"title":@"导入资源",@"action":[UIAction actionWithHandler:^(UIAction *a){[w add];}]},
        @{@"icon":@"play.rectangle",@"title":@"更新影视首页内容",@"action":[UIAction actionWithHandler:^(UIAction *a){if(w.onRefreshMediaHome)w.onRefreshMediaHome();}]}
    ])];
    [self reloadProfiles];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadProfiles];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self updateResourceHeaderLayout];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeStateDidChange) name:PyHostRuntimeStateDidChangeNotification object:nil];
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)runtimeStateDidChange {[self reloadProfiles];}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateResourceHeaderLayout];
}
- (void)updateResourceHeaderLayout {
    UIView *header=self.resourceHeader;
    CGFloat width=CGRectGetWidth(self.tableView.bounds);
    if(!header||width<=0)return;
    self.resourceHeaderTopConstraint.constant=MAX(0,self.view.safeAreaInsets.top)+8;
    // UITableView caches tableHeaderView's frame independently from its Auto
    // Layout subtree. Re-measure after every width/safe-area change and assign
    // the header back even when its width is unchanged, so returning from a
    // pushed page cannot keep a stale clipped header height.
    header.frame=CGRectMake(0,0,width,MAX(1,CGRectGetHeight(header.frame)));
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize fitting=[header systemLayoutSizeFittingSize:CGSizeMake(width,UIViewNoIntrinsicMetric)
                         withHorizontalFittingPriority:UILayoutPriorityRequired
                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat measured=ceil(fitting.height);
    if(measured>0&&fabs(CGRectGetHeight(header.frame)-measured)>0.5){CGRect frame=header.frame;frame.size.height=measured;header.frame=frame;}
    if(self.tableView.tableHeaderView!=header||fabs(CGRectGetWidth(self.tableView.tableHeaderView.frame)-width)>0.5||fabs(CGRectGetHeight(self.tableView.tableHeaderView.frame)-CGRectGetHeight(header.frame))>0.5)self.tableView.tableHeaderView=header;
}
- (BOOL)profile:(NSDictionary *)profile matchesKind:(NSString *)kind {
    NSString *resourceKind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"unknown";
    NSString *status=[profile[@"status"] isKindOfClass:NSString.class]?profile[@"status"]:@"";
    NSString *playlistStatus=[profile[@"subscriptionStatus"] isKindOfClass:NSString.class]?profile[@"subscriptionStatus"]:@"";
    BOOL pending=[resourceKind isEqual:@"unknown"]||[status containsString:@"失败"]||[status containsString:@"异常"]||[status containsString:@"错误"]||[playlistStatus containsString:@"失败"]||[playlistStatus containsString:@"异常"]||[playlistStatus containsString:@"错误"];
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
    NSArray *definitions=@[@{@"id":@"all",@"name":@"全部"},@{@"id":@"vod",@"name":@"影视"},@{@"id":@"live",@"name":@"直播"},@{@"id":@"catalog",@"name":@"合集"},@{@"id":@"script",@"name":@"脚本"},@{@"id":@"attention",@"name":@"待检查"}];
    for(UIView *view in self.kindStack.arrangedSubviews.copy){[self.kindStack removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSDictionary *definition in definitions){NSString *identifier=definition[@"id"];NSUInteger count=[[self.allProfiles filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *profile,NSDictionary *bindings){return [self profile:profile matchesKind:identifier];}]] count];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.accessibilityIdentifier=[@"resource-filter-" stringByAppendingString:identifier];button.accessibilityLabel=[NSString stringWithFormat:@"%@，%lu 项",definition[@"name"],(unsigned long)count];button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;HostStylePillButton(button,[identifier isEqual:self.selectedKind]);button.contentEdgeInsets=UIEdgeInsetsMake(7,12,7,12);button.layer.cornerRadius=16;[button setTitle:[NSString stringWithFormat:@"%@ %lu",definition[@"name"],(unsigned long)count] forState:UIControlStateNormal];[button addTarget:self action:@selector(selectKind:) forControlEvents:UIControlEventTouchUpInside];[self.kindStack addArrangedSubview:button];}
    UIButton *firstFilter=(UIButton *)self.kindStack.arrangedSubviews.firstObject;CGFloat pillHeight=MAX(42,ceil(firstFilter.titleLabel.font.lineHeight+14));self.kindScrollHeightConstraint.constant=pillHeight;[self.resourceHeader setNeedsLayout];[self updateResourceHeaderLayout];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection&&![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory])[self updateKindFilters];
}
- (void)selectKind:(UIButton *)sender {NSString *kind=[sender.accessibilityIdentifier stringByReplacingOccurrencesOfString:@"resource-filter-" withString:@""];if(!kind.length||[kind isEqual:self.selectedKind])return;self.selectedKind=kind;[self reloadProfiles];}
- (void)reloadProfiles {
    NSArray *all = self.profilesProvider ? self.profilesProvider() : @[];
    self.allProfiles=all;
    [self updateKindFilters];
    NSArray *profiles=[all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,NSDictionary *bindings){
        NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
        if(![self profile:p matchesKind:self.selectedKind?:@"all"])return NO;
        NSString *query=self.searchQuery?:@"";if(query.length&&![[p description].lowercaseString containsString:query])return NO;
        return [p[@"type"] isEqual:@"plugin"]||[p[@"type"] isEqual:@"tvbox"]||source.length>0||[p[@"native"] boolValue];
    }]];
    if([self.profiles isEqualToArray:profiles]){self.emptyLabel.text=profiles.count?@"":@"还没有导入资源\n点顶部“添加”导入影视脚本、直播服务或订阅列表";return;}self.profiles=profiles;self.emptyLabel.text=profiles.count?@"":@"还没有导入资源\n点顶部“添加”导入影视脚本、直播服务或订阅列表";
    [self.tableView reloadData];
}
- (void)kindChanged {[self reloadProfiles];}
- (void)searchTextChanged {self.searchQuery=self.resourceSearchField.text.lowercaseString?:@"";[self reloadProfiles];}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {[textField resignFirstResponder];return YES;}
- (void)refreshHomeContent {if(self.onRefreshMediaHome)self.onRefreshMediaHome();}
- (void)add {
    if (self.onAdd)
        self.onAdd();
}
- (void)openServices { if(self.onServices)self.onServices(); }
- (void)refreshProfiles {
    if (self.onRefresh)
        self.onRefresh();
    [self reloadProfiles];
    [self.refreshControl endRefreshing];
}
- (UISwitch *)compactSwitchForRow:(NSInteger)row enabled:(BOOL)enabled label:(NSString *)label {
    UISwitch *toggle=[UISwitch new];toggle.onTintColor=HostAccent();toggle.on=enabled;toggle.tag=row;toggle.accessibilityLabel=label;[toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];return toggle;
}
- (UIView *)switchAccessoryForSwitch:(UISwitch *)toggle width:(CGFloat)width {
    UIView *accessory=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,44)];accessory.isAccessibilityElement=NO;toggle.frame=CGRectMake((width-51)/2,6.5,51,31);toggle.transform=CGAffineTransformMakeScale(.88,.88);[accessory addSubview:toggle];return accessory;
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
    return [NSString stringWithFormat:@"%lu 项 · %lu 个合集 · %lu 个订阅启用 · %lu 个服务运行中",(unsigned long)self.profiles.count,(unsigned long)catalogs,(unsigned long)enabledSubscriptions,(unsigned long)runningServices];
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
        if(plugin){
            NSString *kind=[p[@"resourceKind"] isEqual:@"live"]?@"直播服务":([p[@"resourceKind"] isEqual:@"vod"]?@"影视服务":([p[@"resourceKind"] isEqual:@"both"]?@"影视 / 直播服务":@"待识别能力"));
            NSMutableArray *lines=[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@%@ · %@ · %@",current,kind,p[@"runtime"]?:@"引擎未知",p[@"status"]?:@"未启动"]];
            if([p[@"subscriptionURL"] length]){
                [lines addObject:[NSString stringWithFormat:@"清单：%@ · %@ 个频道",p[@"subscriptionStatus"]?:@"待检测",p[@"channelCount"]?:@0]];
                NSTimeInterval last=[p[@"playlistUpdatedAt"] doubleValue];if(last>0){NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"MM-dd HH:mm";[lines addObject:[NSString stringWithFormat:@"最近成功：%@",[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:last]]]];}
                [lines addObject:[NSString stringWithFormat:@"订阅：%@",p[@"subscriptionURL"]]];
            }
            if([p[@"epgURL"] length])[lines addObject:[NSString stringWithFormat:@"节目单：%@",p[@"epgURL"]]];
            c.detailTextLabel.text=[lines componentsJoinedByString:@"\n"];
            c.imageView.image=[UIImage systemImageNamed:[p[@"resourceKind"] isEqual:@"live"]?@"dot.radiowaves.left.and.right":@"play.rectangle"];
        }else if(tvbox){
            BOOL macCMS=[p[@"catalogKind"] isEqual:@"maccms"];NSString *catalogTitle=macCMS?@"MacCMS 影视接口":@"资源合集";
            c.detailTextLabel.text=macCMS?[NSString stringWithFormat:@"%@%@ · 选中后浏览 · 仅请求当前接口",current,catalogTitle]:[NSString stringWithFormat:@"%@%@ · %lu 个站点 · %lu 个可用 · %lu 个直播列表",current,catalogTitle,(unsigned long)[p[@"siteCount"] unsignedIntegerValue],(unsigned long)[p[@"supportedCount"] unsignedIntegerValue],(unsigned long)[p[@"liveCount"] unsignedIntegerValue]];
            c.imageView.image=[UIImage systemImageNamed:macCMS?@"film":@"square.stack.3d.up"];
        }else{
            c.detailTextLabel.text=[NSString stringWithFormat:@"%@%@",current,c.detailTextLabel.text?:@""];
            UISwitch *s=[self compactSwitchForRow:ip.row enabled:[p[@"enabled"] boolValue] label:[NSString stringWithFormat:@"加入频道 %@",p[@"name"]?:@"订阅"]];c.accessoryView=[self switchAccessoryForSwitch:s width:56];
        }
        if(plugin||tvbox){
            __weak typeof(self) weakSelf=self;NSString *source=p[@"source"]?:@"";BOOL macCMS=[p[@"catalogKind"] isEqual:@"maccms"];
            UIAction *manage=[UIAction actionWithTitle:tvbox?(macCMS?@"打开影视接口":@"打开资源合集"): @"资源能力与设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(tvbox){if(weakSelf.onOpenTVBoxCatalog)weakSelf.onOpenTVBoxCatalog([source substringFromIndex:6]);}else if(weakSelf.onOpenResource)weakSelf.onOpenResource(source);}];
            NSMutableArray<UIAction *> *menuActions=[NSMutableArray arrayWithObject:manage];
            if(plugin&&self.onUseResource){NSString *resourceKind=p[@"resourceKind"];if([resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"])[menuActions addObject:[UIAction actionWithTitle:@"添加直播频道" image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"] identifier:nil handler:^(UIAction *a){if(weakSelf.onUseResource)weakSelf.onUseResource(source,@"live");}]];if([resourceKind isEqual:@"vod"]||[resourceKind isEqual:@"both"])[menuActions addObject:[UIAction actionWithTitle:@"进入影视" image:[UIImage systemImageNamed:@"film"] identifier:nil handler:^(UIAction *a){if(weakSelf.onUseResource)weakSelf.onUseResource(source,@"vod");}]];}
            UIAction *remove=[UIAction actionWithTitle:tvbox?(macCMS?@"移除影视接口":@"移除资源合集"): @"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[weakSelf confirmRemoveProfile:source];}];[menuActions addObject:remove];
            UIButton *more=[UIButton buttonWithType:UIButtonTypeSystem];more.frame=CGRectMake(0,0,36,36);[more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];more.menu=[UIMenu menuWithChildren:menuActions];more.showsMenuAsPrimaryAction=YES;more.accessibilityLabel=@"更多资源操作";more.accessibilityIdentifier=[NSString stringWithFormat:@"resource-more-%ld",(long)ip.row];more.tintColor=HostSecondaryText();more.backgroundColor=HostNeutralSurface();more.layer.cornerRadius=12;more.layer.cornerCurve=kCACornerCurveContinuous;more.layer.borderWidth=.6;HostSetLayerBorderColor(more,HostBorder());HostInstallPressFeedback(more);
            if(plugin){BOOL runningState=[p[@"enabled"] boolValue];UISwitch *running=[self compactSwitchForRow:ip.row enabled:runningState label:[NSString stringWithFormat:@"%@服务，%@",p[@"name"]?:@"脚本",runningState?@"停止":@"启动"]];UIView *actions=[[UIView alloc] initWithFrame:CGRectMake(0,0,96,44)];actions.isAccessibilityElement=NO;running.frame=CGRectMake(0,6.5,51,31);running.transform=CGAffineTransformMakeScale(.88,.88);[actions addSubview:running];more.frame=CGRectMake(58,4,36,36);[actions addSubview:more];c.accessoryView=actions;}else c.accessoryView=more;
        }
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
    if([p[@"type"] isEqual:@"plugin"])return;
    [self reloadProfiles];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *profile=self.profiles[ip.row];NSString *source=profile[@"source"]?:@"";
    if([profile[@"type"] isEqual:@"plugin"]){if(self.onOpenResource)self.onOpenResource(source);}
    else if([profile[@"type"] isEqual:@"tvbox"]){if(self.onOpenTVBoxCatalog)self.onOpenTVBoxCatalog([source substringFromIndex:6]);}
    else {
        UIAlertController *actions=[UIAlertController alertControllerWithTitle:profile[@"name"]?:@"订阅" message:source.length?source:nil preferredStyle:UIAlertControllerStyleActionSheet];
        if(self.onSelectProfile)[actions addAction:[UIAlertAction actionWithTitle:@"打开频道" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onSelectProfile(source);}]];
        if(source.length&&self.onEditProfile)[actions addAction:[UIAlertAction actionWithTitle:@"编辑订阅与节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onEditProfile(source);}]];
        if(source.length&&self.onRefreshProfile)[actions addAction:[UIAlertAction actionWithTitle:@"刷新此订阅" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onRefreshProfile(source);}]];
        [actions addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];actions.popoverPresentationController.sourceView=cell?:self.view;actions.popoverPresentationController.sourceRect=cell?cell.bounds:CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);[self presentViewController:actions animated:YES completion:nil];
    }
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
    NSString *message=plugin?@"这会从本机移除该服务配置和对应的资源代码。":(tvbox?@"这会移除资源合集；已导入的脚本和直播订阅会保留。":@"这会移除订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。");
    if(tvbox&&macCMS)message=@"这会移除 MacCMS 影视接口；其他脚本、影视来源和直播订阅会保留。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:tvbox?(macCMS?@"移除 MacCMS 影视接口？":@"移除资源合集？"):(plugin?@"移除资源？":@"移除订阅？") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:tvbox?(macCMS?@"移除接口":@"移除合集"):(plugin?@"移除资源":@"移除订阅") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onDeleteProfile)self.onDeleteProfile(source);[self reloadProfiles];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return UITableViewAutomaticDimension;}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return 4;}
@end
