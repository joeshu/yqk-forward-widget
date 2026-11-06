#import "MediaGlobalSearchViewController.h"
#import "MediaAPIClient.h"
#import "LocalServiceReadiness.h"
#import "HostTheme.h"
#import "PyHost.h"
#import "MediaSourceHealthStore.h"
#import "HostImageLoader.h"
#import "MediaSearchResults.h"
#import <math.h>

static void MediaSearchLoadPosterWithRetry(NSString *url, UIImageView *view, NSUInteger retriesRemaining);
static void MediaSearchLoadPosterWithRetry(NSString *url, UIImageView *view, NSUInteger retriesRemaining) {
    if(!url.length||!view)return;__weak UIImageView *weakView=view;
    [HostImageLoader.shared loadPosterURL:url intoImageView:view completion:^(BOOL succeeded,NSTimeInterval retryAfter){if(succeeded||!retriesRemaining||retryAfter<=0)return;NSTimeInterval delay=MIN(120.0,MAX(1.0,retryAfter+0.25));dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{UIImageView *current=weakView;if(current&&current.window&&[current.accessibilityIdentifier isEqualToString:url])MediaSearchLoadPosterWithRetry(url,current,retriesRemaining-1);});}];
}

static const NSUInteger MediaGlobalSearchMaximumResults = 100;
static const NSUInteger MediaGlobalSearchMaximumConcurrentSources = 3;

@interface MediaGlobalSearchJob : NSObject
@property(nonatomic) NSUInteger section;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) CFTimeInterval startedAt;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic,strong) LocalServiceReadiness *readiness;
@property(nonatomic,copy) NSArray<NSDictionary *> *providers;
@property(nonatomic) NSUInteger providerIndex;
@property(nonatomic) NSUInteger successfulProviderCount;
@property(nonatomic,copy) NSArray<NSDictionary *> *failedProviders;
@property(nonatomic,copy) NSString *providerFailure;
@end
@implementation MediaGlobalSearchJob @end

@interface MediaSearchResultCell : UITableViewCell
@property(nonatomic,strong) UIImageView *poster;
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *metadataLabel;
@property(nonatomic,strong) UILabel *sourceLabel;
@property(nonatomic,copy) NSDictionary *searchEntry;
@end
@implementation MediaSearchResultCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if((self=[super initWithStyle:style reuseIdentifier:identifier])){
        self.backgroundColor=HostCard();
        self.layer.cornerRadius=14;self.layer.cornerCurve=kCACornerCurveContinuous;self.clipsToBounds=YES;self.layer.borderWidth=0.6;HostSetLayerBorderColor(self,HostBorder());
        self.poster=[UIImageView new];self.poster.translatesAutoresizingMaskIntoConstraints=NO;self.poster.contentMode=UIViewContentModeScaleAspectFill;self.poster.clipsToBounds=YES;self.poster.layer.cornerRadius=10;self.poster.layer.cornerCurve=kCACornerCurveContinuous;self.poster.layer.borderWidth=0.6;HostSetLayerBorderColor(self.poster,HostBorder());
        self.nameLabel=[UILabel new];self.nameLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];self.nameLabel.numberOfLines=2;
        self.metadataLabel=[UILabel new];self.metadataLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.metadataLabel.numberOfLines=2;
        self.sourceLabel=[UILabel new];self.sourceLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.sourceLabel.numberOfLines=2;
        for(UILabel *label in @[self.nameLabel,self.metadataLabel,self.sourceLabel])label.adjustsFontForContentSizeCategory=YES;
        UIStackView *text=[[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel,self.metadataLabel,self.sourceLabel]];text.axis=UILayoutConstraintAxisVertical;text.spacing=6;text.translatesAutoresizingMaskIntoConstraints=NO;
        [self.contentView addSubview:self.poster];[self.contentView addSubview:text];
        [NSLayoutConstraint activateConstraints:@[[self.poster.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],[self.poster.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],[self.poster.widthAnchor constraintEqualToConstant:66],[self.poster.heightAnchor constraintEqualToConstant:96],[self.poster.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12],[text.leadingAnchor constraintEqualToAnchor:self.poster.trailingAnchor constant:14],[text.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],[text.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],[text.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12]]];
    }return self;
}
- (void)prepareForReuse {[super prepareForReuse];self.poster.image=nil;self.poster.accessibilityIdentifier=nil;self.searchEntry=nil;}
@end

@interface MediaGlobalSearchViewController () <UISearchBarDelegate>
@property(nonatomic,strong) UISearchBar *searchBar;
@property(nonatomic,strong) UISegmentedControl *scopeControl;
@property(nonatomic,copy) NSArray<NSDictionary *> *availableSources;
@property(nonatomic,copy) NSArray<NSDictionary *> *searchSources;
@property(nonatomic,copy) NSDictionary *currentSiteSource;
@property(nonatomic) BOOL currentSiteScope;
@property(nonatomic,strong) UIButton *historyButton;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic,strong) UIScrollView *filterScroll;
@property(nonatomic,strong) UIStackView *filterStack;
@property(nonatomic,copy) NSArray<NSDictionary *> *filterChoices;
@property(nonatomic,copy) NSString *renderedFilterKey;
@property(nonatomic) NSInteger selectedSourceSection;
@property(nonatomic,copy) NSString *selectedProvider;
@property(nonatomic) BOOL resultsVisible;
@property(nonatomic) BOOL restoringSearch;
@property(nonatomic) CGPoint savedSearchOffset;
@property(nonatomic,copy) NSDictionary *savedReadingPosition;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *filterOffsets;

@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *rows;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,MediaGlobalSearchJob *> *jobs;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *pendingSections;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *retrySections;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger resultCount;
@property(nonatomic) NSUInteger completedCount;
@property(nonatomic) NSUInteger scheduledCount;
@property(nonatomic) BOOL searching;
@property(nonatomic) BOOL resultLimitReached;
@property(nonatomic,copy) NSString *keyword;
@property(nonatomic,copy) NSArray<NSString *> *searchHistory;
- (void)updateFilters;
- (NSArray *)visibleEntriesForSection:(NSInteger)section;
- (void)restoreOffset:(CGPoint)offset;
- (NSDictionary *)readingPosition;
- (void)restoreReadingPosition:(NSDictionary *)position;
- (void)sortPendingSectionsByHealth;
- (void)showSearchHistory;
- (void)updateEmptyState;
- (void)rememberSearchKeyword:(NSString *)keyword;
- (void)changeSearchScope:(UISegmentedControl *)sender;
- (void)updateSearchScopePresentation;
@end

