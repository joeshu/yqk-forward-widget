#import "MediaBrowserViewController.h"
#import "MediaAPIClient.h"
#import "HostImageLoader.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "LocalServiceReadiness.h"
#import "ServiceStore.h"

@interface MediaSourcePicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSDictionary *> *choices;
@property(nonatomic, copy) NSArray<NSDictionary *> *shown;
@property(nonatomic, copy) void (^onSelect)(NSDictionary *);
@property(nonatomic, strong) UISearchController *search;
@end
@implementation MediaSourcePicker
- (void)viewDidLoad {[super viewDidLoad];self.title=@"影视来源";self.shown=self.choices;self.tableView.backgroundColor=UIColor.blackColor;self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchResultsUpdater=self;self.search.searchBar.placeholder=@"搜索资源或来源";self.navigationItem.searchController=self.search;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.shown.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"source"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];NSDictionary *choice=self.shown[index.row];cell.textLabel.text=choice[@"name"];cell.detailTextLabel.text=choice[@"subtitle"];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {NSString *query=controller.searchBar.text?:@"";self.shown=query.length?[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){return [choice[@"name"] rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound || [choice[@"subtitle"] rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound;}]]:self.choices;[self.tableView reloadData];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {NSDictionary *choice=self.shown[index.row];[self.navigationController popViewControllerAnimated:YES];if(self.onSelect)self.onSelect(choice);}
@end

@interface MediaDetailViewController : UITableViewController
@property(nonatomic, copy) NSDictionary *item;
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) NSString *provider;
@property(nonatomic, copy) NSDictionary *detail;
@property(nonatomic, strong) MediaAPIClient *client;
@property(nonatomic, copy) void (^onPlay)(NSDictionary *,NSString *);
@property(nonatomic, strong) UILabel *status;
@property(nonatomic) BOOL resolving;
@end
@implementation MediaDetailViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.item[@"name"];self.tableView.backgroundColor=UIColor.blackColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=56;
    self.status=[UILabel new];self.status.textAlignment=NSTextAlignmentCenter;self.status.textColor=UIColor.secondaryLabelColor;self.status.numberOfLines=0;self.tableView.backgroundView=self.status;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadDetail)];
    self.client=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];[self loadDetail];
}
- (NSDictionary *)arguments:(NSDictionary *)args {NSMutableDictionary *value=[args mutableCopy];if(self.provider.length)value[@"provider"]=self.provider;return value;}
- (void)loadDetail {
    self.resolving=NO;self.detail=nil;self.status.text=@"正在加载影片详情…";[self.tableView reloadData];
    __weak typeof(self) weakSelf=self;
    [self.client call:@"detail" arguments:[self arguments:@{@"id":self.item[@"id"]?:@""}] completion:^(id result,NSError *error){
        MediaDetailViewController *owner=weakSelf;if(!owner)return;
        if(error || ![result isKindOfClass:NSDictionary.class]){owner.status.text=error.localizedDescription?:@"没有影片详情";return;}
        owner.detail=result;owner.status.text=@"";owner.title=result[@"name"]?:owner.title;[owner.tableView reloadData];
    }];
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(!self.presentedViewController && !self.navigationController){[self.client cancel];}}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return self.detail?1+[self.detail[@"lines"] count]:0;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?1:[self.detail[@"lines"][section-1][@"episodes"] count];}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return section==0?@"影片详情":self.detail[@"lines"][section-1][@"name"];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return section==0 && ![self.detail[@"lines"] count]?@"来源未提供可播放的分集":nil;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:ip.section==0?@"summary":@"episode"];
    if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ip.section==0?@"summary":@"episode"];
    cell.backgroundColor=HostCard();cell.textLabel.textColor=UIColor.labelColor;cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.detailTextLabel.text=nil;cell.accessoryType=UITableViewCellAccessoryNone;
    if(ip.section==0){cell.textLabel.text=self.detail[@"name"];NSString *description=self.detail[@"description"]?:@"暂无简介";if(description.length>5000)description=[description substringToIndex:5000];cell.detailTextLabel.text=description;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else{NSDictionary *episode=self.detail[@"lines"][ip.section-1][@"episodes"][ip.row];cell.textLabel.text=episode[@"name"]?:@"播放";cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.selectionStyle=UITableViewCellSelectionStyleDefault;}
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];if(ip.section==0 || self.resolving)return;
    NSDictionary *line=self.detail[@"lines"][ip.section-1],*episode=line[@"episodes"][ip.row];self.resolving=YES;self.navigationItem.prompt=@"正在解析当前分集…";
    __weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:[self arguments:@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""}] completion:^(id result,NSError *error){
        MediaDetailViewController *owner=weakSelf;if(!owner)return;owner.resolving=NO;owner.navigationItem.prompt=nil;
        if(error){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"播放失败" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[owner presentViewController:alert animated:YES completion:nil];return;}
        if(owner.onPlay)owner.onPlay(result,[NSString stringWithFormat:@"%@ · %@",owner.detail[@"name"]?:owner.title,episode[@"name"]?:@""]);
    }];
}
@end

