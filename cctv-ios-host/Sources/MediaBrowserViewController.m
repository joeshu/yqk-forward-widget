#import "MediaBrowserViewController.h"
#import "MediaAPIClient.h"
#import "HostImageLoader.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "LocalServiceReadiness.h"
#import "ServiceStore.h"
#import "MediaEpisodeSelectionViewController.h"
#import <math.h>

@interface MediaSourcePicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSDictionary *> *choices;
@property(nonatomic, copy) NSArray<NSDictionary *> *shown;
@property(nonatomic, copy) void (^onSelect)(NSDictionary *);
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic,copy) NSString *screenTitle;
@end
@implementation MediaSourcePicker
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewDidLoad {[super viewDidLoad];self.title=self.screenTitle?:@"影视资源";self.shown=self.choices;self.tableView.backgroundColor=UIColor.blackColor;self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchResultsUpdater=self;self.search.searchBar.placeholder=[self.title isEqual:@"影视站点"]?@"搜索当前资源的站点":@"搜索影视资源";self.navigationItem.searchController=self.search;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.shown.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"source"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];NSDictionary *choice=self.shown[index.row];cell.textLabel.text=choice[@"name"];cell.detailTextLabel.text=choice[@"subtitle"];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {NSString *query=controller.searchBar.text?:@"";self.shown=query.length?[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){return [choice[@"name"] rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound || [choice[@"subtitle"] rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound;}]]:self.choices;[self.tableView reloadData];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {NSDictionary *choice=self.shown[index.row];[self.navigationController popViewControllerAnimated:YES];if(self.onSelect)self.onSelect(choice);}
@end


@interface MediaDetailViewController : UITableViewController
@property(nonatomic,copy) NSDictionary *item;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic,copy) NSString *provider;
@property(nonatomic,copy) NSDictionary *detail;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic,copy) void (^onPlay)(NSDictionary *,NSDictionary *);
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIView *detailHeader;
@property(nonatomic,strong) UIImageView *posterView;
@property(nonatomic) NSUInteger generation;
@end
@implementation MediaDetailViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (void)viewDidLoad {[super viewDidLoad];self.title=self.item[@"name"]?:@"影片详情";self.view.backgroundColor=UIColor.blackColor;self.tableView.backgroundColor=UIColor.blackColor;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=92;self.status=[UILabel new];self.status.textAlignment=NSTextAlignmentCenter;self.status.textColor=UIColor.secondaryLabelColor;self.status.numberOfLines=0;self.tableView.backgroundView=self.status;self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadDetail)];self.client=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];[self buildDetailHeader];[self loadDetail];}
- (void)buildDetailHeader {UIView *header=[UIView new];header.backgroundColor=UIColor.clearColor;header.frame=CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),196);header.translatesAutoresizingMaskIntoConstraints=YES;UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=HostCard();card.layer.cornerRadius=18;card.clipsToBounds=YES;[header addSubview:card];self.posterView=[UIImageView new];self.posterView.translatesAutoresizingMaskIntoConstraints=NO;self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;self.posterView.layer.cornerRadius=10;[card addSubview:self.posterView];UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];name.adjustsFontForContentSizeCategory=YES;name.textColor=UIColor.labelColor;name.numberOfLines=3;name.text=self.item[@"name"]?:@"影片详情";[card addSubview:name];UILabel *remarks=[UILabel new];remarks.translatesAutoresizingMaskIntoConstraints=NO;remarks.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];remarks.adjustsFontForContentSizeCategory=YES;remarks.textColor=UIColor.secondaryLabelColor;remarks.numberOfLines=3;remarks.text=[NSString stringWithFormat:@"%@\n%@",self.item[@"remarks"]?:@"",self.source[@"name"]?:@"影视资源"];[card addSubview:remarks];[NSLayoutConstraint activateConstraints:@[[card.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],[card.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],[card.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],[card.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],[self.posterView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],[self.posterView.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],[self.posterView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],[self.posterView.widthAnchor constraintEqualToConstant:112],[name.leadingAnchor constraintEqualToAnchor:self.posterView.trailingAnchor constant:14],[name.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],[name.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],[remarks.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],[remarks.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],[remarks.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:8],[remarks.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-12]]];self.detailHeader=header;self.tableView.tableHeaderView=header;[self refreshDetailHeader];}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];if(self.detailHeader&&fabs(self.detailHeader.frame.size.width-self.tableView.bounds.size.width)>0.5){CGRect frame=self.detailHeader.frame;frame.size.width=self.tableView.bounds.size.width;self.detailHeader.frame=frame;self.tableView.tableHeaderView=self.detailHeader;}}
- (void)refreshDetailHeader {NSString *poster=[self.detail[@"poster"] isKindOfClass:NSString.class]?self.detail[@"poster"]:([self.item[@"poster"] isKindOfClass:NSString.class]?self.item[@"poster"]:@"");self.posterView.image=nil;if(poster.length)[HostImageLoader.shared loadURL:poster intoImageView:self.posterView];}
- (void)dealloc {[self.client cancel];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController){self.generation++;[self.client cancel];}}
- (void)loadDetail {NSUInteger generation=++self.generation;self.detail=nil;self.status.text=@"正在加载影片详情…";[self.tableView reloadData];NSMutableDictionary *args=[@{@"id":self.item[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;[self.client call:@"detail" arguments:args completion:^(id result,NSError *error){MediaDetailViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;if(error||![result isKindOfClass:NSDictionary.class]){owner.status.text=error.localizedDescription?:@"来源没有提供影片详情";return;}owner.detail=result;owner.status.text=@"";owner.title=result[@"name"]?:owner.title;[owner refreshDetailHeader];[owner.tableView reloadData];}];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return self.detail?2:0;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return 1;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return section==0?@"影片简介":@"播放内容";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.backgroundColor=HostCard();cell.textLabel.textColor=UIColor.labelColor;cell.textLabel.font=[UIFont preferredFontForTextStyle:ip.section==0?UIFontTextStyleBody:UIFontTextStyleHeadline];cell.textLabel.numberOfLines=0;cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.detailTextLabel.numberOfLines=0;
    if(ip.section==0){cell.textLabel.text=self.detail[@"name"]?:self.item[@"name"]?:@"影片详情";NSString *synopsis=[self.detail[@"description"] isKindOfClass:NSString.class]?self.detail[@"description"]:@"暂无简介";if(synopsis.length>5000)synopsis=[synopsis substringToIndex:5000];cell.detailTextLabel.text=synopsis;cell.selectionStyle=UITableViewCellSelectionStyleNone;}
    else{NSUInteger count=0;NSMutableArray *names=[NSMutableArray array];for(NSDictionary *line in self.lines){NSArray *episodes=[line[@"episodes"] isKindOfClass:NSArray.class]?line[@"episodes"]:@[];count+=episodes.count;if([line[@"name"] isKindOfClass:NSString.class])[names addObject:line[@"name"]];}cell.textLabel.text=count?[NSString stringWithFormat:@"选择线路和分集 · %lu 集",(unsigned long)count]:@"此来源没有提供可播放分集";cell.detailTextLabel.text=names.count?[names componentsJoinedByString:@"  ·  "]:@"返回资源页或更换来源";cell.accessoryType=count?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;cell.selectionStyle=count?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;}
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {[tableView deselectRowAtIndexPath:ip animated:YES];if(ip.section!=1||!self.lines.count)return;MediaEpisodeSelectionViewController *episodes=[MediaEpisodeSelectionViewController new];episodes.item=self.item;episodes.source=self.source;episodes.provider=self.provider;episodes.detail=self.detail;episodes.client=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];episodes.onSelectEpisode=self.onPlay;[self.navigationController pushViewController:episodes animated:YES];}
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
@property(nonatomic) NSInteger widgetEpisode;
@property(nonatomic) NSInteger widgetSeason;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL hasMore;
@property(nonatomic) BOOL loading;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger searchGeneration;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *browseStates;
@property(nonatomic,copy) NSDictionary *pendingBrowseState;
@property(nonatomic,strong) NSNumber *pendingRestoreOffset;
@property(nonatomic) NSInteger pendingRestorePage;
@property(nonatomic, copy) NSDictionary *filters;
@property(nonatomic, strong) NSMutableDictionary *selectedFilters;
@end
@implementation MediaBrowserViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"影视";self.view.backgroundColor=UIColor.blackColor;self.items=@[];self.keyword=@"";
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"搜索当前影视来源";self.navigationItem.searchController=self.search;
    __weak typeof(self) weakSelf=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"square.stack",@"title":@"选择影视资源",@"action":[UIAction actionWithHandler:^(UIAction *action){[weakSelf chooseResource];}]},
        @{@"icon":@"globe",@"title":@"选择影视站点",@"action":[UIAction actionWithHandler:^(UIAction *action){[weakSelf chooseProvider];}]},
        @{@"icon":@"ellipsis",@"title":@"更多影视操作",@"menu":[UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"分类筛选" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(UIAction *action){[weakSelf chooseFilters];}],
            [UIAction actionWithTitle:@"刷新当前来源" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action){if(weakSelf.source)[weakSelf activate:weakSelf.source];else[weakSelf loadSources];}]
        ]]}
    ])];
    self.categoryScroll=[UIScrollView new];self.categoryScroll.showsHorizontalScrollIndicator=NO;self.categoryScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.categoryScroll.translatesAutoresizingMaskIntoConstraints=NO;
    self.categories=[[UIStackView alloc] init];self.categories.axis=UILayoutConstraintAxisHorizontal;self.categories.spacing=10;self.categories.translatesAutoresizingMaskIntoConstraints=NO;[self.categoryScroll addSubview:self.categories];[self.view addSubview:self.categoryScroll];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];layout.minimumInteritemSpacing=10;layout.minimumLineSpacing=16;layout.sectionInset=UIEdgeInsetsMake(12,14,16,14);
    self.grid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];self.grid.translatesAutoresizingMaskIntoConstraints=NO;self.grid.backgroundColor=UIColor.blackColor;self.grid.dataSource=self;self.grid.delegate=self;self.grid.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self.grid registerClass:UICollectionViewCell.class forCellWithReuseIdentifier:@"movie"];[self.view addSubview:self.grid];
    self.moreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.moreButton.translatesAutoresizingMaskIntoConstraints=NO;[self.moreButton setTitle:@"加载更多" forState:UIControlStateNormal];HostStylePillButton(self.moreButton,YES);[self.moreButton addTarget:self action:@selector(loadMore) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.moreButton];self.moreButton.hidden=YES;
    self.status=[UILabel new];self.status.textColor=UIColor.secondaryLabelColor;self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.status];
    self.resourceButton=[UIButton buttonWithType:UIButtonTypeSystem];self.resourceButton.translatesAutoresizingMaskIntoConstraints=NO;[self.resourceButton setTitle:@"管理资源" forState:UIControlStateNormal];HostStylePillButton(self.resourceButton,NO);[self.resourceButton addTarget:self action:@selector(openResources) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.resourceButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.categoryScroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.categoryScroll.heightAnchor constraintEqualToConstant:44],
        [self.categories.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor constant:14],[self.categories.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor constant:-14],[self.categories.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor constant:4],[self.categories.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor constant:-4],[self.categories.heightAnchor constraintEqualToConstant:36],
        [self.grid.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor],[self.grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.grid.bottomAnchor constraintEqualToAnchor:self.moreButton.topAnchor],
        [self.moreButton.heightAnchor constraintEqualToConstant:40],[self.moreButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.moreButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],[self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.resourceButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:16],[self.resourceButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-16]]];
    [self loadSources];
}
- (void)dealloc {[self.readiness cancel];[self.client cancel];}
- (NSString *)stateKeyForSource:(NSDictionary *)source provider:(NSString *)provider {return [NSString stringWithFormat:@"%@|%@",source[@"id"]?:@"",provider?:@""];}
- (void)saveCurrentBrowseState {if(!self.source)return;if(!self.browseStates)self.browseStates=[NSMutableDictionary dictionary];NSString *key=[self stateKeyForSource:self.source provider:self.provider];self.browseStates[key]=@{@"keyword":self.keyword?:@"",@"category":self.category?:@"",@"filters":self.selectedFilters?:@{},@"provider":self.provider?:@"",@"page":@(MAX(1,self.page)),@"season":@(MAX(1,self.widgetSeason)),@"episode":@(MAX(1,self.widgetEpisode)),@"offset":@(MAX(0,self.grid.contentOffset.y))};}
- (void)restorePendingBrowseState {NSDictionary *state=self.pendingBrowseState;self.pendingBrowseState=nil;if(!state)return;self.keyword=state[@"keyword"]?:@"";self.category=state[@"category"];self.selectedFilters=[state[@"filters"] isKindOfClass:NSDictionary.class]?[state[@"filters"] mutableCopy]:[NSMutableDictionary dictionary];self.pendingRestorePage=MAX(1,MIN(100,[state[@"page"] integerValue]));self.page=self.pendingRestorePage;self.widgetSeason=MAX(1,[state[@"season"] integerValue]);self.widgetEpisode=MAX(1,[state[@"episode"] integerValue]);self.pendingRestoreOffset=@([state[@"offset"] doubleValue]);self.search.searchBar.text=self.keyword;self.navigationItem.prompt=[self.source[@"protocol"] isEqual:@"widget-extractor"]?[NSString stringWithFormat:@"第 %ld 季 · 第 %ld 集",(long)self.widgetSeason,(long)self.widgetEpisode]:nil;for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.category];button.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:[UIColor colorWithWhite:1 alpha:0.09];button.layer.borderColor=selected?[HostAccent() colorWithAlphaComponent:0.42].CGColor:[UIColor colorWithWhite:1 alpha:0.10].CGColor;[button setTitleColor:selected?HostAccent():UIColor.whiteColor forState:UIControlStateNormal];}if(self.keyword.length||self.category.length){self.page=1;[self loadListing:NO];return;}self.pendingRestorePage=0;CGFloat offset=self.pendingRestoreOffset.doubleValue;self.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[self.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
- (void)openResources {if(self.onResources)self.onResources();}
- (void)loadSources {
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    if(!self.sources.count){[self showMessage:@"尚未导入影视资源\n可在资源页导入 JS、Python 或 ZIP 影视包" loading:NO];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=self.sources.firstObject;for(NSDictionary *source in self.sources)if([source[@"id"] isEqual:saved])selected=source;
    [self activate:selected];
}
- (void)refreshSources {
    NSArray<NSDictionary *> *updated=self.sourcesProvider?self.sourcesProvider():@[];
    self.sources=updated;
    if(!updated.count){
        self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.source=nil;self.provider=nil;self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.loading=NO;self.moreButton.hidden=YES;[self.grid reloadData];
        for(UIView *view in self.categories.arrangedSubviews.copy){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
        [self showMessage:@"尚未导入影视资源\n可在资源页导入 JS、Python 或 ZIP 影视包" loading:NO];return;
    }
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:self.source[@"id"]]){self.source=candidate;return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=updated.firstObject;
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:saved]){selected=candidate;break;}
    [self activate:selected];
}
- (void)showMessage:(NSString *)message loading:(BOOL)loading {
    self.status.text=message;self.status.hidden=!message.length;self.resourceButton.hidden=loading || self.items.count>0;
    if(loading)[self.spinner startAnimating];else[self.spinner stopAnimating];
}
- (void)chooseResource {
    if(!self.sources.count){[self openResources];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *source in self.sources){BOOL current=[source[@"id"] isEqual:self.source[@"id"]];[choices addObject:@{@"name":source[@"name"]?:@"影视资源",@"subtitle":current?@"当前资源":@"已导入资源",@"source":source}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"影视资源";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(choice[@"source"])[owner activate:choice[@"source"]];};[self.navigationController pushViewController:picker animated:YES];
}
- (void)chooseProvider {
    if(!self.source){[self openResources];return;}if(!self.providers.count){[self showMessage:@"当前影视资源没有公开多个站点，或尚未加载站点列表" loading:NO];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *provider in self.providers){BOOL current=[provider[@"id"] isEqual:self.provider];[choices addObject:@{@"name":provider[@"name"]?:provider[@"id"]?:@"影视站点",@"subtitle":current?@"当前站点":(self.source[@"name"]?:@"当前影视资源"),@"provider":provider[@"id"]?:@""}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"影视站点";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner||![choice[@"provider"] length]||[owner.provider isEqual:choice[@"provider"]])return;[owner saveCurrentBrowseState];owner.provider=choice[@"provider"];[NSUserDefaults.standardUserDefaults setObject:owner.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",owner.source[@"id"]]];owner.pendingBrowseState=owner.browseStates[[owner stateKeyForSource:owner.source provider:owner.provider]];[owner loadHome];};[self.navigationController pushViewController:picker animated:YES];
}
- (void)chooseFilters {
    if([self.source[@"protocol"] isEqual:@"widget-extractor"]){[self chooseWidgetEpisode];return;}
    NSArray *groups=[self.filters[self.category?:@""] isKindOfClass:NSArray.class]?self.filters[self.category?:@""]:@[];
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"分类筛选";NSMutableArray *choices=[NSMutableArray array];
    for(id raw in groups){if(![raw isKindOfClass:NSDictionary.class])continue;NSDictionary *group=raw;NSString *key=group[@"key"];if(![key isKindOfClass:NSString.class])continue;
        for(id rawOption in [group[@"value"] isKindOfClass:NSArray.class]?group[@"value"]:@[]){if(![rawOption isKindOfClass:NSDictionary.class])continue;NSDictionary *option=rawOption;if(![option[@"v"] isKindOfClass:NSString.class] && ![option[@"v"] isKindOfClass:NSNumber.class])continue;[choices addObject:@{@"name":[NSString stringWithFormat:@"%@ · %@",group[@"name"]?:key,option[@"n"]?:option[@"v"]],@"subtitle":[self.selectedFilters[key] isEqual:option[@"v"]]?@"已选":@"",@"key":key,@"value":option[@"v"]}];}}
    if(!choices.count){[self showMessage:@"当前分类没有筛选条件，请先选择分类" loading:NO];return;}
    picker.choices=choices;__weak typeof(self) weakSelf=self;picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner.selectedFilters)owner.selectedFilters=[NSMutableDictionary dictionary];owner.selectedFilters[choice[@"key"]]=choice[@"value"];owner.page=1;if(!owner.loading)[owner loadListing:NO];};[self.navigationController pushViewController:picker animated:YES];
}
- (void)chooseWidgetEpisode {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"解析指定季 / 集" message:@"先输入完整剧名。电影选择第 1 集；剧集按来源实际提供的季和集解析。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"季（1–999）";field.keyboardType=UIKeyboardTypeNumberPad;field.text=[NSString stringWithFormat:@"%ld",(long)MAX(1,self.widgetSeason)];}];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"集（1–9999）";field.keyboardType=UIKeyboardTypeNumberPad;field.text=[NSString stringWithFormat:@"%ld",(long)MAX(1,self.widgetEpisode)];}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"应用并解析" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.widgetSeason=MAX(1,MIN(999,[alert.textFields[0].text integerValue]));owner.widgetEpisode=MAX(1,MIN(9999,[alert.textFields[1].text integerValue]));owner.navigationItem.prompt=[NSString stringWithFormat:@"第 %ld 季 · 第 %ld 集 · 工具栏筛选可修改",(long)owner.widgetSeason,(long)owner.widgetEpisode];owner.page=1;if(owner.keyword.length&&!owner.loading)[owner loadListing:NO];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)activate:(NSDictionary *)source {
    [self saveCurrentBrowseState];self.generation++;NSUInteger generation=self.generation;[self.readiness cancel];[self.client cancel];self.source=source;NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",source[@"id"]]];self.provider=nil;self.pendingBrowseState=self.browseStates[[self stateKeyForSource:source provider:preferredProvider]]?:self.browseStates[[self stateKeyForSource:source provider:nil]];self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.page=1;self.loading=YES;self.moreButton.hidden=YES;[self.grid reloadData];
    self.widgetSeason=1;self.widgetEpisode=1;BOOL widget=[source[@"protocol"] isEqual:@"widget-extractor"];self.navigationItem.prompt=widget?@"第 1 季 · 第 1 集 · 工具栏筛选可修改":nil;self.search.searchBar.placeholder=widget?@"输入完整剧名，筛选中选择季 / 集":@"搜索当前影视来源";
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    [NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];[self showMessage:[NSString stringWithFormat:@"正在启动 %@…",source[@"name"]] loading:YES];
    self.client=[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue]];__weak typeof(self) weakSelf=self;
    void (^started)(NSError *)=^(NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner || owner.generation!=generation)return;
        if(error){owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];return;}
        NSURL *health=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",source[@"port"]]];
        owner.readiness=[[LocalServiceReadiness alloc] initWithURL:health timeout:25 requiresHealthJSON:YES];
        owner.readiness.failureProvider=owner.startupErrorProvider;
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
        if([caps containsObject:@"providers"]){[owner.client call:@"providers" arguments:@{} completion:^(id providers,NSError *failure){MediaBrowserViewController *page=weakSelf;if(!page)return;page.providers=[providers isKindOfClass:NSArray.class]?providers:@[];NSString *savedProvider=page.pendingBrowseState[@"provider"];NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",page.source[@"id"]]];NSString *chosen=savedProvider.length?savedProvider:preferredProvider;BOOL found=NO;for(NSDictionary *candidate in page.providers)if([candidate[@"id"] isEqual:chosen]){found=YES;break;}page.provider=found?chosen:page.providers.firstObject[@"id"];if(page.provider)[NSUserDefaults.standardUserDefaults setObject:page.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",page.source[@"id"]]];if(page.pendingBrowseState.count){NSMutableDictionary *state=[page.pendingBrowseState mutableCopy];state[@"provider"]=page.provider?:@"";page.pendingBrowseState=state;}[page loadHome];}];}
        else if([caps containsObject:@"home"])[owner loadHome];
        else{owner.loading=NO;if(owner.pendingBrowseState){NSDictionary *pending=owner.pendingBrowseState;[owner restorePendingBrowseState];if(![pending[@"keyword"] length])[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];}else[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];}
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
        for(NSDictionary *category in result[@"categories"]){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:category[@"name"] forState:UIControlStateNormal];HostStylePillButton(button,NO);button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];button.accessibilityIdentifier=category[@"id"];[button addTarget:owner action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[owner.categories addArrangedSubview:button];}
        if(owner.pendingBrowseState){[owner restorePendingBrowseState];return;}
        [owner showMessage:owner.items.count?@"":@"选择分类或输入关键词搜索" loading:NO];
    }];
}
- (void)selectCategory:(UIButton *)button {self.category=button.accessibilityIdentifier;self.selectedFilters=[NSMutableDictionary dictionary];self.keyword=@"";self.search.searchBar.text=@"";for(UIButton *item in self.categories.arrangedSubviews){BOOL selected=item==button;item.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:[UIColor colorWithWhite:1 alpha:0.09];item.layer.borderColor=selected?[HostAccent() colorWithAlphaComponent:0.42].CGColor:[UIColor colorWithWhite:1 alpha:0.10].CGColor;[item setTitleColor:selected?HostAccent():UIColor.whiteColor forState:UIControlStateNormal];}self.page=1;if(!self.loading)[self loadListing:NO];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *keyword=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.keyword=keyword;
    NSUInteger generation=++self.searchGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner || owner.searchGeneration!=generation || !owner.source || owner.loading)return;owner.page=1;if(keyword.length)[owner loadListing:NO];else if(!owner.category.length)[owner loadHome];});
}
- (void)loadMore {if(!self.loading && self.hasMore){self.page++;[self loadListing:YES];}}
- (void)loadListing:(BOOL)append {
    if(!self.source)return;if(!self.keyword.length && !self.category.length){[self loadHome];return;}self.loading=YES;NSString *operation=self.keyword.length?@"search":@"category";NSString *requestedKeyword=self.keyword?:@"",*requestedCategory=self.category?:@"";
    NSInteger requestedPage=self.page;
    NSMutableDictionary *args=[[self arguments:@{@"page":@(self.page)}] mutableCopy];if(self.keyword.length)args[@"keyword"]=self.keyword;else args[@"categoryId"]=self.category?:@"";
    NSInteger episode=self.widgetEpisode,season=self.widgetSeason;if([self.source[@"protocol"] isEqual:@"widget-extractor"]){args[@"episode"]=@(MAX(1,episode));args[@"season"]=@(MAX(1,season));}
    args[@"filters"]=self.selectedFilters?:@{};NSDictionary *requestedFilters=[self.selectedFilters copy]?:@{};
    if(!append){self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载…" loading:YES];}self.moreButton.enabled=NO;
    __weak typeof(self) weakSelf=self;
    [self.client call:operation arguments:args completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.loading=NO;owner.moreButton.enabled=YES;
        if(episode!=owner.widgetEpisode || season!=owner.widgetSeason || ![requestedKeyword isEqualToString:owner.keyword?:@""] || (!requestedKeyword.length && (![requestedCategory isEqualToString:owner.category?:@""] || ![requestedFilters isEqual:owner.selectedFilters?:@{}]))){owner.page=1;[owner loadListing:NO];return;}
        if(error){if(append)owner.page=MAX(1,owner.page-1);[owner showMessage:error.localizedDescription loading:NO];return;}
        NSArray *incoming=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];
        NSMutableArray *all=append?[owner.items mutableCopy]:[NSMutableArray array];NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *item in all)[ids addObject:item[@"id"]];for(NSDictionary *item in incoming)if(![ids containsObject:item[@"id"]]){[all addObject:item];[ids addObject:item[@"id"]];}
        owner.items=all;if(owner.pendingRestorePage>requestedPage && [result[@"hasMore"] boolValue] && incoming.count && requestedPage<owner.pendingRestorePage){owner.page=requestedPage+1;[owner loadListing:YES];return;}if(owner.pendingRestorePage){owner.page=requestedPage;owner.pendingRestorePage=0;}owner.hasMore=[result[@"hasMore"] boolValue];owner.moreButton.hidden=!owner.hasMore;[owner.grid reloadData];[owner showMessage:all.count?@"":@"没有找到影片，请更换关键词或分类" loading:NO];
        if(owner.pendingRestoreOffset){CGFloat offset=owner.pendingRestoreOffset.doubleValue;owner.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[owner.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
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