@implementation MediaGlobalSearchViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"搜索影视";
    self.availableSources = [self.sources copy] ?: @[];
    for(NSDictionary *source in self.availableSources)if(self.currentSourceID.length&&[[source[@"id"] description] isEqual:self.currentSourceID]){self.currentSiteSource=source;break;}
    self.currentSiteScope=self.currentSiteSource!=nil;
    self.searchSources=self.currentSiteScope?@[self.currentSiteSource]:self.availableSources;
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.tableFooterView = [UIView new];
    self.rows = [NSMutableArray array];
    self.jobs = [NSMutableDictionary dictionary];
    self.pendingSections = [NSMutableArray array];
    self.retrySections = [NSMutableSet set];
    self.keyword = @"";self.selectedSourceSection=-1;self.filterOffsets=[NSMutableDictionary dictionary];
    NSArray *history=[NSUserDefaults.standardUserDefaults arrayForKey:@"media.globalSearchHistory.v1"];
    self.searchHistory=[history isKindOfClass:NSArray.class]?history:@[];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(searchHistoryCleared:) name:@"MediaGlobalSearchHistoryDidChange" object:nil];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(1, self.tableView.bounds.size.width), 104)];
    header.backgroundColor = HostBackground();
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索所有已导入影视来源";
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    [header addSubview:self.searchBar];
    self.historyButton=[UIButton buttonWithType:UIButtonTypeSystem];
    self.historyButton.translatesAutoresizingMaskIntoConstraints=NO;
    [self.historyButton setTitle:@"历史" forState:UIControlStateNormal];
    HostStylePillButton(self.historyButton,NO);
    HostInstallPressFeedback(self.historyButton);
    self.historyButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.historyButton.titleLabel.adjustsFontForContentSizeCategory=YES;
    self.historyButton.accessibilityLabel=@"搜索历史设置";
    [self.historyButton addTarget:self action:@selector(showSearchHistory) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:self.historyButton];
    self.scopeControl=[[UISegmentedControl alloc] initWithItems:@[@"当前站点",@"可用来源"]];
    self.scopeControl.translatesAutoresizingMaskIntoConstraints=NO;
    self.scopeControl.selectedSegmentIndex=self.currentSiteScope?0:1;
    [self.scopeControl setEnabled:self.currentSiteSource!=nil forSegmentAtIndex:0];
    self.scopeControl.selectedSegmentTintColor=HostAccent();
    [self.scopeControl setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];
    [self.scopeControl setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];
    self.scopeControl.accessibilityIdentifier=@"media-search-scope";
    self.scopeControl.accessibilityLabel=@"影视搜索范围";
    self.scopeControl.accessibilityHint=self.currentCatalogID.length?@"当前站点只搜索合集内已选站点，不会下载其他站点；未运行插件需要手动启动":@"当前站点只搜索顶部已选站点；可用来源保留独立进度，未运行插件需要手动启动";
    [self.scopeControl addTarget:self action:@selector(changeSearchScope:) forControlEvents:UIControlEventValueChanged];
    [header addSubview:self.scopeControl];
    self.progressLabel = [UILabel new];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.progressLabel.adjustsFontForContentSizeCategory = YES;
    self.progressLabel.textColor = HostSecondaryText();
    self.progressLabel.numberOfLines = 0;
    self.progressLabel.text = @"各来源独立显示搜索进度；未运行的插件不会自动启动。";
    [header addSubview:self.progressLabel];
    self.filterScroll=[UIScrollView new];self.filterScroll.translatesAutoresizingMaskIntoConstraints=NO;self.filterScroll.showsHorizontalScrollIndicator=NO;self.filterScroll.accessibilityIdentifier=@"media-search-station-filters";
    self.filterStack=[[UIStackView alloc] initWithFrame:CGRectZero];self.filterStack.translatesAutoresizingMaskIntoConstraints=NO;self.filterStack.axis=UILayoutConstraintAxisHorizontal;self.filterStack.spacing=8;
    [header addSubview:self.filterScroll];[self.filterScroll addSubview:self.filterStack];
    [NSLayoutConstraint activateConstraints:@[[self.filterScroll.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],[self.filterScroll.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],[self.filterScroll.topAnchor constraintEqualToAnchor:self.progressLabel.bottomAnchor constant:10],[self.filterScroll.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-10],[self.filterScroll.heightAnchor constraintEqualToAnchor:self.filterStack.heightAnchor],[self.filterStack.leadingAnchor constraintEqualToAnchor:self.filterScroll.contentLayoutGuide.leadingAnchor],[self.filterStack.trailingAnchor constraintEqualToAnchor:self.filterScroll.contentLayoutGuide.trailingAnchor],[self.filterStack.topAnchor constraintEqualToAnchor:self.filterScroll.contentLayoutGuide.topAnchor],[self.filterStack.bottomAnchor constraintEqualToAnchor:self.filterScroll.contentLayoutGuide.bottomAnchor]]];
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.historyButton.leadingAnchor constant:-4],
        [self.searchBar.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [self.historyButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14],
        [self.historyButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.historyButton.widthAnchor constraintGreaterThanOrEqualToConstant:48],
        [self.historyButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],
        [self.scopeControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.scopeControl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [self.scopeControl.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.scopeControl.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.scopeControl.bottomAnchor constant:10],
        [self.progressLabel.heightAnchor constraintGreaterThanOrEqualToConstant:18]
    ]];
    self.tableView.tableHeaderView = header;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"搜索" style:UIBarButtonItemStyleDone target:self action:@selector(submitSearch)];
    [self updateSearchScopePresentation];[self updateFilters];[self.tableView reloadData];[self updateEmptyState];
    NSString *initial=[self.initialKeyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(initial.length){self.searchBar.text=initial;dispatch_async(dispatch_get_main_queue(),^{if(self.isViewLoaded&&self.initialKeyword.length&&[self.searchBar.text isEqual:self.initialKeyword])[self submitSearch];});}
}

