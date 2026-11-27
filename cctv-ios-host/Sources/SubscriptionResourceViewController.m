#import "SubscriptionResourceViewController.h"
#import "HostTheme.h"
#import "HostLogRedactor.h"
#import "ProfileStore.h"

@interface SubscriptionResourceViewController () <UIGestureRecognizerDelegate>
@property(nonatomic,strong) UITextField *nameField;
@property(nonatomic,strong) UITextField *urlField;
@property(nonatomic,strong) UITextField *epgField;
@property(nonatomic,copy) NSDictionary *snapshot;
@property(nonatomic,copy) NSDictionary *cachedProfile;
@property(nonatomic) BOOL editingResource;
@property(nonatomic) BOOL saving;
@property(nonatomic) BOOL refreshing;
@property(nonatomic) NSUInteger refreshGeneration;
@property(nonatomic) BOOL hasAppearedOnce;
@property(nonatomic) BOOL suppressMetadataReload;
@property(nonatomic,copy) NSString *notice;
@property(nonatomic,weak) id<UIGestureRecognizerDelegate> previousPopDelegate;
@property(nonatomic,strong) UIView *heroContainer;
@property(nonatomic,strong) UIView *heroCard;
@property(nonatomic,strong) UIView *heroSpecularLine;
@property(nonatomic,strong) UILabel *heroTitleLabel;
@property(nonatomic,strong) UILabel *heroKindBadge;
@property(nonatomic,strong) UILabel *heroSubtitleLabel;
@property(nonatomic,strong) NSArray<UIView *> *heroMetricPills;
@property(nonatomic,strong) NSArray<UILabel *> *heroMetricValues;
@property(nonatomic,strong) NSArray<UILabel *> *heroMetricTitles;
-  (void)changed;
-  (void)loadFields;
-  (void)updateAction;
-  (void)metadataChanged;
-  (void)buildHeroHeaderView;
-  (void)updateHeroSummary;
-  (void)showTransientPrompt:(NSString *)prompt;
-  (BOOL)beginRefreshActionWithPrompt:(NSString *)prompt;
-  (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section;
@end

@implementation SubscriptionResourceViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (UITextField *)field:(NSString *)placeholder allowPaste:(BOOL)allowPaste tag:(NSInteger)tag {
    UITextField *field=[UITextField new];field.placeholder=placeholder;field.textColor=HostText();field.tintColor=HostAccent();field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];field.adjustsFontForContentSizeCategory=YES;field.autocapitalizationType=UITextAutocapitalizationTypeNone;field.autocorrectionType=UITextAutocorrectionTypeNo;field.clearButtonMode=UITextFieldViewModeWhileEditing;[field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];[field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    if(allowPaste){
        UIButton *pasteBtn=[UIButton buttonWithType:UIButtonTypeSystem];
        pasteBtn.tag=tag;
        [pasteBtn setTitle:@"粘贴" forState:UIControlStateNormal];
        pasteBtn.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        pasteBtn.tintColor=HostAccent();
        pasteBtn.frame=CGRectMake(0,0,48,36);
        pasteBtn.backgroundColor=HostSelectedSurface();
        pasteBtn.layer.cornerRadius=10;
        pasteBtn.layer.cornerCurve=kCACornerCurveContinuous;
        HostInstallPressFeedback(pasteBtn);
        [pasteBtn addTarget:self action:@selector(pasteIntoField:) forControlEvents:UIControlEventTouchUpInside];
        field.rightView=pasteBtn;
        field.rightViewMode=UITextFieldViewModeUnlessEditing;
    }
    return field;
}
- (void)pasteIntoField:(UIButton *)sender {
    if(!self.editingResource||self.saving)return;
    NSString *clip=[UIPasteboard.generalPasteboard.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!clip.length)return;
    UITextField *target=sender.tag==1?self.urlField:self.epgField;
    if(!target.enabled)return;
    target.text=clip;
    [self changed];
}
- (void)buildHeroHeaderView {
    CGFloat width=MAX(320.0,self.view.bounds.size.width>0?self.view.bounds.size.width:375.0);
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,138)];
    container.backgroundColor=UIColor.clearColor;

    UIView *card=[UIView new];
    card.translatesAutoresizingMaskIntoConstraints=NO;
    card.backgroundColor=HostCard();
    card.layer.cornerRadius=16;
    card.layer.cornerCurve=kCACornerCurveContinuous;
    card.layer.borderWidth=0.8;
    HostSetLayerBorderColor(card,HostBorder());
    card.accessibilityIdentifier=@"subscription.hero.card";
    [container addSubview:card];

    UIView *spec=[UIView new];
    spec.translatesAutoresizingMaskIntoConstraints=NO;
    spec.backgroundColor=[UIColor colorWithWhite:1.0 alpha:0.12];
    spec.userInteractionEnabled=NO;
    [card addSubview:spec];

    UILabel *titleLbl=[UILabel new];
    titleLbl.translatesAutoresizingMaskIntoConstraints=NO;
    titleLbl.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    titleLbl.adjustsFontForContentSizeCategory=YES;
    titleLbl.textColor=HostText();
    titleLbl.lineBreakMode=NSLineBreakByTruncatingTail;
    [card addSubview:titleLbl];

    UILabel *kindBadge=[UILabel new];
    kindBadge.translatesAutoresizingMaskIntoConstraints=NO;
    kindBadge.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]];
    kindBadge.adjustsFontForContentSizeCategory=YES;
    kindBadge.textColor=HostAccent();
    kindBadge.backgroundColor=HostSelectedSurface();
    kindBadge.textAlignment=NSTextAlignmentCenter;
    kindBadge.layer.cornerRadius=8;
    kindBadge.layer.cornerCurve=kCACornerCurveContinuous;
    kindBadge.clipsToBounds=YES;
    [kindBadge setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [kindBadge setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [card addSubview:kindBadge];

    UILabel *subLbl=[UILabel new];
    subLbl.translatesAutoresizingMaskIntoConstraints=NO;
    subLbl.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    subLbl.adjustsFontForContentSizeCategory=YES;
    subLbl.textColor=HostSecondaryText();
    subLbl.lineBreakMode=NSLineBreakByTruncatingTail;
    [card addSubview:subLbl];

    UIStackView *grid=[UIStackView new];
    grid.translatesAutoresizingMaskIntoConstraints=NO;
    grid.axis=UILayoutConstraintAxisHorizontal;
    grid.distribution=UIStackViewDistributionFillEqually;
    grid.spacing=8;
    [card addSubview:grid];

    NSArray<NSString *> *titles=@[@"缓存频道",@"EPG 节目单",@"显示增强"];
    NSMutableArray<UIView *> *pills=[NSMutableArray arrayWithCapacity:3];
    NSMutableArray<UILabel *> *vals=[NSMutableArray arrayWithCapacity:3];
    NSMutableArray<UILabel *> *caps=[NSMutableArray arrayWithCapacity:3];
    for(NSString *t in titles){
        UIView *pill=[UIView new];
        pill.backgroundColor=HostRaisedSurface();
        pill.layer.cornerRadius=11;
        pill.layer.cornerCurve=kCACornerCurveContinuous;
        pill.layer.borderWidth=0.55;
        HostSetLayerBorderColor(pill,HostBorder());
        [pills addObject:pill];

        UILabel *v=[UILabel new];
        v.translatesAutoresizingMaskIntoConstraints=NO;
        v.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold]];
        v.adjustsFontForContentSizeCategory=YES;
        v.adjustsFontSizeToFitWidth=YES;
        v.minimumScaleFactor=0.75;
        v.textColor=HostText();
        v.textAlignment=NSTextAlignmentCenter;
        v.text=@"—";
        [pill addSubview:v];

        UILabel *c=[UILabel new];
        c.translatesAutoresizingMaskIntoConstraints=NO;
        c.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        c.adjustsFontForContentSizeCategory=YES;
        c.textColor=HostSecondaryText();
        c.textAlignment=NSTextAlignmentCenter;
        c.text=t;
        [pill addSubview:c];

        [NSLayoutConstraint activateConstraints:@[
            [v.topAnchor constraintEqualToAnchor:pill.topAnchor constant:7],
            [v.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:4],
            [v.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-4],
            [c.topAnchor constraintEqualToAnchor:v.bottomAnchor constant:2],
            [c.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:4],
            [c.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-4],
            [c.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-6]
        ]];
        [grid addArrangedSubview:pill];
        [vals addObject:v];
        [caps addObject:c];
    }

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
        [spec.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [spec.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [spec.topAnchor constraintEqualToAnchor:card.topAnchor],
        [spec.heightAnchor constraintEqualToConstant:0.5],
        [titleLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [titleLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [kindBadge.centerYAnchor constraintEqualToAnchor:titleLbl.centerYAnchor],
        [kindBadge.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLbl.trailingAnchor constant:8],
        [kindBadge.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [kindBadge.heightAnchor constraintEqualToConstant:22],
        [subLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:3],
        [subLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [subLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [grid.topAnchor constraintEqualToAnchor:subLbl.bottomAnchor constant:10],
        [grid.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [grid.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [grid.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-11]
    ]];

    self.heroContainer=container;
    self.heroCard=card;
    self.heroSpecularLine=spec;
    self.heroTitleLabel=titleLbl;
    self.heroKindBadge=kindBadge;
    self.heroSubtitleLabel=subLbl;
    self.heroMetricPills=pills;
    self.heroMetricValues=vals;
    self.heroMetricTitles=caps;
    self.tableView.tableHeaderView=container;
}
- (void)updateHeroSummary {
    if(!self.heroCard)return;
    NSDictionary *profile=self.cachedProfile?:@{};
    NSString *name=self.nameField.text.length?self.nameField.text:(profile[@"name"]?:(self.source.length?@"直播资源":@"央视直播 · 官方频道"));
    self.heroTitleLabel.text=name;
    NSString *kindText=!self.source.length?@"  官方内置  ":([self.source hasPrefix:@"local-playlist:"]?@"  本地列表  ":@"  HTTP 订阅  ");
    self.heroKindBadge.text=kindText;
    NSString *status=profile[@"status"]?:(self.source.length?@"等待检测或刷新":@"内置官方 · 实时就绪");
    self.heroSubtitleLabel.text=status;
    NSUInteger chCount=[profile[@"count"] unsignedIntegerValue];
    NSString *epgText=profile[@"epgStatus"]?:(self.source.length?@"自动匹配":@"官方");
    NSInteger enabledSwitches=([ProfileStore isChannelLogoEnabledForSource:self.source]?1:0)
        +([ProfileStore isPlayerCornerLogoEnabledForSource:self.source]?1:0)
        +([ProfileStore isChannelPreviewEnabledForSource:self.source]?1:0)
        +([ProfileStore isChannelTelemetryEnabledForSource:self.source]?1:0);
    NSArray<NSString *> *vals=@[
        [NSString stringWithFormat:@"%lu 台",(unsigned long)chCount],
        epgText,
        [NSString stringWithFormat:@"%ld / 4 项",(long)enabledSwitches]
    ];
    for(NSUInteger i=0;i<self.heroMetricValues.count&&i<vals.count;i++){
        UILabel *lbl=self.heroMetricValues[i];
        lbl.text=vals[i];
        if(i==0&&chCount>0)lbl.textColor=HostAccent();
        else if(i==2&&enabledSwitches>0)lbl.textColor=UIColor.systemGreenColor;
        else lbl.textColor=HostText();
    }
}
- (void)showTransientPrompt:(NSString *)prompt {
    self.navigationItem.prompt=prompt;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if([weakSelf.navigationItem.prompt isEqualToString:prompt])weakSelf.navigationItem.prompt=nil;
    });
}
- (void)handlePullRefresh {
    if(self.onRefresh&&[self beginRefreshActionWithPrompt:self.source.length?@"正在刷新订阅…":@"已同步内置官方频道"]){
        self.onRefresh();
    }
    [self loadFields];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"直播资源";self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=64;
    self.nameField=[self field:@"资源名称" allowPaste:NO tag:0];self.urlField=[self field:@"HTTP / HTTPS 订阅地址" allowPaste:YES tag:1];self.urlField.keyboardType=UIKeyboardTypeURL;self.epgField=[self field:@"留空使用列表提供的 EPG" allowPaste:YES tag:2];self.epgField.keyboardType=UIKeyboardTypeURL;self.editingResource=self.initiallyEditing;
    [self buildHeroHeaderView];
    [self loadFields];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(close)];[self updateAction];
    UIRefreshControl *rc=[UIRefreshControl new];
    [rc addTarget:self action:@selector(handlePullRefresh) forControlEvents:UIControlEventValueChanged];
    self.refreshControl=rc;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(metadataChanged) name:ProfileStoreMetadataDidChangeNotification object:nil];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    HostSizeTableHeaderToFit(self.tableView, 138.0);
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.nameField.textColor=HostText();self.nameField.tintColor=HostAccent();
    self.urlField.textColor=HostText();self.urlField.tintColor=HostAccent();
    self.epgField.textColor=HostText();self.epgField.tintColor=HostAccent();
    self.heroCard.backgroundColor=HostCard();HostSetLayerBorderColor(self.heroCard,HostBorder());
    self.heroTitleLabel.textColor=HostText();
    self.heroKindBadge.textColor=HostAccent();self.heroKindBadge.backgroundColor=HostSelectedSurface();
    self.heroSubtitleLabel.textColor=HostSecondaryText();
    for(UIView *pill in self.heroMetricPills){pill.backgroundColor=HostRaisedSurface();HostSetLayerBorderColor(pill,HostBorder());}
    for(UILabel *lbl in self.heroMetricTitles)lbl.textColor=HostSecondaryText();
    [self updateHeroSummary];
    [self.tableView reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self reloadThemeAppearance];
    }
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIGestureRecognizer *gesture=self.navigationController.interactivePopGestureRecognizer;
    if(gesture.delegate!=self)self.previousPopDelegate=gesture.delegate;
    gesture.delegate=self;
    if(self.hasAppearedOnce&&!self.editingResource){
        [self metadataChanged];
    }else if(!self.cachedProfile.count&&self.profileProvider){
        self.cachedProfile=self.profileProvider()?:@{};
        [self updateHeroSummary];
    }
    self.hasAppearedOnce=YES;
}
- (void)viewWillDisappear:(BOOL)animated {[super viewWillDisappear:animated];UIGestureRecognizer *gesture=self.navigationController.interactivePopGestureRecognizer;if(gesture.delegate==self)gesture.delegate=self.previousPopDelegate;}
- (NSDictionary *)values {return @{@"name":self.nameField.text?:@"",@"url":self.urlField.text?:@"",@"epg":self.epgField.text?:@""};}
- (void)refreshCachedProfile {
    self.cachedProfile=self.profileProvider?(self.profileProvider()?:@{}):@{};
}
// 刷新类动作（refresh/recheck/rematch/matchLogos）统一入口：
//  · loading 时防重复——refreshing/saving 中再点不第二次触发 on*；
//  · 不覆盖 self.notice——保留已有内联错误（如上次“刷新失败”或保存校验提示），
//    仅以导航栏瞬态提示反馈“刷新中…”，避免静默清除已有错误状态；
//  · on* 为 fire-and-forget 且未必回发元数据通知（如台标匹配），故加一个有界
//    兜底复位，防止刷新态被永久锁住；正常路径由 metadataChanged 解除。
- (BOOL)beginRefreshActionWithPrompt:(NSString *)prompt {
    if(self.refreshing||self.saving)return NO;
    self.refreshing=YES;
    NSUInteger gen=++self.refreshGeneration;
    if(prompt.length)[self showTransientPrompt:prompt];
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(10*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        SubscriptionResourceViewController *owner=weakSelf;if(!owner||!owner.refreshing||gen!=owner.refreshGeneration)return;
        owner.refreshing=NO;
        if(!owner.editingResource&&!owner.saving){[owner loadFields];if(owner.isViewLoaded)[owner.tableView reloadData];}
    });
    return YES;
}
- (void)loadFields {
    [self refreshCachedProfile];
    NSDictionary *metadata=[ProfileStore metadata:self.source],*profile=self.cachedProfile?:@{};
    self.nameField.text=metadata[@"name"]?:profile[@"name"]?:(self.source.length?@"直播资源":@"央视直播 · 官方频道");
    self.urlField.text=self.source?:@"";
    self.epgField.text=metadata[@"epgURL"]?:@"";
    self.snapshot=[self values];
    [self updateHeroSummary];
}
- (void)metadataChanged {
    if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf metadataChanged];});return;}
    if(self.editingResource||self.saving||self.suppressMetadataReload)return;
    if(self.refreshing)self.refreshing=NO;   // 任意元数据变更（刷新中/失败/已更新均回发通知）即解除防重复锁
    [self loadFields];
    if(self.isViewLoaded)[self.tableView reloadData];
}
- (void)updateAction {
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:self.editingResource?(self.saving?@"验证中…":@"保存"):@"编辑" style:UIBarButtonItemStyleDone target:self action:self.editingResource?@selector(save):@selector(beginEditing)];self.navigationItem.rightBarButtonItem.enabled=!self.saving&&(self.editingResource?![[self values] isEqual:self.snapshot]:self.source.length>0);
    self.nameField.enabled=self.editingResource&&!self.saving;self.urlField.enabled=self.editingResource&&!self.saving&&[ProfileStore isHTTP:self.source];self.epgField.enabled=self.editingResource&&!self.saving;
}
- (void)changed {self.notice=nil;[self updateAction];}
- (void)beginEditing {self.editingResource=YES;[self loadFields];[self updateAction];[self.tableView reloadData];}
- (void)save {
    if(self.saving)return;NSString *name=[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*url=[self.urlField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],*epg=[self.epgField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([ProfileStore isHTTP:self.source]){NSURLComponents *parts=[NSURLComponents componentsWithString:url];parts.scheme=parts.scheme.lowercaseString;parts.host=parts.host.lowercaseString;parts.fragment=nil;if(([parts.scheme isEqual:@"http"]&&parts.port.integerValue==80)||([parts.scheme isEqual:@"https"]&&parts.port.integerValue==443))parts.port=nil;url=parts.URL.absoluteString?:@"";}
    if(!name.length||([ProfileStore isHTTP:self.source]&&![ProfileStore isHTTP:url])||(epg.length&&![ProfileStore isHTTP:epg])){self.notice=@"请填写名称，并检查订阅或 EPG 的 HTTP / HTTPS 地址";[self.tableView reloadData];return;}if(!self.onCommit)return;
    [self.view endEditing:YES];self.saving=YES;[self updateAction];__weak typeof(self) weakSelf=self;
    self.onCommit(name,url,epg,^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{SubscriptionResourceViewController *owner=weakSelf;if(!owner)return;owner.saving=NO;if(error)owner.notice=error.code==NSURLErrorCancelled?@"验证已取消，原订阅未改变":error.localizedDescription;else{owner.source=url;owner.editingResource=NO;owner.notice=@"已保存";[owner loadFields];}[owner updateAction];[owner.tableView reloadData];});});
}
- (void)close {
    if(self.saving)return;if(self.editingResource&&![[self values] isEqual:self.snapshot]){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"有尚未保存的更改" message:nil preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"放弃更改" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[self.navigationController popViewControllerAnimated:YES];}]];[self presentViewController:alert animated:YES completion:nil];return;}[self.navigationController popViewControllerAnimated:YES];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {if(self.saving)return NO;if(self.editingResource&&![[self values] isEqual:self.snapshot]){[self close];return NO;}return YES;}
