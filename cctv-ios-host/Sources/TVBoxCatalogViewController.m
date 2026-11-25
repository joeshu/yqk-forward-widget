#import "TVBoxCatalogViewController.h"
#import "HostEmptyStateView.h"
#import "TVBoxCatalogStore.h"
#import "HostTheme.h"
#import "HostGlassActionSheetViewController.h"
#import "HostLogRedactor.h"
#import "HostToolbar.h"
#import "PyHost.h"

@interface TVBoxCatalogViewController () <UISearchResultsUpdating>
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,copy) NSString *searchText;
@property(nonatomic,strong) UISegmentedControl *contentFilter;
@property(nonatomic,strong) UIView *headerCardView;
@property(nonatomic,strong) UILabel *summaryLabel;
- (void)pullRefreshCatalog:(UIRefreshControl *)sender;
- (void)updateHeaderLayoutIfNeeded;
@property(nonatomic,copy) NSArray *cachedFilteredSites;
@property(nonatomic,copy) NSArray *cachedFilteredLives;
@property(nonatomic,assign) NSInteger cachedFilterScope;
@property(nonatomic,copy) NSString *cachedFilterQuery;
@property(nonatomic) NSUInteger alertPresentationGeneration;
@property(nonatomic,copy) dispatch_block_t pendingAlertRetry;
- (void)rebuildFilteredCatalogCache;
- (void)showTransientPrompt:(NSString *)prompt;
- (void)updateEmptyState;
- (void)updateCatalogSummary;
- (void)presentCatalogAlert:(UIAlertController *)alert sourceView:(nullable UIView *)sourceView sourceRect:(CGRect)sourceRect;
- (void)attemptPresentCatalogAlert:(UIAlertController *)alert sourceView:(nullable UIView *)sourceView sourceRect:(CGRect)sourceRect retryCount:(NSUInteger)retryCount generation:(NSUInteger)generation;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip;
@end