- (void)updateSearchScopePresentation {
    self.searchBar.placeholder=self.currentSiteScope?@"搜索当前站点":@"搜索已导入影视来源";
    if(self.currentSiteScope){NSString *name=[self.currentSiteSource[@"name"] isKindOfClass:NSString.class]?self.currentSiteSource[@"name"]:@"当前站点";self.progressLabel.text=[NSString stringWithFormat:@"%@ · 只搜索所选站点，不会展开其他站点",name];}
    else self.progressLabel.text=@"搜索已导入来源；未运行的插件需要点按对应来源后单独启动。";
}
- (void)changeSearchScope:(UISegmentedControl *)sender {
    BOOL current=sender.selectedSegmentIndex==0&&self.currentSiteSource!=nil;
    if(self.currentSiteScope==current)return;
    [self cancelJobsAndAdvanceGeneration];
    self.searching=NO;self.currentSiteScope=current;
    self.searchSources=current?@[self.currentSiteSource]:self.availableSources;
    [self.rows removeAllObjects];[self.retrySections removeAllObjects];[self.filterOffsets removeAllObjects];
    self.resultCount=0;self.completedCount=0;self.scheduledCount=0;self.resultLimitReached=NO;
    self.keyword=@"";self.selectedSourceSection=-1;self.selectedProvider=nil;
    self.savedReadingPosition=nil;self.savedSearchOffset=CGPointZero;
    self.filterChoices=nil;self.renderedFilterKey=nil;
    self.navigationItem.rightBarButtonItem.title=@"搜索";self.navigationItem.rightBarButtonItem.action=@selector(submitSearch);
    [self updateSearchScopePresentation];
    if([self.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)self.progressLabel.text=[self.progressLabel.text stringByAppendingString:@" · 点按搜索开始"];
    [self updateFilters];[self.tableView reloadData];[self restoreOffset:CGPointMake(0,-self.tableView.adjustedContentInset.top)];
}


- (void)updateEmptyState {
    if(self.sources.count){self.tableView.backgroundView=nil;return;}
    UILabel *empty=[[UILabel alloc] initWithFrame:self.tableView.bounds];empty.text=@"尚未导入影视资源\n请先到资源页导入影视包，再回来搜索";empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];empty.adjustsFontForContentSizeCategory=YES;empty.textColor=HostSecondaryText();self.tableView.backgroundView=empty;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    if (!header) return;
    CGFloat width = self.tableView.bounds.size.width;
    CGSize fitting=[header systemLayoutSizeFittingSize:CGSizeMake(MAX(1,width),UILayoutFittingCompressedSize.height)
                      withHorizontalFittingPriority:UILayoutPriorityRequired
                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat height=MAX(104,ceil(fitting.height));
    if (fabs(header.frame.size.width - width) > 0.5 || fabs(header.frame.size.height-height)>0.5) {
        header.frame = CGRectMake(0, 0, width, height);
        self.tableView.tableHeaderView = header;
    }
}

- (NSString *)filterPositionKey {
    return [NSString stringWithFormat:@"%ld:%@:%@",(long)self.selectedSourceSection,self.selectedProvider?@"provider":@"source",self.selectedProvider?:@""];
}
- (NSArray *)visibleEntriesForSection:(NSInteger)section {
    if(section<0||(NSUInteger)section>=self.rows.count)return @[];
    NSArray *entries=self.rows[section][@"results"];
    return MediaSearchEntries(entries,self.selectedProvider);
}
- (void)restoreOffset:(CGPoint)offset {
    CGFloat minimum=-self.tableView.adjustedContentInset.top;
    CGFloat maximum=MAX(minimum,self.tableView.contentSize.height-self.tableView.bounds.size.height+self.tableView.adjustedContentInset.bottom);
    [self.tableView setContentOffset:CGPointMake(0,MIN(MAX(offset.y,minimum),maximum)) animated:NO];
}
- (NSDictionary *)readingPosition {
    [self.tableView layoutIfNeeded];
    CGPoint offset=self.tableView.contentOffset;
    for(NSIndexPath *path in [self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)]){
        UITableViewCell *cell=[self.tableView cellForRowAtIndexPath:path];
        if(![cell isKindOfClass:MediaSearchResultCell.class])continue;
        NSDictionary *entry=((MediaSearchResultCell *)cell).searchEntry;if(!entry)continue;
        return @{@"section":@(path.section),@"identity":MediaSearchIdentity(MediaSearchText(entry[@"provider"]),entry[@"item"][@"id"]?:entry[@"item"][@"name"]),@"delta":@([self.tableView rectForRowAtIndexPath:path].origin.y-offset.y),@"offset":@(offset.y)};
    }
    return @{@"offset":@(offset.y)};
}
- (void)restoreReadingPosition:(NSDictionary *)position {
    if(!position){[self restoreOffset:CGPointMake(0,-self.tableView.adjustedContentInset.top)];return;}
    NSInteger section=[position[@"section"] integerValue];NSArray *entries=[self visibleEntriesForSection:section];
    if(position[@"identity"]&&(self.selectedSourceSection<0||self.selectedSourceSection==section)){
        for(NSUInteger index=0;index<entries.count;index++){
            NSDictionary *entry=entries[index];NSString *identity=MediaSearchIdentity(MediaSearchText(entry[@"provider"]),entry[@"item"][@"id"]?:entry[@"item"][@"name"]);
            if([identity isEqual:position[@"identity"]]){
                NSIndexPath *path=[NSIndexPath indexPathForRow:index+1 inSection:section];
                // Resolve automatic row-height estimates around the actual film
                // before calculating its pixel position after a data reload.
                [self.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionTop animated:NO];[self.tableView layoutIfNeeded];
                CGFloat y=[self.tableView rectForRowAtIndexPath:path].origin.y-[position[@"delta"] doubleValue];[self restoreOffset:CGPointMake(0,y)];[self.tableView layoutIfNeeded];return;
            }
        }
    }
    [self restoreOffset:CGPointMake(0,[position[@"offset"] doubleValue])];
}
- (void)updateFilters {
    if(!self.filterStack)return;
    CGPoint offset=self.filterScroll.contentOffset;
    NSMutableArray *choices=[NSMutableArray arrayWithObject:@{@"section":@(-1),@"name":self.currentSiteScope?@"当前站点":@"全部",@"count":@(self.resultCount)}];
    if(!self.currentSiteScope)for(NSUInteger section=0;section<self.rows.count;section++){
        NSDictionary *row=self.rows[section];NSArray *entries=[row[@"results"] isKindOfClass:NSArray.class]?row[@"results"]:@[];
        NSString *sourceName=section<self.searchSources.count?MediaSearchText(self.searchSources[section][@"name"]):@"";
        [choices addObject:@{@"section":@(section),@"name":sourceName,@"count":@(entries.count)}];
        NSDictionary *states=row[@"providerStates"];
        for(NSString *provider in [states.allKeys sortedArrayUsingSelector:@selector(compare:)]){
            NSDictionary *station=states[provider];
            [choices addObject:@{@"section":@(section),@"provider":provider,@"name":MediaSearchText(station[@"name"]),@"count":@(MediaSearchEntries(entries,provider).count),@"state":station[@"state"]?:@""}];
        }
    }
    if([self.filterChoices isEqual:choices]&&[self.renderedFilterKey isEqual:self.filterPositionKey])return;
    self.renderedFilterKey=self.filterPositionKey;self.filterChoices=choices;
    while(self.filterStack.arrangedSubviews.count>choices.count){UIView *view=self.filterStack.arrangedSubviews.lastObject;[self.filterStack removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSUInteger index=0;index<choices.count;index++){
        NSDictionary *choice=choices[index];UIButton *button;
        if(index<self.filterStack.arrangedSubviews.count)button=(UIButton *)self.filterStack.arrangedSubviews[index];
        else{button=[UIButton buttonWithType:UIButtonTypeSystem];HostInstallPressFeedback(button);[button addTarget:self action:@selector(selectSearchFilter:) forControlEvents:UIControlEventTouchUpInside];[button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;[self.filterStack addArrangedSubview:button];}
        NSString *title=[NSString stringWithFormat:@"%@ %@",choice[@"name"],choice[@"count"]];
        [button setTitle:title forState:UIControlStateNormal];button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.contentEdgeInsets=UIEdgeInsetsMake(10,14,10,14);button.layer.cornerRadius=20;button.layer.cornerCurve=kCACornerCurveContinuous;
        BOOL selected=[choice[@"section"] integerValue]==self.selectedSourceSection&&((!choice[@"provider"]&&!self.selectedProvider)||[choice[@"provider"] isEqual:self.selectedProvider]);
        button.backgroundColor=selected?HostSelectedSurface():HostNeutralSurface();button.layer.borderWidth=selected?1.0:0.6;HostSetLayerBorderColor(button,selected?HostAccent():HostBorder());[button setTitleColor:selected?HostAccent():HostText() forState:UIControlStateNormal];button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);button.accessibilityLabel=[NSString stringWithFormat:@"%@，%@ 条结果，%@",choice[@"name"],choice[@"count"],choice[@"state"]?:@"来源筛选"];button.accessibilityIdentifier=[NSString stringWithFormat:@"media-search-filter-%lu",(unsigned long)index];button.tag=index;
    }
    [self.filterScroll layoutIfNeeded];CGFloat maximum=MAX(0,self.filterScroll.contentSize.width-self.filterScroll.bounds.size.width);self.filterScroll.contentOffset=CGPointMake(MIN(MAX(0,offset.x),maximum),0);
}
- (void)selectSearchFilter:(UIButton *)sender {
    if(sender.tag<0||(NSUInteger)sender.tag>=self.filterChoices.count)return;
    self.filterOffsets[self.filterPositionKey]=[self readingPosition];
    NSDictionary *choice=self.filterChoices[sender.tag];self.selectedSourceSection=[choice[@"section"] integerValue];self.selectedProvider=choice[@"provider"];
    [self updateFilters];[self.tableView reloadData];[self.tableView layoutIfNeeded];
    [self restoreReadingPosition:self.filterOffsets[self.filterPositionKey]];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,self.filterScroll);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];self.resultsVisible=YES;
    if(self.restoringSearch){[self updateFilters];[self.tableView reloadData];}
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(self.restoringSearch){[self.tableView layoutIfNeeded];[self restoreReadingPosition:self.savedReadingPosition];self.restoringSearch=NO;}
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];self.savedSearchOffset=self.tableView.contentOffset;self.savedReadingPosition=[self readingPosition];self.resultsVisible=NO;self.restoringSearch=YES;
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // Pushing a film detail keeps this controller in the stack and preserves the
    // ongoing bounded search. An actual pop/dismiss invalidates its callbacks.
    // 注意：presentingViewController 是“呈现自己的 VC”，不能用它判断是否离页；
    // 模态 dismiss 后它仍非 nil，会导致任务永远不取消。
    if(self.isMovingFromParentViewController||self.isBeingDismissed){[self cancelJobsAndAdvanceGeneration];self.searching=NO;}
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSString *query=[searchText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([query isEqual:self.keyword])return;
    if(self.searching)[self cancelSearch];else [self cancelJobsAndAdvanceGeneration];
    self.navigationItem.rightBarButtonItem.title=@"搜索";self.navigationItem.rightBarButtonItem.action=@selector(submitSearch);
    if(!query.length){self.keyword=@"";self.resultCount=0;[self.rows removeAllObjects];self.selectedSourceSection=-1;self.selectedProvider=nil;[self.filterOffsets removeAllObjects];[self updateFilters];[self.tableView reloadData];}
    self.progressLabel.text=query.length?@"关键词已修改 · 按搜索开始；当前保留上次结果":@"请输入影片名称搜索";
}

