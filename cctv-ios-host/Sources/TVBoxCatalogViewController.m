#import "TVBoxCatalogViewController.h"
#import "TVBoxCatalogStore.h"
#import "HostTheme.h"
#import "HostLogRedactor.h"
#import "HostToolbar.h"
#import "PyHost.h"

@interface TVBoxCatalogViewController () <UISearchResultsUpdating>
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,copy) NSString *searchText;
@property(nonatomic,strong) UISegmentedControl *contentFilter;
@property(nonatomic,strong) UILabel *summaryLabel;
- (void)updateEmptyState;
- (void)updateCatalogSummary;
- (void)presentCatalogAlert:(UIAlertController *)alert sourceView:(nullable UIView *)sourceView sourceRect:(CGRect)sourceRect;
@end

@implementation TVBoxCatalogViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (NSArray *)sites { return [self.catalog[@"sites"] isKindOfClass:NSArray.class]?self.catalog[@"sites"]:@[]; }
- (NSArray *)lives { return [self.catalog[@"lives"] isKindOfClass:NSArray.class]?self.catalog[@"lives"]:@[]; }
- (NSArray *)filteredRowsForSection:(NSInteger)section {
    NSArray *rows=section==0?self.sites:self.lives;NSString *query=self.searchText.lowercaseString;
    NSInteger scope=self.contentFilter.selectedSegmentIndex;
    if((scope==1&&section==1)||(scope==2&&section==0))return @[];
    if(scope==3)rows=[rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){return ![row[@"supported"] boolValue];}]];
    if(!query.length)return rows;
    return [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *bindings){
        NSArray *keys=section==0?@[@"name",@"status",@"api",@"key"]:@[@"name",@"url"];
        for(NSString *key in keys){id value=row[key];if([value isKindOfClass:NSString.class]&&[[(NSString *)value lowercaseString] containsString:query])return YES;}
        return NO;
    }]];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {self.searchText=searchController.searchBar.text?:@"";[self.tableView reloadData];[self updateEmptyState];}
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
    UILabel *empty=[[UILabel alloc] initWithFrame:self.tableView.bounds];
    NSInteger scope=self.contentFilter?self.contentFilter.selectedSegmentIndex:0;
    empty.text=self.searchText.length?@"没有匹配的站点或直播源，请修改搜索词":(scope>0?@"当前筛选分类下暂无站点或直播列表":@"此合集暂无站点与直播列表");
    empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];empty.adjustsFontForContentSizeCategory=YES;empty.textColor=HostSecondaryText();self.tableView.backgroundView=empty;
}
- (UIViewController *)visiblePresentationController {
    UIWindow *window=self.viewIfLoaded.window;
    if(!window){
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
            if(scene.activationState!=UISceneActivationStateForegroundActive)continue;
            for(UIWindow *candidate in ((UIWindowScene *)scene).windows)if(candidate.isKeyWindow){window=candidate;break;}
            if(window)break;
        }
    }
    UIViewController *controller=window.rootViewController;
    while(controller){
        if(controller.presentedViewController&&!controller.presentedViewController.isBeingDismissed){controller=controller.presentedViewController;continue;}
        if([controller isKindOfClass:UINavigationController.class]){UIViewController *top=((UINavigationController *)controller).topViewController;if(top&&top!=controller){controller=top;continue;}}
        if([controller isKindOfClass:UITabBarController.class]){UIViewController *selected=((UITabBarController *)controller).selectedViewController;if(selected&&selected!=controller){controller=selected;continue;}}
        break;
    }
    return controller.viewIfLoaded.window==window&&!controller.isBeingDismissed?controller:nil;
}
- (void)presentCatalogAlert:(UIAlertController *)alert sourceView:(UIView *)sourceView sourceRect:(CGRect)sourceRect {
    UIViewController *presenter=[self visiblePresentationController];
    if(!presenter)return;
    UIPopoverPresentationController *popover=alert.popoverPresentationController;
    if(popover){
        UIView *anchor=sourceView.window==presenter.view.window?sourceView:presenter.view;
        popover.sourceView=anchor;
        popover.sourceRect=anchor==sourceView?sourceRect:CGRectMake(CGRectGetMidX(anchor.bounds),CGRectGetMidY(anchor.bounds),1,1);
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();NSString *catalogName=[self.catalog[@"name"] isKindOfClass:NSString.class]?self.catalog[@"name"]:@"";self.title=(!catalogName.length||[catalogName isEqual:@"TVBox 资源目录"]||[catalogName isEqual:@"TVBox资源目录"])?@"资源合集":catalogName;self.navigationItem.prompt=@"点按需要的站点按需加载 · 不必全量导入";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=88;
    self.searchController=[[UISearchController alloc] initWithSearchResultsController:nil];self.searchController.searchResultsUpdater=self;self.searchController.obscuresBackgroundDuringPresentation=NO;self.searchController.searchBar.placeholder=@"搜索合集中的站点、协议或 URL";self.searchController.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.searchController.searchBar.autocorrectionType=UITextAutocorrectionTypeNo;self.navigationItem.searchController=self.searchController;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
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
    json.title=@"导出完整合集 JSON";zip.title=@"导出资源 ZIP（含可获取的 PY / JS）";bulk.title=@"全量导入影视脚本";remove.title=@"移除资源合集";remove.attributes=UIMenuElementAttributesDestructive;
    NSMutableArray<UIMenuElement *> *exportChildren=[NSMutableArray arrayWithObjects:json,zip,nil];
    NSString *catalogURL=[self.catalog[@"url"] isKindOfClass:NSString.class]?self.catalog[@"url"]:@"";
    if(catalogURL.length){
        UIAction *copyCatalogURL=[UIAction actionWithTitle:@"复制合集源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:catalogURL];}];
        [exportChildren addObject:copyCatalogURL];
    }
    UIBarButtonItem *more=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:nil action:nil];
    more.accessibilityLabel=@"合集操作";more.menu=[UIMenu menuWithChildren:@[[UIMenu menuWithTitle:@"导出与复制" children:exportChildren],[UIMenu menuWithTitle:@"高级操作" children:@[bulk]],remove]];self.navigationItem.rightBarButtonItem=more;
    self.contentFilter=[[UISegmentedControl alloc] initWithItems:@[@"全部",@"影视",@"直播",@"不支持"]];self.contentFilter.selectedSegmentIndex=0;self.contentFilter.selectedSegmentTintColor=HostAccent();[self.contentFilter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,self.tableView.bounds.size.width,92)];
    UIView *headerCard=[[UIView alloc] initWithFrame:CGRectMake(16,4,MAX(1,header.bounds.size.width-32),80)];
    headerCard.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    HostStyleGlassCard(headerCard,16);
    [header addSubview:headerCard];
    self.summaryLabel=[[UILabel alloc] initWithFrame:CGRectMake(14,8,MAX(1,headerCard.bounds.size.width-28),20)];
    self.summaryLabel.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    self.summaryLabel.font=HostMonospacedDigitFont(12.5,UIFontWeightSemibold,UIFontTextStyleCaption1);
    self.summaryLabel.textColor=HostSecondaryText();
    self.summaryLabel.accessibilityIdentifier=@"tvbox.catalog.summary";
    [headerCard addSubview:self.summaryLabel];
    self.contentFilter.frame=CGRectMake(10,32,MAX(1,headerCard.bounds.size.width-20),40);self.contentFilter.autoresizingMask=UIViewAutoresizingFlexibleWidth;[headerCard addSubview:self.contentFilter];self.tableView.tableHeaderView=header;
    [self updateCatalogSummary];
    [self updateEmptyState];
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.summaryLabel.textColor=HostSecondaryText();
    self.contentFilter.selectedSegmentTintColor=HostAccent();
    [self updateEmptyState];
    [self.tableView reloadData];
}
- (void)filterChanged {[self.tableView reloadData];[self updateEmptyState];}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self filteredRowsForSection:section].count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {NSArray *rows=[self filteredRowsForSection:section];return section==0?[NSString stringWithFormat:@"影视站点 · %lu",(unsigned long)rows.count]:[NSString stringWithFormat:@"直播列表 · %lu",(unsigned long)rows.count];}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionHeaderView(view); }
- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section { HostStyleSectionFooterView(view); }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {if(section==0)return @"推荐按需加载：在首页顶部选择本合集，再从右侧胶囊点选站点；仅所选脚本会下载，type 1/4 JSON API 会直接读取。不兼容项会保留并标注。";return @"点按需要的直播清单即可加载；同一直播合集只保留当前选择的一个清单，其他清单仍留在合集内。刷新播放列表时会应用合集提供的 UA。";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"tvbox.catalog.row"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"tvbox.catalog.row"];cell.backgroundColor=HostCard();cell.layer.cornerRadius=13;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();
    NSArray *rows=[self filteredRowsForSection:ip.section];if(ip.row<0||ip.row>=rows.count)return cell;
    NSDictionary *row=rows[ip.row];if(![row isKindOfClass:NSDictionary.class])return cell;
    cell.textLabel.text=[row[@"name"] description]?:@"未命名";
    cell.textLabel.font=HostRoundedFont(16,UIFontWeightSemibold,UIFontTextStyleHeadline);
    cell.detailTextLabel.font=HostMonospacedDigitFont(12,UIFontWeightRegular,UIFontTextStyleCaption1);
    BOOL supported=[row[@"supported"] boolValue];NSDictionary *service=ip.section==0&&self.serviceForSite?self.serviceForSite(row):nil;BOOL serviceRunning=service&&[PyHost isRunningServiceIdentifier:service[@"id"]];NSString *status=[row[@"status"] description]?:@"";if(service)status=serviceRunning?@"服务运行中 · 点按打开资源":@"服务已导入 · 点按启动并打开资源";cell.detailTextLabel.text=ip.section==0?[NSString stringWithFormat:@"%@\n%@",status,[HostLogRedactor redactText:[row[@"api"] description]?:@""]]:[NSString stringWithFormat:@"%@\n%@",status,[HostLogRedactor redactText:[row[@"url"] description]?:@""]];
    if(cell.detailTextLabel.text.length){NSMutableParagraphStyle *pStyle=[NSMutableParagraphStyle new];pStyle.lineSpacing=3.0;pStyle.paragraphSpacing=1.5;cell.detailTextLabel.attributedText=[[NSAttributedString alloc] initWithString:cell.detailTextLabel.text attributes:@{NSFontAttributeName:cell.detailTextLabel.font,NSForegroundColorAttributeName:HostSecondaryText(),NSParagraphStyleAttributeName:pStyle}];}
    NSString *iconName=ip.section==0?([row[@"apiKind"] isEqual:@"script"]?@"terminal":@"bolt.horizontal.circle"):@"dot.radiowaves.left.and.right";
    cell.imageView.image=[UIImage systemImageNamed:iconName];
    cell.imageView.tintColor=supported?(serviceRunning?UIColor.systemGreenColor:HostAccent()):HostMutedText();
    if(serviceRunning){cell.layer.borderWidth=1.05;HostSetLayerBorderColor(cell,HostAccent());}
    cell.accessoryType=supported?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=supported?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;cell.textLabel.textColor=supported?HostText():HostMutedText();return cell;
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
        UIAction *copyEndpoint=[UIAction actionWithTitle:@"复制接口地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *action){if(endpoint.length)UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:endpoint];}];
        [children addObject:copyEndpoint];
        UIAction *copyTitle=[UIAction actionWithTitle:@"复制资源名称" image:[UIImage systemImageNamed:@"textformat"] identifier:nil handler:^(__unused UIAction *action){UIPasteboard.generalPasteboard.string=title;}];
        [children addObject:copyTitle];
        return [UIMenu menuWithTitle:@"单项资源" children:children];
    }];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];NSArray *rows=[self filteredRowsForSection:ip.section];if(ip.row<0||ip.row>=rows.count)return;NSDictionary *row=rows[ip.row];if(![row isKindOfClass:NSDictionary.class])return;
    if(ip.section==1){if([row[@"supported"] boolValue]&&self.onSubscribeLive)self.onSubscribeLive(row);return;}
    if(![row[@"supported"] boolValue])return;
    BOOL nativeAPI=[row[@"apiKind"] isEqual:@"tvbox-api"]||[row[@"apiKind"] isEqual:@"maccms-api"]||[row[@"apiKind"] isEqual:@"douban-index"]||[row[@"apiKind"] isEqual:@"jar-bridge"];if(nativeAPI){if(self.onUseNativeSite)self.onUseNativeSite(row);return;}
    NSDictionary *existing=self.serviceForSite?self.serviceForSite(row):nil;UIAlertController *alert=[UIAlertController alertControllerWithTitle:[row[@"name"] description]?:@"未命名" message:existing?@"此脚本已在资源中。打开后会启动该资源并进入影视库。":@"仅对当前选择的站点执行脚本导入。可直接导入并浏览，也可先保存到资源页。ext 会作为 Spider 初始化配置传递。" preferredStyle:UIAlertControllerStyleActionSheet];
    if(existing){[alert addAction:[UIAlertAction actionWithTitle:@"启动并打开资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onUseImportedService)self.onUseImportedService(existing);}]];[alert addAction:[UIAlertAction actionWithTitle:@"查看能力与设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onOpenImportedService)self.onOpenImportedService(existing);}]];}
    else {[alert addAction:[UIAlertAction actionWithTitle:@"导入并打开资源" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onImportSite)self.onImportSite(row,YES);}]];[alert addAction:[UIAlertAction actionWithTitle:@"仅导入到资源页" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){if(self.onImportSite)self.onImportSite(row,NO);}]];}
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];[self presentCatalogAlert:alert sourceView:cell sourceRect:cell.bounds];
}
@end