@implementation TVBoxCatalogViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];self.alertPresentationGeneration++;
    if(self.pendingAlertRetry){dispatch_block_cancel(self.pendingAlertRetry);self.pendingAlertRetry=nil;}
}
- (NSArray *)sites { return [self.catalog[@"sites"] isKindOfClass:NSArray.class]?self.catalog[@"sites"]:@[]; }
- (NSArray *)lives { return [self.catalog[@"lives"] isKindOfClass:NSArray.class]?self.catalog[@"lives"]:@[]; }
- (void)rebuildFilteredCatalogCache {
    NSString *query=[[self.searchText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString]?:@"";
    NSInteger scope=self.contentFilter?self.contentFilter.selectedSegmentIndex:0;
    NSArray *(^filterSection)(NSArray *, NSInteger) = ^NSArray *(NSArray *rows, NSInteger section){
        if((scope==1&&section==1)||(scope==2&&section==0))return @[];
        NSArray *cur=rows;
        if(scope==3)cur=[cur filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return ![row[@"supported"] boolValue];}]];
        if(!query.length)return cur;
        NSArray *keys=section==0?@[@"name",@"status",@"api",@"key"]:@[@"name",@"url"];
        return [cur filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){
            for(NSString *key in keys){id value=row[key];if([value isKindOfClass:NSString.class]&&[[(NSString *)value lowercaseString] containsString:query])return YES;}
            return NO;
        }]];
    };
    self.cachedFilteredSites=filterSection(self.sites,0);
    self.cachedFilteredLives=filterSection(self.lives,1);
    self.cachedFilterScope=scope;
    self.cachedFilterQuery=query;
}
- (NSArray *)filteredRowsForSection:(NSInteger)section {
    NSString *query=[[self.searchText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString]?:@"";
    NSInteger scope=self.contentFilter?self.contentFilter.selectedSegmentIndex:0;
    if(!self.cachedFilteredSites||self.cachedFilterScope!=scope||![self.cachedFilterQuery isEqualToString:query])[self rebuildFilteredCatalogCache];
    return section==0?(self.cachedFilteredSites?:@[]):(self.cachedFilteredLives?:@[]);
}
- (void)showTransientPrompt:(NSString *)prompt {
    NSString *fallback=@"点按需要的站点按需加载 · 不必全量导入";
    self.navigationItem.prompt=prompt;
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if([weakSelf.navigationItem.prompt isEqualToString:prompt])weakSelf.navigationItem.prompt=fallback;
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if(searchController.searchBar.searchTextField.markedTextRange)return;
    NSString *next=searchController.searchBar.text?:@"";
    if([next isEqualToString:self.searchText?:@""])return;
    self.searchText=next;[self.tableView reloadData];[self updateEmptyState];
}
- (void)updateCatalogSummary {
    if(!self.summaryLabel)return;
    NSUInteger supportedSites=0,nativeSites=0,scriptSites=0,supportedLives=0;
    for(NSDictionary *site in self.sites){
        if([site[@"supported"] boolValue]){
            supportedSites++;
            if([site[@"apiKind"] isEqual:@"script"])scriptSites++;
            else nativeSites++;
        }
    }
    for(NSDictionary *live in self.lives)if([live[@"supported"] boolValue])supportedLives++;
    self.summaryLabel.text=[NSString stringWithFormat:@"共 %lu 个影视站点（%lu 个原生直连 · %lu 个脚本） · %lu 个直播列表",(unsigned long)supportedSites,(unsigned long)nativeSites,(unsigned long)scriptSites,(unsigned long)supportedLives];
}
- (void)updateEmptyState {
    NSUInteger total=[self filteredRowsForSection:0].count+[self filteredRowsForSection:1].count;
    if(total){self.tableView.backgroundView=nil;return;}
    NSInteger scope=self.contentFilter?self.contentFilter.selectedSegmentIndex:0;NSString *emptyTitle=self.searchText.length?@"没有匹配的站点或直播源":(scope>0?@"当前筛选分类下暂无内容":@"此合集暂无内容");NSString *emptySubtitle=self.searchText.length?@"请修改搜索词":@"此合集暂无站点与直播列表";self.tableView.backgroundView=[HostEmptyStateView emptyStateViewWithTitle:emptyTitle subtitle:emptySubtitle symbol:@"rectangle.stack"];((HostEmptyStateView *)self.tableView.backgroundView).accessibilityIdentifier=@"tvbox-catalog-empty";
}
- (UIViewController *)visiblePresentationController {
    UIWindow *window=self.viewIfLoaded.window;
    if(!window||self.isBeingDismissed||self.isMovingFromParentViewController)return nil;
    UINavigationController *navigation=self.navigationController;
    if(navigation&&(navigation.topViewController!=self||navigation.viewIfLoaded.window!=window))return nil;
    return self;
}
- (void)presentCatalogAlert:(UIAlertController *)alert sourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect {
    if(self.pendingAlertRetry){dispatch_block_cancel(self.pendingAlertRetry);self.pendingAlertRetry=nil;}
    NSUInteger generation=++self.alertPresentationGeneration;
    [self attemptPresentCatalogAlert:alert sourceView:sourceView sourceRect:sourceRect retryCount:0 generation:generation];
}
- (void)attemptPresentCatalogAlert:(UIAlertController *)alert sourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect retryCount:(NSUInteger)retryCount generation:(NSUInteger)generation {
    if(generation!=self.alertPresentationGeneration||alert.presentingViewController||alert.isBeingPresented)return;
    UIViewController *presenter=[self visiblePresentationController];
    if(!presenter){
        UINavigationController *navigation=self.navigationController;
        // The navigation stack can already point at this page while its
        // controller view is still detached during the push transition. Keep
        // retry eligibility tied to ownership of the visible stack entry;
        // window attachment is the state we are waiting for.
        BOOL waitingForNavigationAttach=navigation&&navigation.topViewController==self&&!self.isBeingDismissed&&!self.isMovingFromParentViewController;
        if(waitingForNavigationAttach&&retryCount<10){
            if([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-port"])NSLog(@"TVBOX_ALERT_RETRY count=%lu originWindow=%d navWindow=%d",(unsigned long)retryCount,self.viewIfLoaded.window!=nil,navigation.viewIfLoaded.window!=nil);
            __weak typeof(self) weakSelf=self;
            dispatch_block_t retry=dispatch_block_create(0,^{TVBoxCatalogViewController *owner=weakSelf;if(!owner||generation!=owner.alertPresentationGeneration)return;owner.pendingAlertRetry=nil;[owner attemptPresentCatalogAlert:alert sourceView:sourceView sourceRect:sourceRect retryCount:retryCount+1 generation:generation];});self.pendingAlertRetry=retry;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),retry);
            return;
        }
        if([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-port"])NSLog(@"TVBOX_ALERT_NO_PRESENTER originWindow=%d navWindow=%d sceneCount=%lu",self.viewIfLoaded.window!=nil,self.navigationController.viewIfLoaded.window!=nil,(unsigned long)UIApplication.sharedApplication.connectedScenes.count);return;
    }
    UIPopoverPresentationController *popover=alert.popoverPresentationController;
    if(popover){
        UIView *anchor=sourceView.window==presenter.view.window?sourceView:presenter.view;
        popover.sourceView=anchor;
        popover.sourceRect=anchor==sourceView?sourceRect:CGRectMake(CGRectGetMidX(anchor.bounds),CGRectGetMidY(anchor.bounds),1,1);
    }
    if([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-port"])NSLog(@"TVBOX_ALERT_PRESENT presenter=%@ origin=%@ navTop=%@ window=%d",NSStringFromClass(presenter.class),NSStringFromClass(self.class),NSStringFromClass(self.navigationController.topViewController.class),presenter.viewIfLoaded.window!=nil);
    [presenter presentViewController:alert animated:YES completion:nil];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();NSString *catalogName=[self.catalog[@"name"] isKindOfClass:NSString.class]?self.catalog[@"name"]:@"";self.title=(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])?@"资源合集":catalogName;self.navigationItem.prompt=@"点按需要的站点按需加载 · 不必全量导入";self.tableView.backgroundColor=HostBackground();self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=88;
    self.searchController=[[UISearchController alloc] initWithSearchResultsController:nil];self.searchController.searchResultsUpdater=self;self.searchController.obscuresBackgroundDuringPresentation=NO;self.searchController.searchBar.placeholder=@"搜索合集中的站点、协议或 URL";self.searchController.searchBar.accessibilityLabel=@"搜索资源合集";self.searchController.searchBar.accessibilityHint=@"输入站点名称、协议或 URL 以筛选合集列表";self.searchController.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.searchController.searchBar.autocorrectionType=UITextAutocorrectionTypeNo;self.navigationItem.searchController=self.searchController;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
    __weak typeof(self) weakSelf=self;
    NSArray *resourceActions=@[
        @{@"icon":@"square.and.arrow.down",@"title":@"全量导入（较慢）",@"action":[UIAction actionWithHandler:^(UIAction *a){
            TVBoxCatalogViewController *owner=weakSelf;if(!owner)return;
            NSUInteger scripts=0,native=0,live=0,unsupported=0;
            for(NSDictionary *site in owner.sites){if(![site[@"supported"] boolValue])unsupported++;else if([site[@"apiKind"] isEqual:@"script"])scripts++;else native++;}
            for(NSDictionary *row in owner.lives){if([row[@"supported"] boolValue])live++;else unsupported++;}
            NSString *message=[NSString stringWithFormat:@"推荐按需加载：打开媒体页，点左侧资源胶囊选择本合集，再点右侧站点胶囊选择需要的站点。这样只会下载所选脚本。\n\n全量影视导入会检查并下载 %lu 个脚本站点，耗时较长；%lu 个原生 API 站点可直接按需使用，%lu 个不兼容项仍保留在合集里。%lu 个直播清单不会整包订阅，会继续留在本合集，点选其中一个后才加载。",(unsigned long)scripts,(unsigned long)native,(unsigned long)unsupported,(unsigned long)live];
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"全量影视导入（较慢）" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"仍然导入影视脚本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){if(owner.onImportCompatibleContents)owner.onImportCompatibleContents();}]];
            [owner presentCatalogAlert:alert sourceView:nil sourceRect:CGRectZero];
        }]},
        @{@"icon":@"square.and.arrow.up",@"title":@"导出完整合集 JSON",@"action":[UIAction actionWithHandler:^(UIAction *a){if(weakSelf.onExportCatalog)weakSelf.onExportCatalog(@"json");}]},
        @{@"icon":@"archivebox",@"title":@"导出资源 ZIP（含可获取的 PY / JS）",@"action":[UIAction actionWithHandler:^(UIAction *a){if(weakSelf.onExportCatalog)weakSelf.onExportCatalog(@"zip");}]},
        @{@"icon":@"trash",@"title":@"移除资源合集",@"action":[UIAction actionWithHandler:^(UIAction *a){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除资源合集？" message:@"仅移除这份集合索引；已导入的脚本和直播订阅会保留。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"移除合集" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){if(weakSelf.onRemove)weakSelf.onRemove();}]];[weakSelf presentCatalogAlert:alert sourceView:nil sourceRect:CGRectZero];}]}
    ];
    UIAction *json=resourceActions[1][@"action"],*zip=resourceActions[2][@"action"],*bulk=resourceActions[0][@"action"],*remove=resourceActions[3][@"action"];
    json.title=@"导出合集 JSON";json.image=[UIImage systemImageNamed:@"square.and.arrow.up"];
    zip.title=@"导出资源 ZIP";zip.subtitle=@"含可获取的 PY / JS 脚本";zip.image=[UIImage systemImageNamed:@"archivebox"];
    bulk.title=@"全量导入影视脚本";bulk.subtitle=@"推荐按需加载，全量耗时较长";bulk.image=[UIImage systemImageNamed:@"square.and.arrow.down"];
    remove.title=@"移除资源合集";remove.image=[UIImage systemImageNamed:@"trash"];remove.attributes=UIMenuElementAttributesDestructive;
    NSMutableArray<UIMenuElement *> *exportChildren=[NSMutableArray arrayWithObjects:json,zip,nil];
    NSString *catalogURL=[self.catalog[@"url"] isKindOfClass:NSString.class]?self.catalog[@"url"]:@"";
    if(catalogURL.length){
        UIAction *copyCatalogURL=[UIAction actionWithTitle:@"复制合集源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:catalogURL];[weakSelf showTransientPrompt:@"合集源地址已复制"];}];
        [exportChildren addObject:copyCatalogURL];
    }
    UIMenu *exportGroup=[UIMenu menuWithTitle:@"导出与复制" image:nil identifier:@"tvbox.catalog.menu.export" options:UIMenuOptionsDisplayInline children:exportChildren];
    UIMenu *advGroup=[UIMenu menuWithTitle:@"高级操作" image:nil identifier:@"tvbox.catalog.menu.advanced" options:UIMenuOptionsDisplayInline children:@[bulk]];
    UIMenu *dangerGroup=[UIMenu menuWithTitle:@"" image:nil identifier:@"tvbox.catalog.menu.danger" options:UIMenuOptionsDisplayInline children:@[remove]];
    UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:nil action:nil];
    more.accessibilityLabel=@"合集操作";more.accessibilityHint=@"导出、导入或移除本资源合集";more.menu=[UIMenu menuWithChildren:@[exportGroup,advGroup,dangerGroup]];self.navigationItem.rightBarButtonItem=more;
    self.contentFilter=[[UISegmentedControl alloc] initWithItems:@[@"全部",@"影视",@"直播",@"不支持"]];self.contentFilter.selectedSegmentIndex=0;self.contentFilter.selectedSegmentTintColor=HostAccent();self.contentFilter.accessibilityLabel=@"资源分类筛选";self.contentFilter.accessibilityHint=@"筛选全部、影视、直播或不支持的资源";[self.contentFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateNormal];[self.contentFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateSelected];[self.contentFilter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(320,self.tableView.bounds.size.width),96)];
    UIView *headerCard=[UIView new];
    headerCard.translatesAutoresizingMaskIntoConstraints=NO;
    HostStyleGlassCard(headerCard,16);
    self.headerCardView=headerCard;
    [header addSubview:headerCard];
    self.summaryLabel=[UILabel new];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints=NO;
    self.summaryLabel.numberOfLines=0;
    self.summaryLabel.font=HostMonospacedDigitFont(12.5,UIFontWeightSemibold,UIFontTextStyleCaption1);
    self.summaryLabel.adjustsFontForContentSizeCategory=YES;
    self.summaryLabel.textColor=HostSecondaryText();
    self.summaryLabel.accessibilityIdentifier=@"tvbox.catalog.summary";
    [headerCard addSubview:self.summaryLabel];
    self.contentFilter.translatesAutoresizingMaskIntoConstraints=NO;
    [headerCard addSubview:self.contentFilter];
    [NSLayoutConstraint activateConstraints:@[
        [headerCard.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [headerCard.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [headerCard.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [headerCard.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:14],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-14],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:headerCard.topAnchor constant:10],
        [self.contentFilter.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:10],
        [self.contentFilter.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-10],
        [self.contentFilter.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:8],
        [self.contentFilter.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [self.contentFilter.bottomAnchor constraintEqualToAnchor:headerCard.bottomAnchor constant:-10]
    ]];
    self.tableView.tableHeaderView=header;
    UIRefreshControl *rc=[UIRefreshControl new];
    rc.tintColor=HostAccent();
    rc.attributedTitle=[[NSAttributedString alloc] initWithString:@"下拉重新显示本地合集；远程更新请在资源页选择“刷新合集”"];
    [rc addTarget:self action:@selector(pullRefreshCatalog:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl=rc;
    [self updateCatalogSummary];
    [self updateHeaderLayoutIfNeeded];
    [self updateEmptyState];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateHeaderLayoutIfNeeded];
}
- (void)updateHeaderLayoutIfNeeded {
    UIView *header=self.tableView.tableHeaderView;
    CGFloat w=CGRectGetWidth(self.tableView.bounds);
    if(!header||w<=0)return;
    CGSize target=CGSizeMake(w,UILayoutFittingCompressedSize.height);
    CGFloat h=ceil([header systemLayoutSizeFittingSize:target withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    if(fabs(CGRectGetWidth(header.frame)-w)>0.5||fabs(CGRectGetHeight(header.frame)-h)>0.5){
        header.frame=CGRectMake(0,0,w,MAX(88,h));
        self.tableView.tableHeaderView=header;
    }
}
- (void)pullRefreshCatalog:(UIRefreshControl *)sender {
    [self rebuildFilteredCatalogCache];
    [self updateCatalogSummary];
    [self updateHeaderLayoutIfNeeded];
    [self.tableView reloadData];
    [self updateEmptyState];
    [self showTransientPrompt:@"已重载本地合集 · 远程更新请在资源页选择“刷新合集”"];
    __weak typeof(sender) weakSender=sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[weakSender endRefreshing];});
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    if(self.headerCardView)HostStyleGlassCard(self.headerCardView,16);
    self.summaryLabel.textColor=HostSecondaryText();
    self.contentFilter.selectedSegmentTintColor=HostAccent();
    [self.contentFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateNormal];
    [self.contentFilter setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent(),NSFontAttributeName:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]} forState:UIControlStateSelected];
    [self updateEmptyState];
    [self.tableView reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection&&[self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        HostRefreshAppearanceLayers(self.view.window);
        [self reloadThemeAppearance];
    }
}
- (void)filterChanged {[self.tableView reloadData];[self updateEmptyState];}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self filteredRowsForSection:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {NSArray *rows=[self filteredRowsForSection:section];return section==0?[NSString stringWithFormat:@"影视站点 · %lu",(unsigned long)rows.count]:[NSString stringWithFormat:@"直播列表 · %lu",(unsigned long)rows.count];}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"推荐按需加载：在首页顶部选择本合集，再从右侧胶囊点选站点；仅所选脚本会下载，type 1/4 JSON API 会直接读取。不兼容项会保留并标注。";return @"点按需要的直播清单即可加载；同一直播合集只保留当前选择的一个清单，其他清单仍留在合集内。刷新播放列表时会应用合集提供的 UA。";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"tvbox.catalog.row"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"tvbox.catalog.row"];cell.transform=CGAffineTransformIdentity;cell.backgroundColor=HostCard();cell.layer.cornerRadius=13;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();
    NSArray *rows=[self filteredRowsForSection:ip.section];if(ip.row<0||ip.row>=rows.count)return cell;
    NSDictionary *row=rows[ip.row];if(![row isKindOfClass:NSDictionary.class])return cell;
    cell.textLabel.text=[row[@"name"] description]?:@"未命名";
    cell.textLabel.font=HostRoundedFont(16,UIFontWeightSemibold,UIFontTextStyleHeadline);
    cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.detailTextLabel.font=HostMonospacedDigitFont(12,UIFontWeightRegular,UIFontTextStyleCaption1);
    cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    BOOL supported=[row[@"supported"] boolValue];NSDictionary *service=ip.section==0&&self.serviceForSite?self.serviceForSite(row):nil;BOOL serviceRunning=service&&[PyHost isRunningServiceIdentifier:service[@"id"]];NSString *status=[row[@"status"] description]?:@"";if(service)status=serviceRunning?@"服务运行中 · 点按打开资源":@"服务已导入 · 点按启动并打开资源";cell.detailTextLabel.text=ip.section==0?[NSString stringWithFormat:@"%@\n%@",status,[HostLogRedactor redactText:[row[@"api"] description]?:@""]]:[NSString stringWithFormat:@"%@\n%@",status,[HostLogRedactor redactText:[row[@"url"] description]?:@""]];
    if(cell.detailTextLabel.text.length){NSMutableParagraphStyle *pStyle=[NSMutableParagraphStyle new];pStyle.lineSpacing=3.0;pStyle.paragraphSpacing=1.5;pStyle.lineBreakMode=NSLineBreakByCharWrapping;cell.detailTextLabel.attributedText=[[NSAttributedString alloc] initWithString:cell.detailTextLabel.text attributes:@{NSFontAttributeName:cell.detailTextLabel.font,NSForegroundColorAttributeName:HostSecondaryText(),NSParagraphStyleAttributeName:pStyle}];}else{cell.detailTextLabel.attributedText=nil;}
    NSString *iconName=ip.section==0?([row[@"apiKind"] isEqual:@"script"]?@"terminal":@"bolt.horizontal.circle"):@"dot.radiowaves.left.and.right";
    cell.imageView.image=[UIImage systemImageNamed:iconName];
    cell.imageView.tintColor=supported?(serviceRunning?UIColor.systemGreenColor:HostAccent()):HostMutedText();
    if(serviceRunning){cell.layer.borderWidth=1.05;HostSetLayerBorderColor(cell,HostAccent());}
    UIView *accentBar=[cell.contentView viewWithTag:9201];
    if(!accentBar){accentBar=[[UIView alloc] initWithFrame:CGRectMake(2,10,3,MAX(0,CGRectGetHeight(cell.contentView.bounds)-20))];accentBar.tag=9201;accentBar.autoresizingMask=UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleRightMargin;accentBar.layer.cornerRadius=1.5;accentBar.userInteractionEnabled=NO;[cell.contentView addSubview:accentBar];}
    accentBar.frame=CGRectMake(2,10,3,MAX(0,CGRectGetHeight(cell.contentView.bounds)-20));
    accentBar.backgroundColor=serviceRunning?UIColor.systemGreenColor:(supported?HostAccent():[HostMutedText() colorWithAlphaComponent:0.35]);
    cell.accessoryType=supported?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=supported?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;cell.textLabel.textColor=supported?HostText():HostMutedText();
    // VoiceOver：可点按的资源行补按钮特征与提示，不支持项保持静态文本。
    if(supported){
        cell.accessibilityTraits=UIAccessibilityTraitButton;
        cell.accessibilityHint=ip.section==0?@"点按打开或导入此站点，长按可导出单项资源":@"点按加载此直播清单，长按可导出单项资源";
    }else{
        cell.accessibilityTraits=UIAccessibilityTraitStaticText;
        cell.accessibilityHint=nil;
    }
    cell.imageView.accessibilityElementsHidden=YES;
    return cell;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    NSArray *rows=[self filteredRowsForSection:ip.section];if(ip.row<0||ip.row>=rows.count)return nil;
    NSDictionary *row=rows[ip.row];if(![row isKindOfClass:NSDictionary.class])return nil;NSString *kind=ip.section==0?@"site":@"live";NSUInteger index=[row[@"sourceIndex"] respondsToSelector:@selector(unsignedIntegerValue)]?[row[@"sourceIndex"] unsignedIntegerValue]:(NSUInteger)ip.row;NSString *title=[row[@"name"] isKindOfClass:NSString.class]?row[@"name"]:@"资源";BOOL supported=[row[@"supported"] boolValue];__weak typeof(self) weakSelf=self;
    return [UIContextMenuConfiguration configurationWithIdentifier:[NSString stringWithFormat:@"%@:%@:%lu",self.catalog[@"id"]?:@"",kind,(unsigned long)index] previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        NSMutableArray<UIAction *> *children=[NSMutableArray array];
        if(supported){
            UIAction *open=[UIAction actionWithTitle:ip.section==0?@"打开或导入此站点":@"加载此直播清单" image:[UIImage systemImageNamed:@"play.circle"] identifier:nil handler:^(__unused UIAction *action){[weakSelf tableView:tableView didSelectRowAtIndexPath:ip];}];
            [children addObject:open];
        }
        UIAction *export=[UIAction actionWithTitle:[NSString stringWithFormat:@"导出 %@ JSON",title] image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action){if(weakSelf.onExportSingleResource)weakSelf.onExportSingleResource(row,kind,index);}];
        [children addObject:export];
        NSString *endpoint=[row[ip.section==0?@"api":@"url"] description]?:@"";
        UIAction *copyEndpoint=[UIAction actionWithTitle:@"复制接口地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action){if(endpoint.length){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:endpoint];[weakSelf showTransientPrompt:@"接口地址已复制"];}}];
        [children addObject:copyEndpoint];
        UIAction *copyTitle=[UIAction actionWithTitle:@"复制资源名称" image:[UIImage systemImageNamed:@"textformat"] identifier:nil handler:^(__unused UIAction *action){UIPasteboard.generalPasteboard.string=title;[weakSelf showTransientPrompt:@"资源名称已复制"];}];
        [children addObject:copyTitle];
        return [UIMenu menuWithTitle:@"单项资源" children:children];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];NSArray *rows=[self filteredRowsForSection:ip.section];if(ip.row<0||ip.row>=rows.count)return;NSDictionary *row=rows[ip.row];if(![row isKindOfClass:NSDictionary.class])return;
    if(ip.section==1){if([row[@"supported"] boolValue]&&self.onSubscribeLive)self.onSubscribeLive(row);return;}
    if(![row[@"supported"] boolValue])return;
    BOOL nativeAPI=[row[@"apiKind"] isEqual:@"tvbox-api"]||[row[@"apiKind"] isEqual:@"maccms-api"]||[row[@"apiKind"] isEqual:@"douban-index"]||[row[@"apiKind"] isEqual:@"jar-bridge"];if(nativeAPI){if(self.onUseNativeSite)self.onUseNativeSite(row);return;}
    NSDictionary *existing=self.serviceForSite?self.serviceForSite(row):nil;
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetAction *> *actions=[NSMutableArray array];
    if(existing){
        [actions addObject:[HostGlassSheetAction actionWithTitle:@"启动并打开资源" subtitle:@"立即拉起脚本服务并进入影视库" value:nil icon:@"play.circle.fill" tint:HostAccent() destructive:NO selected:NO handler:^{if(weakSelf.onUseImportedService)weakSelf.onUseImportedService(existing);}]];
        [actions addObject:[HostGlassSheetAction actionWithTitle:@"查看能力与设置" subtitle:@"检查接口、端口与运行日志" value:nil icon:@"slider.horizontal.3" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{if(weakSelf.onOpenImportedService)weakSelf.onOpenImportedService(existing);}]];
    }else{
        [actions addObject:[HostGlassSheetAction actionWithTitle:@"导入并打开资源" subtitle:@"按需导入当前站点脚本并直接浏览" value:nil icon:@"square.and.arrow.down.fill" tint:HostAccent() destructive:NO selected:NO handler:^{if(weakSelf.onImportSite)weakSelf.onImportSite(row,YES);}]];
        [actions addObject:[HostGlassSheetAction actionWithTitle:@"仅导入到资源页" subtitle:@"保存脚本配置稍后手动启动" value:nil icon:@"tray.and.arrow.down" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{if(weakSelf.onImportSite)weakSelf.onImportSite(row,NO);}]];
    }
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];
    [HostGlassActionSheetViewController presentOn:self
                                            title:[row[@"name"] description]?:@"未命名"
                                         subtitle:existing?@"此脚本已在资源中。打开后会启动该资源并进入影视库。":@"仅对当前选择的站点执行脚本导入。ext 会作为 Spider 初始化配置传递。"
                                        badgeText:existing?@"已导入脚本":@"脚本站点"
                                       badgeColor:existing?UIColor.systemGreenColor:HostAccent()
                                         sections:@[[HostGlassSheetSection sectionWithTitle:@"站点操作" actions:actions]]
                                       sourceView:cell?:self.view];
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
@end