- (BOOL)sourceAvailableForSearch:(NSDictionary *)source {
    if (MediaSourceUsesNativeCatalogAPI(source)) return YES;
    NSString *identifier = [source[@"id"] isKindOfClass:NSString.class] ? source[@"id"] : @"";
    return identifier.length && [PyHost isRunningServiceIdentifier:identifier];
}

- (void)submitSearch {
    [self.searchBar resignFirstResponder];
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) {
        [self searchBar:self.searchBar textDidChange:@""];
        self.progressLabel.text = @"请输入关键词。各来源将分别显示进度和结果。";
        return;
    }
    self.selectedSourceSection=-1;self.selectedProvider=nil;[self.filterOffsets removeAllObjects];
    self.keyword = query;
    [self rememberSearchKeyword:query];
    [self cancelJobsAndAdvanceGeneration];
    [self.rows removeAllObjects];
    for (NSUInteger index = 0; index < self.searchSources.count; index++) {
        NSDictionary *source = self.searchSources[index];
        BOOL available = [self sourceAvailableForSearch:source];
        [self.rows addObject:[@{@"state":available?@"等待搜索":@"服务未运行 · 点按启动", @"results":[NSMutableArray array], @"error":@"", @"provider":@"", @"providerError":@"", @"failedProviders":@[], @"providerStates":[NSMutableDictionary dictionary]} mutableCopy]];
        if (available) [self.pendingSections addObject:@(index)];
    }
    [self sortPendingSectionsByHealth];
    self.resultCount = 0;
    self.completedCount = 0;
    self.scheduledCount = self.pendingSections.count;
    self.resultLimitReached = NO;
    self.searching = self.pendingSections.count > 0;
    self.retrySections = [NSMutableSet set];
    self.navigationItem.rightBarButtonItem.title = self.searching ? @"停止" : @"重试失败";
    self.navigationItem.rightBarButtonItem.action = self.searching ? @selector(cancelSearch) : @selector(retryFailedSources);
    [self updateProgress];
    [self updateFilters];[self.tableView reloadData];
    [self scheduleSources];
}

- (void)rememberSearchKeyword:(NSString *)keyword {
    if(![NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]||!keyword.length||keyword.length>256)return;
    NSMutableArray *values=[self.searchHistory mutableCopy]?:[NSMutableArray array];[values removeObject:keyword];[values insertObject:keyword atIndex:0];if(values.count>20)[values removeObjectsInRange:NSMakeRange(20,values.count-20)];self.searchHistory=values.copy;[NSUserDefaults.standardUserDefaults setObject:self.searchHistory forKey:@"media.globalSearchHistory.v1"];
}

- (void)searchHistoryCleared:(NSNotification *)notification {
    // 设置页清除搜索历史时同步清掉本页内存里的历史，否则菜单里仍显示旧关键词。
    if([notification.userInfo[@"enabled"] boolValue]&&![notification.userInfo[@"cleared"] boolValue])return;
    self.searchHistory=@[];
}
- (void)showSearchHistory {
    BOOL enabled=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"];
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"搜索历史" message:enabled?(self.searchHistory.count?@"选择关键词重新搜索。历史只保存在本机，可随时清除。":@"还没有保存搜索词。"):@"搜索历史默认关闭；开启后最多保留 20 条关键词，仅保存在本机。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf=self;
    for(NSString *term in self.searchHistory){if(![term isKindOfClass:NSString.class]||!term.length)continue;[menu addAction:[UIAlertAction actionWithTitle:term style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaGlobalSearchViewController *owner=weakSelf;if(!owner)return;owner.searchBar.text=term;[owner submitSearch];}]];}
    if(enabled&&self.searchHistory.count)[menu addAction:[UIAlertAction actionWithTitle:@"清空搜索历史" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){MediaGlobalSearchViewController *owner=weakSelf;if(!owner)return;owner.searchHistory=@[];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];[owner showSearchHistory];}]];
    [menu addAction:[UIAlertAction actionWithTitle:enabled?@"关闭搜索历史":@"开启搜索历史" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){MediaGlobalSearchViewController *owner=weakSelf;if(!owner)return;[NSUserDefaults.standardUserDefaults setBool:!enabled forKey:@"media.globalSearchHistoryEnabled.v1"];if(enabled){owner.searchHistory=@[];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"media.globalSearchHistory.v1"];id rawBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];NSMutableDictionary *browse=[rawBrowse isKindOfClass:NSDictionary.class]?[rawBrowse mutableCopy]:[NSMutableDictionary dictionary];[browse enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSDictionary *state,BOOL *stop){if(![state isKindOfClass:NSDictionary.class])return;NSMutableDictionary *clean=[state mutableCopy];clean[@"keyword"]=@"";browse[key]=clean.copy;}];[NSUserDefaults.standardUserDefaults setObject:browse forKey:@"media.browseStates.v1"];}[NSNotificationCenter.defaultCenter postNotificationName:@"MediaGlobalSearchHistoryDidChange" object:nil userInfo:@{@"enabled":@(!enabled)}];[owner showSearchHistory];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if(menu.popoverPresentationController){menu.popoverPresentationController.sourceView=self.historyButton;menu.popoverPresentationController.sourceRect=self.historyButton.bounds;}
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)cancelJobsAndAdvanceGeneration {
    self.generation++;
    for (MediaGlobalSearchJob *job in self.jobs.allValues) {
        [job.readiness cancel];
        [job.client cancel];
    }
    [self.jobs removeAllObjects];
    [self.pendingSections removeAllObjects];
}

- (void)sortPendingSectionsByHealth {
    [self.pendingSections sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b){
        NSDictionary *sourceA=a.unsignedIntegerValue<self.searchSources.count?self.searchSources[a.unsignedIntegerValue]:@{};
        NSDictionary *sourceB=b.unsignedIntegerValue<self.searchSources.count?self.searchSources[b.unsignedIntegerValue]:@{};
        BOOL downA=[MediaSourceHealthStore.shared isDeprioritizedSourceID:sourceA[@"id"]?:@""];
        BOOL downB=[MediaSourceHealthStore.shared isDeprioritizedSourceID:sourceB[@"id"]?:@""];
        if(downA!=downB)return downA?NSOrderedDescending:NSOrderedAscending;
        return [a compare:b];
    }];
}