@interface MediaBrowserViewController () <UICollectionViewDataSource,UICollectionViewDelegateFlowLayout,UISearchResultsUpdating>
@property(nonatomic, strong) UICollectionView *grid;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) UIScrollView *categoryScroll;
@property(nonatomic, strong) UIStackView *categories;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *resourceButton;
@property(nonatomic, strong) UIButton *moreButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) MediaAPIClient *client;
@property(nonatomic, strong) LocalServiceReadiness *readiness;
@property(nonatomic, copy) NSArray<NSDictionary *> *sources;
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) NSArray<NSDictionary *> *providers;
@property(nonatomic, copy) NSString *provider;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, copy) NSString *keyword;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL hasMore;
@property(nonatomic) BOOL loading;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger searchGeneration;
@property(nonatomic, copy) NSDictionary *filters;
@property(nonatomic, strong) NSMutableDictionary *selectedFilters;
@end
@implementation MediaBrowserViewController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"影视";self.view.backgroundColor=UIColor.blackColor;self.items=@[];self.keyword=@"";
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"搜索当前影视来源";self.navigationItem.searchController=self.search;
    __weak typeof(self) weakSelf=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"square.stack",@"title":@"选择影视来源",@"action":[UIAction actionWithHandler:^(UIAction *action){[weakSelf chooseSource];}]},
        @{@"icon":@"line.3.horizontal.decrease.circle",@"title":@"分类筛选",@"action":[UIAction actionWithHandler:^(UIAction *action){[weakSelf chooseFilters];}]},
        @{@"icon":@"arrow.clockwise",@"title":@"刷新当前来源",@"action":[UIAction actionWithHandler:^(UIAction *action){if(weakSelf.source)[weakSelf activate:weakSelf.source];else[weakSelf loadSources];}]}])];
    self.categoryScroll=[UIScrollView new];self.categoryScroll.showsHorizontalScrollIndicator=NO;self.categoryScroll.translatesAutoresizingMaskIntoConstraints=NO;
    self.categories=[[UIStackView alloc] init];self.categories.axis=UILayoutConstraintAxisHorizontal;self.categories.spacing=10;self.categories.translatesAutoresizingMaskIntoConstraints=NO;[self.categoryScroll addSubview:self.categories];[self.view addSubview:self.categoryScroll];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];layout.minimumInteritemSpacing=10;layout.minimumLineSpacing=16;layout.sectionInset=UIEdgeInsetsMake(12,14,16,14);
    self.grid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];self.grid.translatesAutoresizingMaskIntoConstraints=NO;self.grid.backgroundColor=UIColor.blackColor;self.grid.dataSource=self;self.grid.delegate=self;self.grid.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self.grid registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"movie"];[self.view addSubview:self.grid];
    self.moreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.moreButton.translatesAutoresizingMaskIntoConstraints=NO;[self.moreButton setTitle:@"加载更多" forState:UIControlStateNormal];[self.moreButton addTarget:self action:@selector(loadMore) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.moreButton];self.moreButton.hidden=YES;
    self.status=[UILabel new];self.status.textColor=UIColor.secondaryLabelColor;self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.status];
    self.resourceButton=[UIButton buttonWithType:UIButtonTypeSystem];self.resourceButton.translatesAutoresizingMaskIntoConstraints=NO;[self.resourceButton setTitle:@"管理资源" forState:UIControlStateNormal];[self.resourceButton addTarget:self action:@selector(openResources) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.resourceButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.categoryScroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.categoryScroll.heightAnchor constraintEqualToConstant:44],
        [self.categories.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor constant:14],[self.categories.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor constant:-14],[self.categories.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor constant:4],[self.categories.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor constant:-4],[self.categories.heightAnchor constraintEqualToConstant:36],
        [self.grid.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor],[self.grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.grid.bottomAnchor constraintEqualToAnchor:self.moreButton.topAnchor],
        [self.moreButton.heightAnchor constraintEqualToConstant:40],[self.moreButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.moreButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],[self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.resourceButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:16],[self.resourceButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-16]]];
    [self loadSources];
}
- (void)dealloc {[self.readiness cancel];[self.client cancel];}
- (void)openResources {if(self.onResources)self.onResources();}
- (void)loadSources {
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    if(!self.sources.count){[self showMessage:@"尚未导入影视资源\n可在资源页导入 JS、Python 或 ZIP 影视包" loading:NO];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=self.sources.firstObject;for(NSDictionary *source in self.sources)if([source[@"id"] isEqual:saved])selected=source;
    [self activate:selected];
}
- (void)showMessage:(NSString *)message loading:(BOOL)loading {
    self.status.text=message;self.status.hidden=!message.length;self.resourceButton.hidden=loading || self.items.count>0;
    if(loading)[self.spinner startAnimating];else[self.spinner stopAnimating];
}
- (void)chooseSource {
    if(!self.sources.count){[self openResources];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *source in self.sources)[choices addObject:@{@"name":source[@"name"],@"subtitle":@"已导入资源",@"source":source}];
    for(NSDictionary *provider in self.providers)[choices addObject:@{@"name":provider[@"name"],@"subtitle":self.source[@"name"]?:@"",@"provider":provider[@"id"]}];
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(choice[@"source"])[owner activate:choice[@"source"]];else{owner.provider=choice[@"provider"];[owner loadHome];}};[self.navigationController pushViewController:picker animated:YES];
}
- (void)chooseFilters {
    NSArray *groups=[self.filters[self.category?:@""] isKindOfClass:NSArray.class]?self.filters[self.category?:@""]:@[];
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];NSMutableArray *choices=[NSMutableArray array];
    for(id raw in groups){if(![raw isKindOfClass:NSDictionary.class])continue;NSDictionary *group=raw;NSString *key=group[@"key"];if(![key isKindOfClass:NSString.class])continue;
        for(id rawOption in [group[@"value"] isKindOfClass:NSArray.class]?group[@"value"]:@[]){if(![rawOption isKindOfClass:NSDictionary.class])continue;NSDictionary *option=rawOption;if(![option[@"v"] isKindOfClass:NSString.class] && ![option[@"v"] isKindOfClass:NSNumber.class])continue;[choices addObject:@{@"name":[NSString stringWithFormat:@"%@ · %@",group[@"name"]?:key,option[@"n"]?:option[@"v"]],@"subtitle":[self.selectedFilters[key] isEqual:option[@"v"]]?@"已选":@"",@"key":key,@"value":option[@"v"]}];}}
    if(!choices.count){[self showMessage:@"当前分类没有筛选条件，请先选择分类" loading:NO];return;}
    picker.choices=choices;__weak typeof(self) weakSelf=self;picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner.selectedFilters)owner.selectedFilters=[NSMutableDictionary dictionary];owner.selectedFilters[choice[@"key"]]=choice[@"value"];owner.page=1;if(!owner.loading)[owner loadListing:NO];};[self.navigationController pushViewController:picker animated:YES];
}
- (void)activate:(NSDictionary *)source {
    self.generation++;NSUInteger generation=self.generation;[self.readiness cancel];[self.client cancel];self.source=source;self.provider=nil;self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.page=1;self.loading=YES;self.moreButton.hidden=YES;[self.grid reloadData];
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    [NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];[self showMessage:[NSString stringWithFormat:@"正在启动 %@…",source[@"name"]] loading:YES];
    self.client=[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue]];__weak typeof(self) weakSelf=self;
    void (^started)(NSError *)=^(NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner || owner.generation!=generation)return;
        if(error){owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];return;}
        NSURL *health=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",source[@"port"]]];
        owner.readiness=[[LocalServiceReadiness alloc] initWithURL:health timeout:25 requiresHealthJSON:YES];
        [owner.readiness start:^(NSError *failure,NSTimeInterval elapsed){
            MediaBrowserViewController *page=weakSelf;if(!page || page.generation!=generation)return;
            if(failure){page.loading=NO;[page showMessage:failure.localizedDescription loading:NO];return;}
            [page loadCapabilities];
        }];
    };
    if(self.onActivateService)self.onActivateService(source,started);else started(nil);
}
- (NSDictionary *)arguments:(NSDictionary *)args {NSMutableDictionary *value=[args mutableCopy];if(self.provider.length)value[@"provider"]=self.provider;return value;}
- (void)loadCapabilities {
    __weak typeof(self) weakSelf=self;
    [self.client call:@"capabilities" arguments:@{} completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;
        if(error){owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];return;}
        NSArray *caps=[result isKindOfClass:NSDictionary.class] && [result[@"capabilities"] isKindOfClass:NSArray.class]?result[@"capabilities"]:@[];
        NSMutableDictionary *saved=[owner.source mutableCopy];saved[@"capabilities"]=caps;[ServiceStore save:saved];owner.source=saved;
        if([caps containsObject:@"live"] && ![caps containsObject:@"detail"] && ![caps containsObject:@"play"]){owner.loading=NO;if(owner.onSubscribeLive)owner.onSubscribeLive(owner.source);else[owner showMessage:@"此资源提供直播频道，可添加到频道订阅" loading:NO];return;}
        if([caps containsObject:@"providers"]){[owner.client call:@"providers" arguments:@{} completion:^(id providers,NSError *failure){MediaBrowserViewController *page=weakSelf;if(!page)return;page.providers=[providers isKindOfClass:NSArray.class]?providers:@[];page.provider=page.providers.firstObject[@"id"];[page loadHome];}];}
        else if([caps containsObject:@"home"])[owner loadHome];
        else{owner.loading=NO;[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];}
    }];
}
- (void)loadHome {
    self.filters=@{};self.selectedFilters=[NSMutableDictionary dictionary];
    self.loading=YES;self.keyword=@"";self.category=nil;self.page=1;self.hasMore=NO;self.moreButton.hidden=YES;self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载推荐与分类…" loading:YES];
    __weak typeof(self) weakSelf=self;
    [self.client call:@"home" arguments:[self arguments:@{}] completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.loading=NO;
        if(error){[owner showMessage:error.localizedDescription loading:NO];return;}
        if(owner.keyword.length || owner.category.length){owner.page=1;[owner loadListing:NO];return;}
        owner.items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];[owner.grid reloadData];
        owner.filters=[result[@"filters"] isKindOfClass:NSDictionary.class]?result[@"filters"]:@{};
        for(UIView *view in owner.categories.arrangedSubviews){[owner.categories removeArrangedSubview:view];[view removeFromSuperview];}
        for(NSDictionary *category in result[@"categories"]){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:category[@"name"] forState:UIControlStateNormal];button.accessibilityIdentifier=category[@"id"];[button addTarget:owner action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[owner.categories addArrangedSubview:button];}
        [owner showMessage:owner.items.count?@"":@"选择分类或输入关键词搜索" loading:NO];
    }];
}
- (void)selectCategory:(UIButton *)button {self.category=button.accessibilityIdentifier;self.selectedFilters=[NSMutableDictionary dictionary];self.keyword=@"";self.search.searchBar.text=@"";self.page=1;if(!self.loading)[self loadListing:NO];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *keyword=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.keyword=keyword;
    NSUInteger generation=++self.searchGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner || owner.searchGeneration!=generation || !owner.source || owner.loading)return;owner.page=1;if(keyword.length)[owner loadListing:NO];else if(!owner.category.length)[owner loadHome];});
}
- (void)loadMore {if(!self.loading && self.hasMore){self.page++;[self loadListing:YES];}}
- (void)loadListing:(BOOL)append {
    if(!self.source)return;if(!self.keyword.length && !self.category.length){[self loadHome];return;}self.loading=YES;NSString *operation=self.keyword.length?@"search":@"category";NSString *requestedKeyword=self.keyword?:@"",*requestedCategory=self.category?:@"";
    NSMutableDictionary *args=[[self arguments:@{@"page":@(self.page)}] mutableCopy];if(self.keyword.length)args[@"keyword"]=self.keyword;else args[@"categoryId"]=self.category?:@"";
    args[@"filters"]=self.selectedFilters?:@{};NSDictionary *requestedFilters=[self.selectedFilters copy]?:@{};
    if(!append){self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载…" loading:YES];}self.moreButton.enabled=NO;
    __weak typeof(self) weakSelf=self;
    [self.client call:operation arguments:args completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.loading=NO;owner.moreButton.enabled=YES;
        if(![requestedKeyword isEqualToString:owner.keyword?:@""] || (!requestedKeyword.length && (![requestedCategory isEqualToString:owner.category?:@""] || ![requestedFilters isEqual:owner.selectedFilters?:@{}]))){owner.page=1;[owner loadListing:NO];return;}
        if(error){if(append)owner.page=MAX(1,owner.page-1);[owner showMessage:error.localizedDescription loading:NO];return;}
        NSArray *incoming=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];
        NSMutableArray *all=append?[owner.items mutableCopy]:[NSMutableArray array];NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *item in all)[ids addObject:item[@"id"]];for(NSDictionary *item in incoming)if(![ids containsObject:item[@"id"]]){[all addObject:item];[ids addObject:item[@"id"]];}
        owner.items=all;owner.hasMore=[result[@"hasMore"] boolValue];owner.moreButton.hidden=!owner.hasMore;[owner.grid reloadData];[owner showMessage:all.count?@"":@"没有找到影片，请更换关键词或分类" loading:NO];
    }];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.items.count;}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {NSInteger columns=collectionView.bounds.size.width>700?4:2;CGFloat width=floor((collectionView.bounds.size.width-28-(columns-1)*10)/columns);return CGSizeMake(width,width*1.4+44);}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    UICollectionViewCell *cell=[collectionView dequeueReusableCellWithReuseIdentifier:@"movie" forIndexPath:ip];for(UIView *view in cell.contentView.subviews.copy)[view removeFromSuperview];NSDictionary *item=self.items[ip.item];CGFloat width=cell.bounds.size.width,posterHeight=width*1.4;
    cell.contentView.backgroundColor=HostCard();cell.contentView.layer.cornerRadius=10;cell.contentView.clipsToBounds=YES;
    UIImageView *poster=[[UIImageView alloc] initWithFrame:CGRectMake(0,0,width,posterHeight)];poster.contentMode=UIViewContentModeScaleAspectFill;poster.clipsToBounds=YES;[cell.contentView addSubview:poster];if([item[@"poster"] length])[HostImageLoader.shared loadURL:item[@"poster"] intoImageView:poster];
    UILabel *name=[[UILabel alloc] initWithFrame:CGRectMake(8,posterHeight+3,width-16,20)];name.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];name.textColor=UIColor.labelColor;name.text=item[@"name"];[cell.contentView addSubview:name];
    UILabel *remarks=[[UILabel alloc] initWithFrame:CGRectMake(8,posterHeight+23,width-16,16)];remarks.font=[UIFont systemFontOfSize:11];remarks.textColor=UIColor.secondaryLabelColor;remarks.text=item[@"remarks"];[cell.contentView addSubview:remarks];cell.accessibilityLabel=[NSString stringWithFormat:@"%@，%@",item[@"name"],item[@"remarks"]?:@""];return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=self.items[ip.item];detail.source=self.source;detail.provider=self.provider;detail.onPlay=self.onPlay;[self.navigationController pushViewController:detail animated:YES];
}
@end