- (NSArray<NSDictionary *> *)managementRows {
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray arrayWithObjects:
        @{@"title":@"查看频道",@"detail":@"返回频道页并仅展示此订阅来源的直播台",@"icon":@"play.tv",@"action":@"open"},
        @{@"title":@"刷新此订阅",@"detail":@"重新拉取最新播放列表并更新本地缓存",@"icon":@"arrow.clockwise",@"action":@"refresh"},
        nil];
    if(self.onRecheckHealth)[rows addObject:@{@"title":@"重新检测健康",@"detail":@"检测订阅源连通性与首屏响应速度",@"icon":@"checkmark.shield",@"action":@"recheck"}];
    if(self.onRematchEPG)[rows addObject:@{@"title":@"重新匹配节目单（EPG）",@"detail":@"按频道标识重新关联 XMLTV 与官方节目单",@"icon":@"calendar.badge.clock",@"action":@"rematch"}];
    [rows addObject:@{@"title":@"智能匹配官方高清台标与节目单",@"detail":@"自动归一常见央视/卫视频道台标与 EPG",@"icon":@"sparkles.tv",@"action":@"matchLogos"}];
    [rows addObject:@{@"title":@"导出单项资源文件",@"detail":@"导出为可分享或备份的独立资源配置",@"icon":@"square.and.arrow.up",@"action":@"export"}];
    if(self.source.length)[rows addObject:@{@"title":@"配置本源 udpxy 网关",@"detail":@"为本订阅单独指定局域网 rtp/udp 转发网关（留空则用全局设置）",@"icon":@"network",@"action":@"udpxy"}];
    if(self.source.length)[rows addObject:@{@"title":@"复制订阅地址",@"detail":@"复制原始订阅链接到系统剪贴板",@"icon":@"doc.on.doc",@"action":@"copy"}];
    if(self.source.length&&self.onDelete)[rows addObject:@{@"title":@"移除此订阅",@"detail":@"删除此订阅源及其独有频道，不影响其他源",@"icon":@"trash",@"action":@"delete",@"destructive":@YES}];
    return rows;
}
- (void)applyInPlaceSwitchFeedbackForRow:(NSInteger)row detail:(NSString *)detail iconName:(NSString *)iconName {
    UITableViewCell *cell=[self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:1]];
    if(cell){
        cell.detailTextLabel.text=detail;
        if(iconName.length){
            cell.imageView.image=[UIImage systemImageNamed:iconName];
            cell.imageView.tintColor=HostAccent();
        }
        [cell setNeedsLayout];
    }
    [self updateHeroSummary];
    UITableViewHeaderFooterView *footer=[self.tableView footerViewForSection:0];
    if(footer.textLabel){
        footer.textLabel.text=[self tableView:self.tableView titleForFooterInSection:0];
        [footer setNeedsLayout];
    }else if(!cell){
        [self.tableView reloadData];
    }
}
- (void)toggleChannelLogoSwitch:(UISwitch *)sender {
    self.suppressMetadataReload=YES;
    [ProfileStore setChannelLogoEnabled:sender.isOn forSource:self.source];
    self.suppressMetadataReload=NO;
    self.notice = sender.isOn ? @"已开启此资源的频道列表与播放器台标" : @"已关闭此资源的台标显示";
    [self applyInPlaceSwitchFeedbackForRow:2
                                    detail:sender.isOn?@"已开启 · 在 CCTV 页与频道页显示该资源台标":@"已关闭 · 列表与网格仅显示文字台名"
                                  iconName:sender.isOn?@"photo.fill":@"photo"];
}
- (void)togglePlayerCornerLogoSwitch:(UISwitch *)sender {
    self.suppressMetadataReload=YES;
    [ProfileStore setPlayerCornerLogoEnabled:sender.isOn forSource:self.source];
    self.suppressMetadataReload=NO;
    self.notice = sender.isOn ? @"已开启此资源的播放器右上角台标" : @"已关闭此资源的播放器右上角台标";
    [self applyInPlaceSwitchFeedbackForRow:3
                                    detail:sender.isOn?@"已开启 · 播放时在画面右上角显示当前频道台标":@"已关闭 · 播放画面右上角不显示台标水印"
                                  iconName:sender.isOn?@"tv.inset.filled":@"tv"];
}
- (void)toggleChannelPreviewSwitch:(UISwitch *)sender {
    self.suppressMetadataReload=YES;
    [ProfileStore setChannelPreviewEnabled:sender.isOn forSource:self.source];
    self.suppressMetadataReload=NO;
    self.notice = sender.isOn ? @"已开启此资源的频道实时预览图" : @"已关闭此资源的频道实时预览图";
    [self applyInPlaceSwitchFeedbackForRow:4
                                    detail:sender.isOn?@"已开启 · 播放列表刷新时检测并展示频道最新真实画面":@"已关闭 · 仅展示纯色卡片与台标"
                                  iconName:sender.isOn?@"photo.on.rectangle.angled":@"rectangle.slash"];
}
- (void)toggleChannelTelemetrySwitch:(UISwitch *)sender {
    self.suppressMetadataReload=YES;
    [ProfileStore setChannelTelemetryEnabled:sender.isOn forSource:self.source];
    self.suppressMetadataReload=NO;
    self.notice = sender.isOn ? @"已开启此资源的频道速率与延迟显示" : @"已关闭此资源的频道速率与延迟显示";
    [self applyInPlaceSwitchFeedbackForRow:5
                                    detail:sender.isOn?@"已开启 · 在 CCTV 页与频道页展示每个台的实时速率与响应延迟":@"已关闭 · 不显示速率与延迟徽章"
                                  iconName:@"speedometer"];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?3:(section==1?6:self.managementRows.count);}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return @[@"资源配置",@"内容状态与显示增强",@"使用与管理"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section!=0)return nil;
    if(self.notice.length)return self.notice;
    // 无编辑/保存提示时，把订阅刷新失败状态作为内联错误透出，配合下方
    // “刷新此订阅”重试入口；刷新中/已合并/等待等非终态不被当作错误显示。
    NSString *status=[self.cachedProfile isKindOfClass:NSDictionary.class]?self.cachedProfile[@"status"]:nil;
    if([status isKindOfClass:NSString.class]&&status.length&&([status containsString:@"失败"]||[status containsString:@"异常"]||[status containsString:@"错误"]))return status;
    return @"修改订阅地址会先读取新清单，验证成功后替换。EPG 留空使用列表自动提供的地址。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *reuseID=(ip.section==0&&self.editingResource)?[NSString stringWithFormat:@"subscription.edit.%ld",(long)ip.row]:(ip.section==1&&ip.row>=2?[NSString stringWithFormat:@"subscription.switch.%ld",(long)ip.row]:@"subscription.subtitle.cell");
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:reuseID];
    if(!cell){
        cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    }
    for(UIView *sub in cell.contentView.subviews){
        if([sub isKindOfClass:UIStackView.class])[sub removeFromSuperview];
    }
    cell.accessoryView=nil;
    cell.accessoryType=UITableViewCellAccessoryNone;
    cell.imageView.image=nil;
    cell.detailTextLabel.text=nil;
    cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    cell.backgroundColor=HostCard();
    cell.layer.cornerRadius=14;
    cell.layer.cornerCurve=kCACornerCurveContinuous;
    cell.clipsToBounds=YES;
    cell.layer.borderWidth=0.6;
    HostSetLayerBorderColor(cell,HostBorder());
    cell.textLabel.textColor=HostText();
    cell.detailTextLabel.textColor=HostSecondaryText();
    cell.textLabel.numberOfLines=0;
    cell.detailTextLabel.numberOfLines=0;
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    if(!self.cachedProfile.count&&self.profileProvider){
        [self refreshCachedProfile];
    }
    NSDictionary *profile=self.cachedProfile?:@{};
    if(ip.section==0){
        NSString *rowTitle=@[@"名称",@"订阅来源",@"XMLTV / EPG"][ip.row];
        if(self.editingResource){
            cell.textLabel.text=nil;
            cell.detailTextLabel.text=nil;
            UITextField *field=@[self.nameField,self.urlField,self.epgField][ip.row];
            [field removeFromSuperview];
            field.accessibilityLabel=rowTitle;
            UILabel *label=[UILabel new];
            label.text=rowTitle;
            label.textColor=HostSecondaryText();
            label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            label.adjustsFontForContentSizeCategory=YES;
            label.numberOfLines=0;
            UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,field]];
            stack.translatesAutoresizingMaskIntoConstraints=NO;
            stack.axis=UILayoutConstraintAxisVertical;
            stack.alignment=UIStackViewAlignmentFill;
            stack.spacing=6;
            [cell.contentView addSubview:stack];
            [NSLayoutConstraint activateConstraints:@[
                [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
            ]];
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        }else{
            cell.textLabel.text=rowTitle;
            cell.imageView.image=[UIImage systemImageNamed:@[@"tag",@"link",@"calendar.badge.clock"][ip.row]];
            cell.imageView.tintColor=HostAccent();
            NSURL *url=[NSURL URLWithString:self.source];
            NSDictionary *meta=[ProfileStore metadata:self.source];
            NSString *epgURL=self.epgField.text.length?self.epgField.text:(meta[@"detectedEPGURL"]?:@"");
            cell.detailTextLabel.text=ip.row==0?self.nameField.text:(ip.row==1?(url.host.length?[NSString stringWithFormat:@"%@ · %@",url.host,url.lastPathComponent?:@""]:([self.source hasPrefix:@"local-playlist:"]?@"本地文件":@"官方频道目录")):(epgURL.length?[NSString stringWithFormat:@"已配置 EPG · %@",[HostLogRedactor redactText:epgURL]]:@"自动使用列表提供的 EPG"));
            if(ip.row>0&&self.source.length)cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
            else cell.selectionStyle=UITableViewCellSelectionStyleNone;
        }
    }
    else if(ip.section==1){
        if(ip.row==0){
            cell.textLabel.text=[NSString stringWithFormat:@"%@ 个缓存频道",profile[@"count"]?:@0];
            cell.detailTextLabel.text=profile[@"epgStatus"]?:@"EPG 自动匹配";
            cell.imageView.image=[UIImage systemImageNamed:@"tv"];
        }else if(ip.row==1){
            NSString *defaultStatus=self.source.length?@"尚未检查":@"内置官方 · 实时就绪";
            NSString *statusText=profile[@"status"]?:defaultStatus;
            cell.textLabel.text=statusText;
            NSTimeInterval updated=[profile[@"updatedAt"] doubleValue];
            if(updated>0){
                static NSDateFormatter *fmt;static dispatch_once_t once;
                dispatch_once(&once,^{fmt=[NSDateFormatter new];fmt.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];fmt.dateFormat=@"yyyy-MM-dd HH:mm";});
                NSString *timeStr=nil;@synchronized(fmt){timeStr=[fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]];}
                cell.detailTextLabel.text=[NSString stringWithFormat:@"最近成功刷新：%@",timeStr?:@""];
            }else{
                cell.detailTextLabel.text=self.source.length?@"尚无成功刷新时间记录":@"内置官方频道 · 实时同步";
            }
            BOOL hasWarn=([statusText containsString:@"失败"]||[statusText containsString:@"异常"]||[statusText containsString:@"超时"]);
            cell.imageView.image=[UIImage systemImageNamed:hasWarn?@"exclamationmark.triangle.fill":@"checkmark.shield"];
            cell.imageView.tintColor=hasWarn?UIColor.systemOrangeColor:UIColor.systemGreenColor;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
            return cell;
        }else if(ip.row==2){
            BOOL logoEnabled=[ProfileStore isChannelLogoEnabledForSource:self.source];
            cell.textLabel.text=@"频道列表与网格台标";
            cell.detailTextLabel.text=logoEnabled?@"已开启 · 在 CCTV 页与频道页显示该资源台标":@"已关闭 · 列表与网格仅显示文字台名";
            cell.imageView.image=[UIImage systemImageNamed:logoEnabled?@"photo.fill":@"photo"];
            UISwitch *toggle=[UISwitch new];
            toggle.onTintColor=HostAccent();
            toggle.on=logoEnabled;
            toggle.accessibilityIdentifier=@"subscription.logo.switch";
            toggle.accessibilityLabel=@"频道列表与网格台标";
            [toggle addTarget:self action:@selector(toggleChannelLogoSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
        }else if(ip.row==3){
            BOOL cornerEnabled=[ProfileStore isPlayerCornerLogoEnabledForSource:self.source];
            cell.textLabel.text=@"播放器右上角台标";
            cell.detailTextLabel.text=cornerEnabled?@"已开启 · 播放时在画面右上角显示当前频道台标":@"已关闭 · 播放画面右上角不显示台标水印";
            cell.imageView.image=[UIImage systemImageNamed:cornerEnabled?@"tv.inset.filled":@"tv"];
            UISwitch *toggle=[UISwitch new];
            toggle.onTintColor=HostAccent();
            toggle.on=cornerEnabled;
            toggle.accessibilityIdentifier=@"subscription.corner-logo.switch";
            toggle.accessibilityLabel=@"播放器右上角台标";
            [toggle addTarget:self action:@selector(togglePlayerCornerLogoSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
        }else if(ip.row==4){
            BOOL previewEnabled=[ProfileStore isChannelPreviewEnabledForSource:self.source];
            cell.textLabel.text=@"频道实时预览图";
            cell.detailTextLabel.text=previewEnabled?@"已开启 · 播放列表刷新时检测并展示频道最新真实画面":@"已关闭 · 仅展示纯色卡片与台标";
            cell.imageView.image=[UIImage systemImageNamed:previewEnabled?@"photo.on.rectangle.angled":@"rectangle.slash"];
            UISwitch *toggle=[UISwitch new];
            toggle.onTintColor=HostAccent();
            toggle.on=previewEnabled;
            toggle.accessibilityIdentifier=@"subscription.preview.switch";
            toggle.accessibilityLabel=@"频道实时预览图";
            [toggle addTarget:self action:@selector(toggleChannelPreviewSwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
        }else{
            BOOL telemetryEnabled=[ProfileStore isChannelTelemetryEnabledForSource:self.source];
            cell.textLabel.text=@"频道速率与延迟";
            cell.detailTextLabel.text=telemetryEnabled?@"已开启 · 在 CCTV 页与频道页展示每个台的实时速率与响应延迟":@"已关闭 · 不显示速率与延迟徽章";
            cell.imageView.image=[UIImage systemImageNamed:@"speedometer"];
            UISwitch *toggle=[UISwitch new];
            toggle.onTintColor=HostAccent();
            toggle.on=telemetryEnabled;
            toggle.accessibilityIdentifier=@"subscription.telemetry.switch";
            toggle.accessibilityLabel=@"频道速率与延迟";
            [toggle addTarget:self action:@selector(toggleChannelTelemetrySwitch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
        }
        cell.imageView.tintColor=HostAccent();
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else {
        NSArray<NSDictionary *> *rows=self.managementRows;
        if(ip.row>=0&&ip.row<(NSInteger)rows.count){
            NSDictionary *item=rows[ip.row];
            BOOL destructive=[item[@"destructive"] boolValue];
            cell.textLabel.text=item[@"title"];
            cell.detailTextLabel.text=item[@"detail"];
            cell.textLabel.textColor=destructive?UIColor.systemRedColor:HostAccent();
            cell.imageView.image=[UIImage systemImageNamed:item[@"icon"]];
            cell.imageView.tintColor=destructive?UIColor.systemRedColor:HostAccent();
            cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}
- (void)confirmDeleteSubscription {
    if(!self.source.length||!self.onDelete)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除此订阅？" message:@"这会移除该订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"移除订阅" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        SubscriptionResourceViewController *owner=weakSelf;
        if(!owner)return;
        if(owner.onDelete)owner.onDelete();
        [owner.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(self.saving||self.editingResource)return;
    if(ip.section==0&&ip.row>0){NSString *value=ip.row==1?self.source:([ProfileStore metadata:self.source][@"epgURL"]?:[ProfileStore metadata:self.source][@"detectedEPGURL"]);if(!value.length)return;UIAlertController *alert=[UIAlertController alertControllerWithTitle:ip.row==1?@"完整订阅地址":@"EPG 地址" message:value preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"复制完整地址" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){UIPasteboard.generalPasteboard.string=value;[self showTransientPrompt:@"完整地址已复制"];}]];[alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
    else if(ip.section==2){
        NSArray<NSDictionary *> *rows=self.managementRows;
        if(ip.row<0||ip.row>=(NSInteger)rows.count)return;
        NSString *action=rows[ip.row][@"action"];
        if([action isEqual:@"open"]){if(self.onOpen)self.onOpen();}
        else if([action isEqual:@"refresh"]){if(self.onRefresh&&[self beginRefreshActionWithPrompt:self.source.length?@"正在刷新订阅…":@"已同步内置官方频道与节目单"]){self.onRefresh();[self loadFields];[self.tableView reloadData];}}
        else if([action isEqual:@"recheck"]){if(self.onRecheckHealth&&[self beginRefreshActionWithPrompt:self.source.length?@"正在重新检测订阅健康状态…":@"内置官方频道健康状态正常"]){self.onRecheckHealth();[self loadFields];[self.tableView reloadData];}}
        else if([action isEqual:@"rematch"]){if(self.onRematchEPG&&[self beginRefreshActionWithPrompt:@"已发起节目单（EPG）重新匹配"]){self.onRematchEPG();[self loadFields];[self.tableView reloadData];}}
        else if([action isEqual:@"matchLogos"]){if(self.onMatchStationLogos&&[self beginRefreshActionWithPrompt:@"已完成官方高清台标与节目单归一匹配"]){self.onMatchStationLogos();self.refreshing=NO;[self loadFields];[self.tableView reloadData];}}
        else if([action isEqual:@"export"]){if(self.onExport)self.onExport();}
        else if([action isEqual:@"udpxy"]){
            NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.subscription.udpxy.v1"];
            NSString *current=[saved isKindOfClass:NSDictionary.class]?saved[self.source]:@"";
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"本源 udpxy 网关" message:@"例如 http://192.168.1.1:4022；留空将回退使用全局 udpxy 设置。" preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField *tf){tf.placeholder=@"http://192.168.1.1:4022";tf.text=current?:@"";tf.keyboardType=UIKeyboardTypeURL;tf.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            __weak typeof(self) weakSelf=self;
            __weak UIAlertController *weakAlert=alert;
            [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
                SubscriptionResourceViewController *owner=weakSelf;if(!owner||!owner.source.length)return;
                NSString *val=[weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]?:@"";
                NSMutableDictionary *map=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.subscription.udpxy.v1"] mutableCopy]?:[NSMutableDictionary dictionary];
                if(val.length)map[owner.source]=val;else [map removeObjectForKey:owner.source];
                [NSUserDefaults.standardUserDefaults setObject:map forKey:@"cctv.subscription.udpxy.v1"];
                [owner showTransientPrompt:val.length?@"已保存本源 udpxy 网关（刷新订阅后生效）":@"已清除本源 udpxy 网关"];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        }
        else if([action isEqual:@"copy"]){if(self.source.length){UIPasteboard.generalPasteboard.string=self.source;self.notice=@"订阅地址已复制到剪贴板";[self showTransientPrompt:self.notice];}}
        else if([action isEqual:@"delete"]){[self confirmDeleteSubscription];}
    }
}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(!cell||UIAccessibilityIsReduceMotionEnabled())return;
    [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{cell.transform=CGAffineTransformMakeScale(0.985,0.985);} completion:nil];
}
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(!cell)return;
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{cell.transform=CGAffineTransformIdentity;} completion:nil];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    (void)point;if(self.editingResource)return nil;
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];
    NSString *title=cell.textLabel.text?:@"";NSString *detail=cell.detailTextLabel.text?:@"";
    if(!title.length&&!detail.length)return nil;
    __weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:ip previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested){
        NSMutableArray<UIMenuElement *> *items=[NSMutableArray array];
        if(detail.length){
            [items addObject:[UIAction actionWithTitle:@"复制此项内容" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=detail;[weakSelf showTransientPrompt:@"已复制到剪贴板"];}]];
        }
        [items addObject:[UIAction actionWithTitle:@"复制完整键值" image:[UIImage systemImageNamed:@"list.clipboard"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=detail.length?[NSString stringWithFormat:@"%@：%@",title,detail]:title;[weakSelf showTransientPrompt:@"已复制到剪贴板"];}]];
        return [UIMenu menuWithTitle:title children:items];
    }];
}
@end