- (void)cancelSearch {
    if (!self.searching) return;
    [self cancelJobsAndAdvanceGeneration];
    for (NSMutableDictionary *row in self.rows) {
        NSMutableDictionary *states=row[@"providerStates"];for(NSString *key in states.allKeys){NSDictionary *state=states[key];if([@[@"搜索中",@"等待搜索"] containsObject:state[@"state"]])states[key]=@{@"name":state[@"name"],@"state":@"已取消"};}
        if ([@[@"搜索中",@"等待搜索",@"等待重试",@"等待健康检查"] containsObject:row[@"state"]]) row[@"state"] = @"已取消";
        else if ([[row[@"state"] description] containsString:@"正在请求启动"]) row[@"state"] = @"启动请求仍在处理 · 点按此来源继续检查";
    }
    self.searching = NO;
    self.navigationItem.rightBarButtonItem.title = @"重试失败";
    self.navigationItem.rightBarButtonItem.action = @selector(retryFailedSources);
    self.progressLabel.text = [NSString stringWithFormat:@"搜索已停止 · 已保留 %lu 条已读取结果。", (unsigned long)self.resultCount];
    [self updateFilters];[self.tableView reloadData];
}

- (void)scheduleSources {
    if (!self.searching) return;
    while (self.jobs.count < MediaGlobalSearchMaximumConcurrentSources && self.pendingSections.count) {
        NSNumber *number = self.pendingSections.firstObject;
        [self.pendingSections removeObjectAtIndex:0];
        NSUInteger section = number.unsignedIntegerValue;
        if (section >= self.searchSources.count || section >= self.rows.count) continue;
        [self startSourceAtSection:section];
    }
    [self updateProgress];
    if (!self.jobs.count && !self.pendingSections.count) {
        self.searching = NO;
        self.navigationItem.rightBarButtonItem.title = @"重试失败";
        self.navigationItem.rightBarButtonItem.action = @selector(retryFailedSources);
    }
}

- (void)startSourceAtSection:(NSUInteger)section {
    NSDictionary *source = self.searchSources[section];
    MediaGlobalSearchJob *job = [MediaGlobalSearchJob new];
    job.section = section;
    job.generation = self.generation;
    job.source = source;
    job.startedAt = CACurrentMediaTime();
    self.jobs[@(section)] = job;
    self.rows[section][@"state"] = @"搜索中";
    self.rows[section][@"error"] = @"";
    [self reloadSection:section];

    if (MediaSourceUsesNativeCatalogAPI(source)) {
        job.client = [[MediaAPIClient alloc] initWithTVBoxSource:source];
        job.providers = @[@{@"id":@"", @"name":source[@"name"]?:@"TVBox 站点"}];
        [self searchNextProviderForJob:job];
        return;
    }

    id rawPort = source[@"port"];
    NSInteger port = [rawPort respondsToSelector:@selector(integerValue)] ? [rawPort integerValue] : 0;
    // 全局搜索也走网络超时偏好（默认 20 秒），不再写死 15 秒。
    job.client = [[MediaAPIClient alloc] initWithPort:port];
    NSURL *healthURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/health", (long)port]];
    if (!healthURL || port < 1 || port > 65535) {
        [self finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:1 userInfo:@{NSLocalizedDescriptionKey:@"本机影视服务端口无效。"}]];
        return;
    }
    job.readiness = [[LocalServiceReadiness alloc] initWithURL:healthURL timeout:12 requiresHealthJSON:YES];
    job.readiness.diagnosticContext=@{@"service_id":job.source[@"id"]?:@"",@"trigger":@"global_search"};
    __weak typeof(self) weakSelf = self;
    [job.readiness start:^(NSError *error, NSTimeInterval elapsed) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || ![owner isCurrentJob:job]) return;
        if (error) { [owner finishJob:job error:error]; return; }
        [owner loadCapabilitiesForJob:job];
    }];
}

- (BOOL)isCurrentJob:(MediaGlobalSearchJob *)job {
    return job && job.generation == self.generation && self.jobs[@(job.section)] == job;
}

- (void)loadCapabilitiesForJob:(MediaGlobalSearchJob *)job {
    __weak typeof(self) weakSelf = self;
    [job.client call:@"capabilities" arguments:@{} completion:^(id result, NSError *error) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || ![owner isCurrentJob:job]) return;
        if (error) { [owner finishJob:job error:error]; return; }
        NSDictionary *capabilityPayload = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSArray *capabilities = [capabilityPayload[@"capabilities"] isKindOfClass:NSArray.class] ? capabilityPayload[@"capabilities"] : @[];
        if (![capabilities containsObject:@"search"]) {
            [owner finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:2 userInfo:@{NSLocalizedDescriptionKey:@"此资源未声明影视搜索能力。"}]];
            return;
        }
        if (![capabilities containsObject:@"providers"]) {
            job.providers = @[@{@"id":@"", @"name":job.source[@"name"]?:@"默认站点"}];
            [owner searchNextProviderForJob:job];
            return;
        }
        [job.client call:@"providers" arguments:@{} completion:^(id providers, NSError *providerError) {
            MediaGlobalSearchViewController *page = weakSelf;
            if (!page || ![page isCurrentJob:job]) return;
            if (providerError) { [page finishJob:job error:providerError]; return; }
            NSMutableArray *valid = [NSMutableArray array];
            if ([providers isKindOfClass:NSArray.class]) for (id candidate in providers) {
                if (![candidate isKindOfClass:NSDictionary.class]) continue;
                if([candidate[@"searchable"] isKindOfClass:NSNumber.class]&&![candidate[@"searchable"] boolValue])continue;
                NSString *identifier = [candidate[@"id"] isKindOfClass:NSString.class] ? candidate[@"id"] : @"";
                NSString *name = [candidate[@"name"] isKindOfClass:NSString.class] ? candidate[@"name"] : identifier;
                if (name.length) [valid addObject:@{@"id":identifier, @"name":name}];
            }
            if (!valid.count) { [page finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:3 userInfo:@{NSLocalizedDescriptionKey:@"资源没有可搜索的影视站点。"}]]; return; }
            if(page.currentSiteScope){
                NSMutableArray *selected=[NSMutableArray array];NSString *selectedProviderID=page.currentProviderID?:@"";
                for(NSDictionary *candidate in valid)if([candidate[@"id"] isEqual:selectedProviderID]){[selected addObject:candidate];break;}
                if(!selected.count){[page finishJob:job error:[NSError errorWithDomain:@"CCTVHostSearch" code:5 userInfo:@{NSLocalizedDescriptionKey:@"当前站点已不可用。请返回媒体页重新选择站点，或切换搜索范围。"}]];return;}
                valid=selected;
            }
            NSArray *retryTargets=[page.rows[job.section][@"retryProviders"] isKindOfClass:NSArray.class]?page.rows[job.section][@"retryProviders"]:@[];
            if(retryTargets.count){NSMutableArray *retry=[NSMutableArray array];for(NSDictionary *target in retryTargets)for(NSDictionary *candidate in valid)if([candidate[@"id"] isEqual:target[@"id"]]){[retry addObject:candidate];break;}job.providers=retry.count?retry:valid;}else job.providers=valid;
            job.failedProviders=@[];page.rows[job.section][@"retryProviders"]=@[];for(NSDictionary *station in job.providers){NSMutableDictionary *states=page.rows[job.section][@"providerStates"];states[station[@"id"]]=@{@"name":station[@"name"],@"state":@"等待搜索"};}[page updateFilters];
            [page searchNextProviderForJob:job];
        }];
    }];
}

- (void)searchNextProviderForJob:(MediaGlobalSearchJob *)job {
    if (![self isCurrentJob:job]) return;
    if (self.resultCount >= MediaGlobalSearchMaximumResults) { [self stopAtResultLimit]; return; }
    if (job.providerIndex >= job.providers.count) {
        NSError *providerError = (!job.successfulProviderCount&&job.failedProviders.count) ? [NSError errorWithDomain:@"CCTVHostSearch" code:4 userInfo:@{NSLocalizedDescriptionKey:job.providerFailure.length?job.providerFailure:@"所有影视站点都搜索失败。"}] : nil;
        [self finishJob:job error:providerError];
        return;
    }
    NSDictionary *provider = job.providers[job.providerIndex++];
    NSString *providerID = [provider[@"id"] isKindOfClass:NSString.class] ? provider[@"id"] : @"";
    NSString *providerName = [provider[@"name"] isKindOfClass:NSString.class] ? provider[@"name"] : @"影视站点";
    self.rows[job.section][@"provider"] = providerName;
    self.rows[job.section][@"providerStates"][providerID]=@{@"name":providerName,@"state":@"搜索中"};
    [self reloadSection:job.section];
    NSMutableDictionary *arguments = [@{@"keyword":self.keyword?:@"", @"page":@1} mutableCopy];
    if (providerID.length) arguments[@"provider"] = providerID;
    __weak typeof(self) weakSelf = self;
    [job.client call:@"search" arguments:arguments completion:^(id result, NSError *error) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || ![owner isCurrentJob:job]) return;
        if (error) {
            NSString *message = error.localizedDescription.length ? error.localizedDescription : @"影视搜索失败。";
            NSMutableDictionary *row = owner.rows[job.section];
            NSDictionary *failedProvider=@{@"id":providerID,@"name":providerName};NSMutableArray *failed=[job.failedProviders mutableCopy]?:[NSMutableArray array];[failed addObject:failedProvider];job.failedProviders=failed;
            NSMutableArray *rowFailures=[row[@"failedProviders"] mutableCopy]?:[NSMutableArray array];[rowFailures addObject:failedProvider];row[@"failedProviders"]=rowFailures;
            row[@"providerStates"][providerID]=@{@"name":providerName,@"state":@"来源失败",@"error":message};
            row[@"providerError"] = [NSString stringWithFormat:@"%@：%@", providerName, message];
            if (!job.providerFailure.length) job.providerFailure = row[@"providerError"];
            [owner reloadSection:job.section];
            [owner searchNextProviderForJob:job];
            return;
        }
        job.successfulProviderCount++;
        NSDictionary *searchPayload = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSArray *items = [searchPayload[@"items"] isKindOfClass:NSArray.class] ? searchPayload[@"items"] : @[];
        NSMutableArray *stored = owner.rows[job.section][@"results"];
        NSUInteger remaining=owner.resultCount<MediaGlobalSearchMaximumResults?MediaGlobalSearchMaximumResults-owner.resultCount:0;
        owner.resultCount+=MediaSearchAppend(stored,items,providerID,providerName,remaining);
        owner.rows[job.section][@"providerStates"][providerID]=@{@"name":providerName,@"state":MediaSearchEntries(stored,providerID).count?@"搜索完成":@"无结果"};
        [owner reloadSection:job.section];
        [owner updateProgress];
        if (owner.resultCount >= MediaGlobalSearchMaximumResults) { [owner stopAtResultLimit]; return; }
        [owner searchNextProviderForJob:job];
    }];
}

- (void)finishJob:(MediaGlobalSearchJob *)job error:(NSError *)error {
    if (![self isCurrentJob:job]) return;
    BOOL partial=job.successfulProviderCount>0&&job.failedProviders.count>0;
    [MediaSourceHealthStore.shared recordSourceID:job.source[@"id"]?:@"" success:(error==nil||job.successfulProviderCount>0) elapsed:MAX(0,CACurrentMediaTime()-job.startedAt)];
    [job.readiness cancel];
    if (error) {
        self.rows[job.section][@"state"] = @"搜索失败";
        self.rows[job.section][@"error"] = error.localizedDescription ?: @"未知错误";
        self.rows[job.section][@"failedProviders"] = job.failedProviders ?: @[];
    } else if(partial) {
        self.rows[job.section][@"state"] = @"部分完成";
        NSMutableArray *names=[NSMutableArray array];for(NSDictionary *provider in [job.failedProviders subarrayWithRange:NSMakeRange(0,MIN(job.failedProviders.count,5))])if([provider[@"name"] length])[names addObject:provider[@"name"]];if(job.failedProviders.count>5)[names addObject:@"…"];
        self.rows[job.section][@"error"] = [NSString stringWithFormat:@"%lu 个影视站点失败：%@ · 点按只重试失败站点",(unsigned long)job.failedProviders.count,[names componentsJoinedByString:@"、"]];
        self.rows[job.section][@"failedProviders"] = job.failedProviders;
    } else {
        self.rows[job.section][@"state"] = [self.rows[job.section][@"results"] count]?@"搜索完成":@"无结果";
        self.rows[job.section][@"error"] = @"";
        self.rows[job.section][@"failedProviders"] = @[];
    }
    [self.jobs removeObjectForKey:@(job.section)];
    self.completedCount++;
    [self reloadSection:job.section];
    [self scheduleSources];
}

- (void)stopAtResultLimit {
    if (self.resultLimitReached) return;
    self.resultLimitReached = YES;
    for(NSMutableDictionary *row in self.rows){NSMutableDictionary *states=row[@"providerStates"];for(NSString *key in states.allKeys){NSDictionary *state=states[key];if([@[@"等待搜索",@"搜索中"] containsObject:state[@"state"]])states[key]=@{@"name":state[@"name"],@"state":@"已达结果上限"};}}
    self.searching = NO;
    self.generation++;
    for (MediaGlobalSearchJob *job in self.jobs.allValues) {
        [job.readiness cancel];
        [job.client cancel];
        if (job.section < self.rows.count) self.rows[job.section][@"state"] = @"已达结果上限";
    }
    [self.jobs removeAllObjects];
    for (NSNumber *number in self.pendingSections) if(number.unsignedIntegerValue<self.rows.count)self.rows[number.unsignedIntegerValue][@"state"] = @"未搜索 · 已达结果上限";
    [self.pendingSections removeAllObjects];
    self.navigationItem.rightBarButtonItem.title = @"重试失败";
    self.navigationItem.rightBarButtonItem.action = @selector(retryFailedSources);
    self.progressLabel.text = [NSString stringWithFormat:@"结果达到 %lu 条上限 · 可滚动查看已找到的结果。", (unsigned long)MediaGlobalSearchMaximumResults];
    if(self.resultsVisible){[self updateFilters];[self.tableView reloadData];}
}

- (BOOL)hasSubmittedSearchInput {
    NSString *query=[self.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return query.length&&[query isEqual:self.keyword];
}
- (void)retryFailedSources {
    if(![self hasSubmittedSearchInput]){self.progressLabel.text=@"请先搜索当前关键词，再重试来源";return;}
    NSMutableArray<NSNumber *> *failed = [NSMutableArray array];
    for (NSUInteger section = 0; section < self.rows.count; section++) {
        NSDictionary *row = self.rows[section];
        if (![row[@"state"] isEqual:@"搜索失败"]&&![row[@"state"] isEqual:@"部分完成"]) continue;
        if ([self sourceAvailableForSearch:self.searchSources[section]]) [failed addObject:@(section)];
    }
    if (!failed.count) {
        self.progressLabel.text = @"没有可重试的失败来源。未运行的插件需要点按对应来源后单独启动。";
        return;
    }
    [self cancelJobsAndAdvanceGeneration];
    self.pendingSections = [failed mutableCopy];
    [self sortPendingSectionsByHealth];
    self.retrySections = [NSMutableSet setWithArray:failed];
    self.completedCount = 0;
    self.scheduledCount = failed.count;
    self.searching = YES;
    self.resultLimitReached = NO;
    for (NSNumber *number in failed) {
        NSMutableDictionary *row = self.rows[number.unsignedIntegerValue];
        row[@"state"] = @"等待重试";
        row[@"error"] = @"";
        row[@"providerError"] = @"";
        row[@"retryProviders"] = [row[@"failedProviders"] isKindOfClass:NSArray.class]?[row[@"failedProviders"] copy]:@[];
        row[@"failedProviders"] = @[];
    }
    self.navigationItem.rightBarButtonItem.title = @"停止";
    self.navigationItem.rightBarButtonItem.action = @selector(cancelSearch);
    self.progressLabel.text = [NSString stringWithFormat:@"正在重试 %lu 个失败来源。", (unsigned long)failed.count];
    [self updateFilters];[self.tableView reloadData];
    [self scheduleSources];
}

- (void)startStoppedSourceAtSection:(NSUInteger)section {
    if (section >= self.searchSources.count) return;
    NSDictionary *source = self.searchSources[section];
    if (MediaSourceUsesNativeCatalogAPI(source)) return;
    if (!self.onActivateService) {
        self.rows[section][@"error"] = @"当前页面无法启动该插件，请到资源页单独启动。";
        [self reloadSection:section];
        return;
    }
    NSUInteger requestGeneration = self.generation;
    self.rows[section][@"state"] = @"正在请求启动此插件…";
    self.rows[section][@"error"] = @"";
    [self reloadSection:section];
    __weak typeof(self) weakSelf = self;
    self.onActivateService(source, ^(NSError *error) {
        MediaGlobalSearchViewController *owner = weakSelf;
        if (!owner || owner.generation != requestGeneration || section >= owner.rows.count) return;
        if (error) {
            owner.rows[section][@"state"] = @"启动失败";
            owner.rows[section][@"error"] = error.localizedDescription ?: @"插件启动失败。";
            [owner reloadSection:section];
            return;
        }
        owner.rows[section][@"state"] = @"启动请求已接受 · 正在检查服务";
        [owner enqueueStartedSection:section];
    });
}

- (void)enqueueStartedSection:(NSUInteger)section {
    NSNumber *number = @(section);
    if (self.jobs[number] || [self.pendingSections containsObject:number]) return;
    if (!self.searching) {
        self.searching = YES;
        self.completedCount = 0;
        self.scheduledCount = 0;
        self.resultLimitReached = NO;
        self.navigationItem.rightBarButtonItem.title = @"停止";
        self.navigationItem.rightBarButtonItem.action = @selector(cancelSearch);
    }
    self.scheduledCount++;
    [self.pendingSections addObject:number];
    self.rows[section][@"state"] = @"等待健康检查";
    self.rows[section][@"providerError"] = @"";
    self.searching = YES;
    [self updateProgress];
    [self reloadSection:section];
    [self scheduleSources];
}

- (void)updateProgress {
    NSUInteger denominator = self.scheduledCount;
    if (!denominator) {
        if(self.currentSiteScope)self.progressLabel.text=@"当前站点尚未运行；点按对应来源可单独启动后搜索。";
        else self.progressLabel.text = [NSString stringWithFormat:@"%lu 个影视来源 · 搜索中来源上限 %lu；不会自动启动其他插件。", (unsigned long)self.searchSources.count, (unsigned long)MediaGlobalSearchMaximumConcurrentSources];
        return;
    }
    NSUInteger active = self.jobs.count;
    NSUInteger queued = self.pendingSections.count;
    NSUInteger stations=0,finishedStations=0;
    for(NSDictionary *row in self.rows)for(NSDictionary *station in [row[@"providerStates"] allValues]){stations++;if([@[@"搜索完成",@"无结果",@"来源失败"] containsObject:station[@"state"]])finishedStations++;}
    NSString *mode = self.retrySections.count ? @"重试失败来源 · " : @"";
    self.progressLabel.text = [NSString stringWithFormat:@"%@已完成 %lu / %lu 个资源 · 同时搜索 %lu 个 · 排队 %lu 个 · 找到 %lu 条", mode, (unsigned long)self.completedCount, (unsigned long)denominator, (unsigned long)active, (unsigned long)queued, (unsigned long)self.resultCount];
    if(stations)self.progressLabel.text=[self.progressLabel.text stringByAppendingFormat:@" · 站点 %lu / %lu",(unsigned long)finishedStations,(unsigned long)stations];
}

- (void)reloadSection:(NSUInteger)section {
    if (section >= self.rows.count || section >= [self numberOfSectionsInTableView:self.tableView]) return;
    if(!self.resultsVisible){return;}
    [self updateFilters];
    NSDictionary *position=[self readingPosition];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationNone];
    [self.tableView layoutIfNeeded];[self restoreReadingPosition:position];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.searchSources.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(self.selectedSourceSection>=0&&section!=self.selectedSourceSection)return 0;
    if (section >= self.rows.count) return 1;
    return 1 + [self visibleEntriesForSection:section].count;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return self.selectedSourceSection>=0&&section!=self.selectedSourceSection?CGFLOAT_MIN:UITableViewAutomaticDimension;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return CGFLOAT_MIN;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section >= self.searchSources.count||(self.selectedSourceSection>=0&&section!=self.selectedSourceSection)) return nil;
    return [NSString stringWithFormat:@"%@ · %lu",self.searchSources[section][@"name"]?:@"影视来源",(unsigned long)[self visibleEntriesForSection:section].count];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *statusReuse = @"media-search-status";
    static NSString *resultReuse = @"media-search-result";
    BOOL statusRow = indexPath.row == 0;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:statusRow ? statusReuse : resultReuse];
    if (!cell) cell = statusRow?[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:statusReuse]:[[MediaSearchResultCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:resultReuse];
    cell.backgroundColor = HostCard();
    cell.textLabel.textColor = HostText();
    cell.detailTextLabel.textColor = HostSecondaryText();
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    NSDictionary *source = indexPath.section < self.searchSources.count ? self.searchSources[indexPath.section] : @{};
    NSDictionary *row = indexPath.section < self.rows.count ? self.rows[indexPath.section] : @{};
    if (statusRow) {
        cell.layer.cornerRadius = 14; cell.layer.cornerCurve = kCACornerCurveContinuous; cell.clipsToBounds = YES; cell.layer.borderWidth = 0.6; HostSetLayerBorderColor(cell, HostBorder());
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        BOOL sourceFailed=[@[@"搜索失败",@"启动失败"] containsObject:row[@"state"]?:@""];
        NSDictionary *station=self.selectedProvider&&!sourceFailed?row[@"providerStates"][self.selectedProvider]:nil;
        cell.textLabel.text = station?station[@"state"]:(row[@"state"] ?: @"待搜索");
        NSString *error = station?MediaSearchText(station[@"error"]):([row[@"error"] isKindOfClass:NSString.class] ? row[@"error"] : @"");
        NSString *providerError = station?@"":([row[@"providerError"] isKindOfClass:NSString.class] ? row[@"providerError"] : @"");
        cell.detailTextLabel.text = error.length&&providerError.length?[NSString stringWithFormat:@"%@\n最近失败：%@",error,providerError]:(error.length?error:(providerError.length?providerError:([row[@"provider"] length]?[NSString stringWithFormat:@"当前站点：%@",row[@"provider"]]:@"")));
        BOOL stopped = [[row[@"state"] description] containsString:@"未运行"];
        BOOL failed = [row[@"state"] isEqual:@"搜索失败"] || [row[@"state"] isEqual:@"部分完成"] || [row[@"state"] isEqual:@"启动失败"];
        cell.accessoryType = (stopped || failed) ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.selectionStyle = (stopped || failed) ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessibilityHint = stopped ? @"点按后只启动此插件，然后检查健康状态和影视接口" : (failed ? ([row[@"state"] isEqual:@"部分完成"]?@"点按只重试失败站点":@"点按重试此来源") : nil);
    } else {
        NSArray *entries=[self visibleEntriesForSection:indexPath.section];
        if((NSUInteger)(indexPath.row-1)>=entries.count){MediaSearchResultCell *stale=(MediaSearchResultCell *)cell;stale.nameLabel.text=@"";stale.metadataLabel.text=@"";stale.sourceLabel.text=@"";stale.poster.image=nil;stale.searchEntry=nil;cell.accessibilityLabel=nil;return cell;}
        NSDictionary *entry=entries[indexPath.row-1],*item=entry[@"item"];
        MediaSearchResultCell *resultCell=(MediaSearchResultCell *)cell;resultCell.searchEntry=entry;
        resultCell.nameLabel.text=MediaSearchText(item[@"name"]);
        NSMutableArray *parts=[NSMutableArray array];for(NSString *key in @[@"year",@"area",@"type",@"remarks"]){NSString *text=MediaSearchText(item[key]);if(text.length)[parts addObject:text];}
        resultCell.metadataLabel.text=parts.count?[parts componentsJoinedByString:@" · "]:@"暂无影片信息";
        resultCell.sourceLabel.text=[NSString stringWithFormat:@"%@ · %@",MediaSearchText(source[@"name"]),MediaSearchText(entry[@"providerName"])];
        resultCell.nameLabel.textColor=HostText();resultCell.metadataLabel.textColor=HostSecondaryText();resultCell.sourceLabel.textColor=HostAccent();resultCell.poster.backgroundColor=HostNeutralSurface();
        resultCell.poster.image=[UIImage systemImageNamed:@"film" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular]];resultCell.poster.tintColor=HostSecondaryText();resultCell.poster.accessibilityIdentifier=nil;
        NSString *poster=MediaSearchText(item[@"poster"]);resultCell.poster.contentMode=poster.length?UIViewContentModeScaleAspectFill:UIViewContentModeCenter;if(poster.length)MediaSearchLoadPosterWithRetry(poster,resultCell.poster,1);
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;cell.selectionStyle=UITableViewCellSelectionStyleDefault;
        cell.accessibilityLabel=[NSString stringWithFormat:@"%@，%@，%@",resultCell.nameLabel.text,resultCell.metadataLabel.text,resultCell.sourceLabel.text];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section >= self.searchSources.count || indexPath.section >= self.rows.count) return;
    if (indexPath.row == 0) {
        if(![self hasSubmittedSearchInput]){self.progressLabel.text=@"请先搜索当前关键词，再启动或重试来源";return;}
        NSDictionary *row = self.rows[indexPath.section];
        if ([[row[@"state"] description] containsString:@"未运行"]) { [self startStoppedSourceAtSection:indexPath.section]; return; }
        if ([row[@"state"] isEqual:@"搜索失败"] || [row[@"state"] isEqual:@"部分完成"] || [row[@"state"] isEqual:@"启动失败"]) {
            if (self.searching) { self.progressLabel.text = @"其他来源仍在搜索；当前失败来源可在本轮结束后重试。"; return; }
            if ([self sourceAvailableForSearch:self.searchSources[indexPath.section]]) {
                self.pendingSections = [NSMutableArray arrayWithObject:@(indexPath.section)];
                self.scheduledCount = 1; self.completedCount = 0; self.searching = YES;
                self.retrySections = [NSMutableSet setWithObject:@(indexPath.section)];
                self.rows[indexPath.section][@"state"] = @"等待重试"; self.rows[indexPath.section][@"error"] = @""; self.rows[indexPath.section][@"providerError"] = @"";self.rows[indexPath.section][@"retryProviders"]=[self.rows[indexPath.section][@"failedProviders"] isKindOfClass:NSArray.class]?[self.rows[indexPath.section][@"failedProviders"] copy]:@[];self.rows[indexPath.section][@"failedProviders"]=@[];
                self.navigationItem.rightBarButtonItem.title = @"停止"; self.navigationItem.rightBarButtonItem.action = @selector(cancelSearch);
                [self scheduleSources];
            } else [self startStoppedSourceAtSection:indexPath.section];
        }
        return;
    }
    NSArray *entries=[self visibleEntriesForSection:indexPath.section];
    if((NSUInteger)(indexPath.row-1)>=entries.count)return;
    NSDictionary *entry=entries[indexPath.row-1];
    self.savedSearchOffset=self.tableView.contentOffset;
    if (self.onSelectResult) self.onSelectResult(entry[@"item"] ?: @{}, self.searchSources[indexPath.section], entry[@"provider"] ?: @"");
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.row == 0 || indexPath.section >= self.searchSources.count) return nil;
    NSArray *entries = [self visibleEntriesForSection:indexPath.section];
    if ((NSUInteger)(indexPath.row - 1) >= entries.count) return nil;
    NSDictionary *entry = entries[indexPath.row - 1];
    NSDictionary *item = [entry[@"item"] isKindOfClass:NSDictionary.class] ? entry[@"item"] : @{};
    NSString *title = MediaSearchText(item[@"name"]);
    NSString *provider = MediaSearchText(entry[@"provider"]);
    NSDictionary *source = self.searchSources[indexPath.section];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *openAction = [UIAction actionWithTitle:@"查看影片详情" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(__unused UIAction *a) {
            MediaGlobalSearchViewController *owner = weakSelf;
            if (owner && owner.onSelectResult) owner.onSelectResult(item, source, provider);
        }];
        UIAction *copyAction = [UIAction actionWithTitle:@"复制片名" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(__unused UIAction *a) {
            if (title.length) UIPasteboard.generalPasteboard.string = title;
        }];
        UIAction *filterStationAction = [UIAction actionWithTitle:@"仅看此来源结果" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(__unused UIAction *a) {
            MediaGlobalSearchViewController *owner = weakSelf;
            if (!owner) return;
            owner.selectedSourceSection = indexPath.section;
            owner.selectedProvider = provider.length ? provider : nil;
            [owner updateFilters];
            [owner.tableView reloadData];
        }];
        return [UIMenu menuWithTitle:title children:@[openAction, filterStationAction, copyAction]];
    }];
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    if (!self.isViewLoaded) return;
    self.view.backgroundColor = HostBackground();
    self.view.tintColor = HostAccent();
    self.tableView.backgroundColor = HostBackground();
    self.tableView.tableHeaderView.backgroundColor = HostBackground();
    self.progressLabel.textColor = HostSecondaryText();
    HostStylePillButton(self.historyButton, NO);
    self.historyButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.historyButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.scopeControl.selectedSegmentTintColor = HostAccent();
    [self.scopeControl setTitleTextAttributes:@{NSForegroundColorAttributeName:HostText()} forState:UIControlStateNormal];
    [self.scopeControl setTitleTextAttributes:@{NSForegroundColorAttributeName:HostOnAccent()} forState:UIControlStateSelected];
    self.renderedFilterKey = nil;
    [self updateFilters];
    [self updateEmptyState];
    [self.tableView reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [self submitSearch]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [self cancelJobsAndAdvanceGeneration]; }
@end
