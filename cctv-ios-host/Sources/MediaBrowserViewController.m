#import "MediaBrowserViewController.h"
#import "MediaAPIClient.h"
#import "HostImageLoader.h"
#import "HostTheme.h"
#import "HostToolbar.h"
#import "LocalServiceReadiness.h"
#import "ServiceStore.h"
#import "MediaEpisodeSelectionViewController.h"
#import "RuntimeDiagnostics.h"
#import "MediaWebViewController.h"
#import "MediaPlaybackStateStore.h"
#import "MediaMetadataCache.h"
#import "MediaGlobalSearchViewController.h"
#import "MediaSourceHealthStore.h"
#import "PyHost.h"
#import <float.h>
#import <math.h>

@interface MediaPosterCell : UICollectionViewCell
@property(nonatomic,strong) UIImageView *posterView;
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *remarksLabel;
- (void)configureWithItem:(NSDictionary *)item;
@end

@implementation MediaPosterCell
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        HostStyleGlassCard(self.contentView,10);
        self.posterView=[UIImageView new];self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;[self.contentView addSubview:self.posterView];
        self.nameLabel=[UILabel new];self.nameLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];self.nameLabel.adjustsFontForContentSizeCategory=YES;self.nameLabel.textColor=HostText();self.nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.nameLabel];
        self.remarksLabel=[UILabel new];self.remarksLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11]];self.remarksLabel.adjustsFontForContentSizeCategory=YES;self.remarksLabel.textColor=HostSecondaryText();self.remarksLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.remarksLabel];
    }
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.posterView.image=nil;self.posterView.accessibilityIdentifier=nil;self.nameLabel.text=@"";self.remarksLabel.text=@"";self.accessibilityLabel=nil;
}
- (void)configureWithItem:(NSDictionary *)item {
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";
    if(poster.length)[HostImageLoader.shared loadURL:poster intoImageView:self.posterView];else{self.posterView.image=nil;self.posterView.accessibilityIdentifier=nil;}
    self.nameLabel.text=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"";
    self.remarksLabel.text=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"";
    self.accessibilityLabel=[NSString stringWithFormat:@"%@，%@",self.nameLabel.text,self.remarksLabel.text];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width=CGRectGetWidth(self.contentView.bounds),posterHeight=width*1.4;
    CGFloat nameHeight=ceil(self.nameLabel.font.lineHeight),remarksHeight=ceil(self.remarksLabel.font.lineHeight);
    self.posterView.frame=CGRectMake(0,0,width,posterHeight);
    self.nameLabel.frame=CGRectMake(8,posterHeight+4,MAX(0,width-16),nameHeight);
    self.remarksLabel.frame=CGRectMake(8,CGRectGetMaxY(self.nameLabel.frame)+2,MAX(0,width-16),remarksHeight);
}
@end

@interface MediaSourcePicker : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSDictionary *> *choices;
@property(nonatomic, copy) NSArray<NSDictionary *> *shown;
@property(nonatomic, copy) NSArray<NSString *> *scopeKeys;
@property(nonatomic, copy) NSString *selectedScope;
@property(nonatomic, copy) void (^onSelect)(NSDictionary *);
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic, strong) UIScrollView *scopeScroll;
@property(nonatomic, strong) UIStackView *scopeStack;
@property(nonatomic,copy) NSString *screenTitle;
- (void)configureScopes;
- (void)selectScope:(UIButton *)sender;
@end
@implementation MediaSourcePicker
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.screenTitle?:@"影视资源";self.shown=self.choices?:@[];self.selectedScope=@"*";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;self.tableView.tableFooterView=[UIView new];
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchResultsUpdater=self;self.search.searchBar.placeholder=[self.title isEqual:@"影视站点"]?@"搜索当前资源的站点":([self.title isEqual:@"影视资源"]?@"搜索已导入资源":@"搜索选项");self.search.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closePicker)];
    [self configureScopes];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];UIView *header=self.tableView.tableHeaderView;if(header&&fabs(header.frame.size.width-self.tableView.bounds.size.width)>0.5){CGRect frame=header.frame;frame.size.width=self.tableView.bounds.size.width;header.frame=frame;self.tableView.tableHeaderView=header;} }
- (void)configureScopes {
    NSMutableOrderedSet<NSString *> *keys=[NSMutableOrderedSet orderedSet];for(NSDictionary *choice in self.choices){NSString *key=[choice[@"scope"] isKindOfClass:NSString.class]?choice[@"scope"]:@"";if(key.length)[keys addObject:key];}self.scopeKeys=keys.array;
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),self.scopeKeys.count?52:8)];header.backgroundColor=UIColor.clearColor;
    if(self.scopeKeys.count){self.scopeScroll=[UIScrollView new];self.scopeScroll.translatesAutoresizingMaskIntoConstraints=NO;self.scopeScroll.showsHorizontalScrollIndicator=NO;self.scopeStack=[UIStackView new];self.scopeStack.translatesAutoresizingMaskIntoConstraints=NO;self.scopeStack.axis=UILayoutConstraintAxisHorizontal;self.scopeStack.spacing=8;[self.scopeScroll addSubview:self.scopeStack];[header addSubview:self.scopeScroll];[NSLayoutConstraint activateConstraints:@[[self.scopeScroll.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],[self.scopeScroll.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],[self.scopeScroll.topAnchor constraintEqualToAnchor:header.topAnchor constant:6],[self.scopeScroll.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4],[self.scopeStack.leadingAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.leadingAnchor],[self.scopeStack.trailingAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.trailingAnchor],[self.scopeStack.topAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.topAnchor],[self.scopeStack.bottomAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.bottomAnchor],[self.scopeStack.heightAnchor constraintEqualToAnchor:self.scopeScroll.frameLayoutGuide.heightAnchor]]];[self addScopeButton:@"*" title:[NSString stringWithFormat:@"全部 %lu",(unsigned long)self.choices.count]];for(NSString *key in self.scopeKeys){NSString *label=nil;for(NSDictionary *choice in self.choices)if([choice[@"scope"] isEqual:key]){label=choice[@"scopeName"];break;}NSUInteger count=[[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){return [choice[@"scope"] isEqual:key];}]] count];[self addScopeButton:key title:[NSString stringWithFormat:@"%@ %lu",label.length?label:key,(unsigned long)count]];}}
    self.tableView.tableHeaderView=header;
}
- (void)addScopeButton:(NSString *)key title:(NSString *)title {UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.accessibilityIdentifier=key;button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];HostStylePillButton(button,[key isEqual:self.selectedScope]);[button setTitle:title forState:UIControlStateNormal];[button addTarget:self action:@selector(selectScope:) forControlEvents:UIControlEventTouchUpInside];[self.scopeStack addArrangedSubview:button];}
- (void)selectScope:(UIButton *)sender {HostAnimateSelection(sender);self.selectedScope=sender.accessibilityIdentifier?:@"*";for(UIButton *button in self.scopeStack.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.selectedScope];HostStylePillButton(button,selected);}[self updateSearchResultsForSearchController:self.search];}
- (void)closePicker { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.shown.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"source"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];NSDictionary *choice=self.shown[index.row];cell.backgroundColor=HostCard();cell.textLabel.text=choice[@"name"];cell.textLabel.textColor=UIColor.labelColor;cell.textLabel.numberOfLines=0;NSMutableArray *details=[NSMutableArray array];if([choice[@"subtitle"] length])[details addObject:choice[@"subtitle"]];if([choice[@"url"] length])[details addObject:choice[@"url"]];cell.detailTextLabel.text=[details componentsJoinedByString:@"\n"];cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.detailTextLabel.numberOfLines=0;BOOL selected=[choice[@"selected"] boolValue];cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {NSString *query=controller.searchBar.text?:@"";self.shown=[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){NSString *scope=[choice[@"scope"] isKindOfClass:NSString.class]?choice[@"scope"]:@"";if(![self.selectedScope isEqual:@"*"]&&![@"" isEqual:scope]&&![scope isEqual:self.selectedScope])return NO;BOOL matches=![query length];for(NSString *key in @[@"name",@"subtitle",@"url"]){NSString *value=[choice[key] isKindOfClass:NSString.class]?choice[key]:@"";if(query.length&&[value rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)matches=YES;}return matches;}]];[self.tableView reloadData];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {NSDictionary *choice=self.shown[index.row];void(^onSelect)(NSDictionary *)=self.onSelect;[self.navigationController dismissViewControllerAnimated:YES completion:^{if(onSelect)onSelect(choice);}];}
@end


@interface MediaDetailViewController : UIViewController
@property(nonatomic,copy) NSDictionary *item;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic,copy) NSString *provider;
@property(nonatomic,copy) NSDictionary *detail;
@property(nonatomic,copy) NSDictionary *resumeEntry;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic,copy) void (^onPlay)(NSDictionary *,NSDictionary *);
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIImageView *bannerView;
@property(nonatomic,strong) UIImageView *posterView;
@property(nonatomic,strong) UILabel *heroTitle;
@property(nonatomic,strong) UILabel *heroMetadata;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *metadataLabel;
@property(nonatomic,strong) UILabel *descriptionLabel;
@property(nonatomic,strong) UIButton *descriptionToggle;
@property(nonatomic,strong) UIButton *playButton;
@property(nonatomic,strong) UIButton *favoriteButton;
@property(nonatomic,strong) UIStackView *routeButtons;
@property(nonatomic,strong) UIStackView *episodeGrid;
@property(nonatomic,strong) NSMutableArray<UIButton *> *episodeButtons;
@property(nonatomic,strong) UILabel *episodeTitle;
@property(nonatomic,strong) UILabel *pageLabel;
@property(nonatomic,strong) UIButton *previousPageButton;
@property(nonatomic,strong) UIButton *nextPageButton;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic) NSInteger selectedLineIndex;
@property(nonatomic) NSInteger selectedEpisodeIndex;
@property(nonatomic) NSInteger episodePage;
@property(nonatomic) BOOL descriptionExpanded;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,copy) NSString *diagnosticTraceID;
- (void)loadDetail;
- (void)selectRoute:(UIButton *)sender;
- (void)selectEpisode:(UIButton *)sender;
@end
@implementation MediaDetailViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithNibName:nil bundle:nil];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.item[@"name"]?:@"影片详情";self.view.backgroundColor=HostBackground();self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.selectedLineIndex=0;self.selectedEpisodeIndex=0;self.episodePage=0;self.episodeButtons=[NSMutableArray array];self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];back.frame=CGRectMake(0,0,44,44);[back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];back.tintColor=HostText();back.backgroundColor=HostCard();back.layer.cornerRadius=14;back.layer.cornerCurve=kCACornerCurveContinuous;back.accessibilityLabel=@"返回";back.accessibilityIdentifier=@"media-detail-back";[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:back];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadDetail)];
    self.client=MediaSourceUsesNativeCatalogAPI(self.source)?[[MediaAPIClient alloc] initWithTVBoxSource:self.source]:[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];[self buildDetailLayout];[self loadDetail];
}
- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label=[UILabel new];label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];label.adjustsFontForContentSizeCategory=YES;label.textColor=HostText();label.text=text;return label;
}
- (UIButton *)actionButton:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;
    button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;
    button.backgroundColor=HostCard();[button setTitleColor:HostText() forState:UIControlStateNormal];button.layer.cornerRadius=16;button.layer.cornerCurve=kCACornerCurveContinuous;
    button.layer.borderWidth=0.6;HostSetLayerBorderColor(button,HostBorder());button.contentEdgeInsets=UIEdgeInsetsMake(13,16,13,16);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[button setTitle:title forState:UIControlStateNormal];return button;
}
- (void)buildDetailLayout {
    self.scrollView=[UIScrollView new];self.scrollView.translatesAutoresizingMaskIntoConstraints=NO;self.scrollView.alwaysBounceVertical=YES;self.scrollView.accessibilityIdentifier=@"media-detail-scroll";[self.view addSubview:self.scrollView];
    self.contentStack=[UIStackView new];self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=13;
    self.contentStack.layoutMargins=UIEdgeInsetsMake(10,16,24,16);self.contentStack.layoutMarginsRelativeArrangement=YES;[self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[[self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],[self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor]]];
    self.status=[UILabel new];self.status.textColor=HostSecondaryText();self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.status.adjustsFontForContentSizeCategory=YES;
    self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.hidden=YES;[self.contentStack addArrangedSubview:self.status];
    self.bannerView=[UIImageView new];self.bannerView.translatesAutoresizingMaskIntoConstraints=NO;self.bannerView.contentMode=UIViewContentModeScaleAspectFill;self.bannerView.clipsToBounds=YES;self.bannerView.layer.cornerRadius=18;self.bannerView.hidden=YES;
    [self.contentStack addArrangedSubview:self.bannerView];[self.bannerView.heightAnchor constraintEqualToConstant:180].active=YES;
    UIView *hero=[UIView new];hero.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(hero,20);
    self.posterView=[UIImageView new];self.posterView.translatesAutoresizingMaskIntoConstraints=NO;self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;[hero addSubview:self.posterView];
    UIView *shade=[UIView new];shade.translatesAutoresizingMaskIntoConstraints=NO;shade.backgroundColor=[UIColor colorWithWhite:0 alpha:0.38];[hero addSubview:shade];
    self.heroTitle=[UILabel new];self.heroTitle.translatesAutoresizingMaskIntoConstraints=NO;self.heroTitle.font=[UIFont systemFontOfSize:24 weight:UIFontWeightBold];self.heroTitle.adjustsFontForContentSizeCategory=YES;self.heroTitle.textColor=UIColor.whiteColor;self.heroTitle.numberOfLines=2;
    self.heroMetadata=[UILabel new];self.heroMetadata.translatesAutoresizingMaskIntoConstraints=NO;self.heroMetadata.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.heroMetadata.adjustsFontForContentSizeCategory=YES;self.heroMetadata.textColor=UIColor.whiteColor;self.heroMetadata.numberOfLines=2;
    [hero addSubview:self.heroTitle];[hero addSubview:self.heroMetadata];[self.contentStack addArrangedSubview:hero];
    [NSLayoutConstraint activateConstraints:@[[hero.heightAnchor constraintEqualToAnchor:hero.widthAnchor multiplier:0.64],
        [self.posterView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.posterView.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.posterView.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.posterView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [shade.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[shade.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[shade.topAnchor constraintEqualToAnchor:hero.topAnchor],[shade.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [self.heroTitle.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:18],[self.heroTitle.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-18],
        [self.heroTitle.bottomAnchor constraintEqualToAnchor:self.heroMetadata.topAnchor constant:-3],[self.heroMetadata.leadingAnchor constraintEqualToAnchor:self.heroTitle.leadingAnchor],
        [self.heroMetadata.trailingAnchor constraintEqualToAnchor:self.heroTitle.trailingAnchor],[self.heroMetadata.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-16]]];
    self.titleLabel=[self sectionLabel:self.item[@"name"]?:@"影片详情"];self.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];self.titleLabel.numberOfLines=2;[self.contentStack addArrangedSubview:self.titleLabel];
    self.metadataLabel=[UILabel new];self.metadataLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.metadataLabel.adjustsFontForContentSizeCategory=YES;self.metadataLabel.textColor=HostSecondaryText();self.metadataLabel.numberOfLines=0;[self.contentStack addArrangedSubview:self.metadataLabel];
    self.descriptionLabel=[UILabel new];self.descriptionLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.descriptionLabel.adjustsFontForContentSizeCategory=YES;self.descriptionLabel.textColor=HostSecondaryText();self.descriptionLabel.numberOfLines=5;[self.contentStack addArrangedSubview:self.descriptionLabel];
    self.descriptionToggle=[UIButton buttonWithType:UIButtonTypeSystem];self.descriptionToggle.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;[self.descriptionToggle setTitle:@"展开简介" forState:UIControlStateNormal];[self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];self.descriptionToggle.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];[self.descriptionToggle addTarget:self action:@selector(toggleDescription) forControlEvents:UIControlEventTouchUpInside];self.descriptionToggle.hidden=YES;[self.contentStack addArrangedSubview:self.descriptionToggle];
    self.playButton=[self actionButton:@"▶︎  播放" identifier:@"media-detail-play" action:@selector(playCurrentEpisode)];self.favoriteButton=[self actionButton:@"♡  收藏" identifier:@"media-detail-favorite" action:@selector(toggleFavorite)];
    [self.contentStack addArrangedSubview:self.playButton];[self.contentStack addArrangedSubview:self.favoriteButton];[self.playButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;[self.favoriteButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;
    [self.contentStack addArrangedSubview:[self sectionLabel:@"播放线路"]];
    UIScrollView *routeScroll=[UIScrollView new];routeScroll.translatesAutoresizingMaskIntoConstraints=NO;routeScroll.showsHorizontalScrollIndicator=NO;[self.contentStack addArrangedSubview:routeScroll];
    self.routeButtons=[UIStackView new];self.routeButtons.translatesAutoresizingMaskIntoConstraints=NO;self.routeButtons.axis=UILayoutConstraintAxisHorizontal;self.routeButtons.spacing=8;[routeScroll addSubview:self.routeButtons];
    [NSLayoutConstraint activateConstraints:@[[routeScroll.heightAnchor constraintGreaterThanOrEqualToConstant:44],[self.routeButtons.leadingAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.leadingAnchor],
        [self.routeButtons.trailingAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.trailingAnchor],[self.routeButtons.topAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.topAnchor],
        [self.routeButtons.bottomAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.bottomAnchor],[self.routeButtons.heightAnchor constraintEqualToAnchor:routeScroll.frameLayoutGuide.heightAnchor]]];
    self.episodeTitle=[self sectionLabel:@"选集"];[self.contentStack addArrangedSubview:self.episodeTitle];
    self.pageLabel=[UILabel new];self.pageLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.pageLabel.adjustsFontForContentSizeCategory=YES;self.pageLabel.textColor=HostSecondaryText();[self.contentStack addArrangedSubview:self.pageLabel];
    UIStackView *paging=[UIStackView new];paging.axis=UILayoutConstraintAxisHorizontal;paging.spacing=10;self.previousPageButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextPageButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.previousPageButton setTitle:@"上一页" forState:UIControlStateNormal];[self.nextPageButton setTitle:@"下一页" forState:UIControlStateNormal];HostStylePillButton(self.previousPageButton,NO);HostStylePillButton(self.nextPageButton,NO);
    [self.previousPageButton addTarget:self action:@selector(previousEpisodePage) forControlEvents:UIControlEventTouchUpInside];[self.nextPageButton addTarget:self action:@selector(nextEpisodePage) forControlEvents:UIControlEventTouchUpInside];
    [paging addArrangedSubview:self.previousPageButton];[paging addArrangedSubview:self.nextPageButton];self.previousPageButton.hidden=YES;self.nextPageButton.hidden=YES;[self.contentStack addArrangedSubview:paging];
    self.episodeGrid=[UIStackView new];self.episodeGrid.axis=UILayoutConstraintAxisVertical;self.episodeGrid.spacing=8;self.episodeGrid.distribution=UIStackViewDistributionFillEqually;self.episodeGrid.accessibilityIdentifier=@"media-detail-episode-grid";[self.contentStack addArrangedSubview:self.episodeGrid];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.hidesWhenStopped=YES;self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[[self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)dealloc {[self.client cancel];}
- (void)goBack {[self.navigationController popViewControllerAnimated:YES];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController){self.generation++;[self.client cancel];}}
- (void)loadDetail {
    NSUInteger generation=++self.generation;[self.client cancel];self.status.text=@"正在加载影片详情…";self.status.hidden=NO;[self.spinner startAnimating];
    NSMutableDictionary *args=[@{@"id":self.item[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;
    __weak typeof(self) weakSelf=self;
    [self.client call:@"detail" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaDetailViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;[owner.spinner stopAnimating];
        if(error||![result isKindOfClass:NSDictionary.class]){if(owner.detail){owner.status.text=[NSString stringWithFormat:@"刷新失败 · 保留当前详情：%@",error.localizedDescription?:@"来源未返回详情"];owner.status.hidden=NO;}else{owner.status.text=[NSString stringWithFormat:@"影片详情加载失败\n%@",error.localizedDescription?:@"来源没有提供影片详情"];owner.status.hidden=NO;}return;}
        owner.detail=result;owner.status.text=@"";owner.status.hidden=YES;owner.title=[result[@"name"] length]?result[@"name"]:owner.title;owner.titleLabel.text=owner.title;
        if(!owner.resumeEntry){NSString *sourceID=owner.source[@"id"]?:@"",*itemID=owner.item[@"id"]?[owner.item[@"id"] description]:@"";owner.resumeEntry=[MediaPlaybackStateStore latestHistoryForSourceID:sourceID provider:owner.provider?:@"" itemID:itemID];}
        [owner restoreResumeEntrySelection];[owner refreshDetailHeader];[owner updateRouteAndEpisodeViews];
        if(!owner.lines.count){owner.status.text=@"此来源未返回可播放分集，请更换站点或检查源配置";owner.status.hidden=NO;[RuntimeDiagnostics.shared recordEvent:@"media_detail_no_episodes" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@""}];}
    }];
}
- (void)restoreResumeEntrySelection {
    NSDictionary *entry=self.resumeEntry;if(![entry isKindOfClass:NSDictionary.class])return;
    if(![entry[@"sourceID"] isEqual:self.source[@"id"]]||![entry[@"provider"] isEqual:self.provider?:@""]||![entry[@"itemID"] isEqual:([self.item[@"id"] description]?:@"")]){self.resumeEntry=nil;return;}
    NSInteger lineIndex=[entry[@"lineIndex"] integerValue],episodeIndex=[entry[@"episodeIndex"] integerValue];NSString *lineID=entry[@"lineID"]?:@"",*episodeID=entry[@"episodeID"]?:@"";BOOL lineFound=NO;
    for(NSUInteger index=0;index<self.lines.count;index++)if(lineID.length&&[[self.lines[index][@"id"] description] isEqual:lineID]){lineIndex=(NSInteger)index;lineFound=YES;break;}
    if(lineID.length&&!lineFound){self.resumeEntry=nil;return;}if(!lineFound&&(lineIndex<0||lineIndex>=self.lines.count))lineIndex=0;
    NSArray *episodes=lineIndex>=0&&lineIndex<self.lines.count&&[self.lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[(NSUInteger)lineIndex][@"episodes"]:@[];BOOL episodeFound=NO;
    for(NSUInteger index=0;index<episodes.count;index++)if(episodeID.length&&[[episodes[index][@"id"] description] isEqual:episodeID]){episodeIndex=(NSInteger)index;episodeFound=YES;break;}
    if((episodeID.length&&!episodeFound)||(!episodeFound&&(episodeIndex<0||episodeIndex>=episodes.count))){self.resumeEntry=nil;return;}
    self.selectedLineIndex=lineIndex;self.selectedEpisodeIndex=episodeIndex;self.episodePage=episodeIndex/12;
}
- (NSString *)metadataSummary {
    NSMutableArray *parts=[NSMutableArray array];for(NSString *key in @[@"year",@"area",@"lang",@"type",@"remarks"]){id value=self.detail[key];if([value isKindOfClass:NSString.class]&&[value length])[parts addObject:value];}
    return parts.count?[parts componentsJoinedByString:@" · "]:@"";
}
- (void)refreshDetailHeader {
    NSString *banner=[self.detail[@"banner"] isKindOfClass:NSString.class]?self.detail[@"banner"]:([self.item[@"banner"] isKindOfClass:NSString.class]?self.item[@"banner"]:@"");self.bannerView.hidden=banner.length==0;self.bannerView.image=nil;if(banner.length)[HostImageLoader.shared loadPosterURL:banner intoImageView:self.bannerView];
    NSString *poster=[self.detail[@"poster"] isKindOfClass:NSString.class]&&[self.detail[@"poster"] length]?self.detail[@"poster"]:([self.item[@"poster"] isKindOfClass:NSString.class]?self.item[@"poster"]:@"");self.posterView.image=nil;if(poster.length)[HostImageLoader.shared loadPosterURL:poster intoImageView:self.posterView];
    NSString *name=[self.detail[@"name"] length]?self.detail[@"name"]:(self.item[@"name"]?:@"影片详情");self.heroTitle.text=name;self.heroMetadata.text=[self metadataSummary];
    NSMutableArray *info=[NSMutableArray array];NSString *metadata=[self metadataSummary];if(metadata.length)[info addObject:metadata];NSString *actors=[self.detail[@"actor"] isKindOfClass:NSString.class]?self.detail[@"actor"]:@"";NSString *director=[self.detail[@"director"] isKindOfClass:NSString.class]?self.detail[@"director"]:@"";
    if(director.length)[info addObject:[NSString stringWithFormat:@"导演：%@",director]];if(actors.length)[info addObject:[NSString stringWithFormat:@"主演：%@",actors]];self.metadataLabel.text=[info componentsJoinedByString:@"\n"];
    NSString *synopsis=[self.detail[@"description"] isKindOfClass:NSString.class]?self.detail[@"description"]:@"";if(synopsis.length>1200)synopsis=[[synopsis substringToIndex:1200] stringByAppendingString:@"…"];self.descriptionLabel.text=synopsis.length?synopsis:@"暂无简介";self.descriptionToggle.hidden=synopsis.length<220;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:5;[self updateFavoriteButton];
}
- (NSString *)favoriteKey {NSString *sourceID=self.source[@"id"]?:@"",*provider=self.provider?:@"",*itemID=self.item[@"id"]?:@"";return [NSString stringWithFormat:@"%lu:%@%lu:%@%lu:%@",(unsigned long)sourceID.length,sourceID,(unsigned long)provider.length,provider,(unsigned long)itemID.length,itemID];}
- (void)updateFavoriteButton {
    NSDictionary *favorites=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};BOOL favorite=favorites[[self favoriteKey]]!=nil;[self.favoriteButton setTitle:favorite?@"♥  已收藏":@"♡  收藏" forState:UIControlStateNormal];
    [self.favoriteButton setTitleColor:favorite?HostAccent():HostText() forState:UIControlStateNormal];self.favoriteButton.accessibilityLabel=favorite?@"取消收藏影片":@"收藏影片";
}
- (void)toggleFavorite {
    NSMutableDictionary *favorites=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"] mutableCopy]?:[NSMutableDictionary dictionary];NSString *key=[self favoriteKey];
    if(favorites[key]) [favorites removeObjectForKey:key];else favorites[key]=@{@"sourceID":self.source[@"id"]?:@"",@"sourceName":self.source[@"name"]?:@"",@"provider":self.provider?:@"",@"item":self.item?:@{}};
    [NSUserDefaults.standardUserDefaults setObject:favorites forKey:@"cctv.mediaFavorites.v1"];[self updateFavoriteButton];
}
- (void)toggleDescription {self.descriptionExpanded=!self.descriptionExpanded;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:5;[self.descriptionToggle setTitle:self.descriptionExpanded?@"收起简介":@"展开简介" forState:UIControlStateNormal];}
- (void)updateRouteAndEpisodeViews {
    for(UIView *view in self.routeButtons.arrangedSubviews.copy){[self.routeButtons removeArrangedSubview:view];[view removeFromSuperview];}if(self.selectedLineIndex>=self.lines.count)self.selectedLineIndex=0;
    for(NSUInteger index=0;index<self.lines.count;index++){NSDictionary *line=self.lines[index];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;NSString *name=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)index+1];
        [button setTitle:name forState:UIControlStateNormal];button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-route-%lu",(unsigned long)index];HostStylePillButton(button,index==self.selectedLineIndex);[button addTarget:self action:@selector(selectRoute:) forControlEvents:UIControlEventTouchUpInside];[self.routeButtons addArrangedSubview:button];}
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];self.episodeTitle.text=[NSString stringWithFormat:@"选集 · %lu 集",(unsigned long)episodes.count];
    NSUInteger pageCount=MAX(1,(episodes.count+11)/12);self.episodePage=MIN(self.episodePage,(NSInteger)pageCount-1);NSUInteger start=(NSUInteger)self.episodePage*12,end=MIN(start+12,episodes.count);
    self.pageLabel.text=episodes.count?[NSString stringWithFormat:@"第 %ld/%lu 页  ·  第 %lu–%lu 集",(long)self.episodePage+1,(unsigned long)pageCount,(unsigned long)start+1,(unsigned long)end]:@"此线路没有可选分集";
    self.previousPageButton.hidden=pageCount<=1;self.nextPageButton.hidden=pageCount<=1;self.previousPageButton.enabled=self.episodePage>0;self.nextPageButton.enabled=self.episodePage+1<pageCount;self.playButton.enabled=episodes.count>0;self.playButton.alpha=episodes.count?1.0:0.55;
    NSDictionary *selectedLine=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex]:@{};NSDictionary *selectedEpisode=self.selectedEpisodeIndex<episodes.count?episodes[self.selectedEpisodeIndex]:@{};NSString *resumeLineID=self.resumeEntry[@"lineID"]?:@"",*resumeEpisodeID=self.resumeEntry[@"episodeID"]?:@"";BOOL lineMatches=resumeLineID.length?[[selectedLine[@"id"] description] isEqual:resumeLineID]:self.selectedLineIndex==[self.resumeEntry[@"lineIndex"] integerValue];BOOL episodeMatches=resumeEpisodeID.length?[[selectedEpisode[@"id"] description] isEqual:resumeEpisodeID]:self.selectedEpisodeIndex==[self.resumeEntry[@"episodeIndex"] integerValue];BOOL resumeSelected=self.resumeEntry&&lineMatches&&episodeMatches;
    if(resumeSelected){NSString *verb=[self.resumeEntry[@"completed"] boolValue]?@"重新播放":@"继续观看";[self.playButton setTitle:[NSString stringWithFormat:@"▶︎  %@ · %@",verb,self.resumeEntry[@"episodeName"]?:@"上次分集"] forState:UIControlStateNormal];}else [self.playButton setTitle:@"▶︎  播放" forState:UIControlStateNormal];
    for(UIView *row in self.episodeGrid.arrangedSubviews.copy){[self.episodeGrid removeArrangedSubview:row];[row removeFromSuperview];}[self.episodeButtons removeAllObjects];if(!episodes.count)return;
    for(NSUInteger rowIndex=0;rowIndex<4;rowIndex++){UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=8;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<3;col++){NSUInteger index=start+rowIndex*3+col;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.layer.cornerRadius=15;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
            if(index<end){NSDictionary *episode=episodes[index];NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];[button setTitle:name forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-episode-%lu",(unsigned long)index];HostStylePillButton(button,(NSInteger)index==self.selectedEpisodeIndex);[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.episodeButtons addObject:button];}
            else button.hidden=YES;[row addArrangedSubview:button];}
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
}
- (void)selectRoute:(UIButton *)sender {self.generation++;[self.client cancel];[self.spinner stopAnimating];self.status.hidden=YES;self.resumeEntry=nil;self.selectedLineIndex=sender.tag;self.selectedEpisodeIndex=0;self.episodePage=0;[self updateRouteAndEpisodeViews];}
- (void)previousEpisodePage {if(self.episodePage>0){self.episodePage--;[self updateRouteAndEpisodeViews];}}
- (void)nextEpisodePage {NSArray *episodes=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(self.episodePage+1<(NSInteger)(episodes.count+11)/12){self.episodePage++;[self updateRouteAndEpisodeViews];}}
- (void)selectEpisode:(UIButton *)sender {self.resumeEntry=nil;self.selectedEpisodeIndex=sender.tag;[self resolveAndPlaySelectedEpisode];}
- (void)playCurrentEpisode {NSArray *episodes=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(!episodes.count)return;if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;[self resolveAndPlaySelectedEpisode];}
- (void)resolveAndPlaySelectedEpisode {
    if(self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=self.lines[self.selectedLineIndex][@"episodes"];if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)return;
    NSDictionary *line=self.lines[self.selectedLineIndex],*episode=episodes[self.selectedEpisodeIndex];NSUInteger generation=++self.generation;[self.client cancel];self.status.hidden=NO;self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];[self.spinner startAnimating];[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"", @"request_generation":@(generation), @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex)}];
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaDetailViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;[owner.spinner stopAnimating];owner.status.hidden=NO;
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"request_generation":@(generation), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.status.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];[owner updateRouteAndEpisodeViews];return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"request_generation":@(generation)}];owner.status.hidden=YES;NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"lineIndex":@(owner.selectedLineIndex),@"episodeIndex":@(owner.selectedEpisodeIndex),@"correlationID":owner.diagnosticTraceID?:@""};if(owner.onPlay)owner.onPlay(result,context);
    }];
}
@end
@interface MediaFavoritesViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *entries;
@property(nonatomic,copy) void (^onSelect)(NSDictionary *entry);
@end
@implementation MediaFavoritesViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"影视收藏";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=78;
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};
    NSPredicate *valid=[NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry,NSDictionary *bindings){return [entry isKindOfClass:NSDictionary.class]&&[entry[@"item"] isKindOfClass:NSDictionary.class];}];
    self.entries=[[saved.allValues filteredArrayUsingPredicate:valid] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSString *left=a[@"item"][@"name"]?:@"",*right=b[@"item"][@"name"]?:@"";return [left localizedStandardCompare:right];}];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(self.entries.count){self.tableView.backgroundView=nil;return self.entries.count;}
    UILabel *empty=[[UILabel alloc] initWithFrame:self.tableView.bounds];empty.text=@"还没有收藏影视\n在影片详情页点按「收藏」即可保存";empty.textAlignment=NSTextAlignmentCenter;empty.numberOfLines=0;empty.textColor=HostSecondaryText();self.tableView.backgroundView=empty;return 0;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"media.favorite"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media.favorite"];
    NSDictionary *entry=self.entries[indexPath.row],*item=entry[@"item"]?:@{};cell.backgroundColor=HostCard();cell.textLabel.text=item[@"name"]?:@"影片";cell.textLabel.textColor=HostText();cell.textLabel.numberOfLines=2;
    NSMutableArray *parts=[NSMutableArray array];if([entry[@"sourceName"] length])[parts addObject:entry[@"sourceName"]];if([entry[@"provider"] length])[parts addObject:entry[@"provider"]];if([item[@"remarks"] length])[parts addObject:item[@"remarks"]];cell.detailTextLabel.text=[parts componentsJoinedByString:@" · "];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";if(poster.length)[HostImageLoader.shared loadURL:poster intoImageView:cell.imageView];return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {[tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.onSelect&&indexPath.row<self.entries.count)self.onSelect(self.entries[indexPath.row]);}
@end

@interface MediaWatchHistoryViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *entries;
@property(nonatomic,copy) void (^onSelect)(NSDictionary *entry);
@end
@implementation MediaWatchHistoryViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"观看历史";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=78;
    self.entries=MediaPlaybackStateStore.watchHistory;
    [self updateClearHistoryButton];
}
- (void)updateClearHistoryButton {self.navigationItem.rightBarButtonItem=self.entries.count?[[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClearHistory)]:nil;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(self.entries.count){self.tableView.backgroundView=nil;return self.entries.count;}
    UILabel *empty=[[UILabel alloc] initWithFrame:self.tableView.bounds];empty.text=@"还没有观看记录\n播放过的影片会保存在这里";empty.textAlignment=NSTextAlignmentCenter;empty.numberOfLines=0;empty.textColor=HostSecondaryText();self.tableView.backgroundView=empty;return 0;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"media.history"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media.history"];
    NSDictionary *entry=self.entries[indexPath.row],*item=entry[@"item"]?:@{};cell.backgroundColor=HostCard();cell.textLabel.text=item[@"name"]?:@"影片";cell.textLabel.textColor=HostText();cell.textLabel.numberOfLines=2;
    NSTimeInterval position=[entry[@"position"] doubleValue],duration=[entry[@"duration"] doubleValue];NSUInteger mm=(NSUInteger)MAX(0,position)/60,ss=(NSUInteger)MAX(0,position)%60;
    NSString *progress=[entry[@"completed"] boolValue]?@"已看完":(duration>0?[NSString stringWithFormat:@"看到 %02lu:%02lu",(unsigned long)mm,(unsigned long)ss]:@"已开始播放");
    NSMutableArray *parts=[NSMutableArray array];if([entry[@"episodeName"] length])[parts addObject:entry[@"episodeName"]];if([entry[@"sourceName"] length])[parts addObject:entry[@"sourceName"]];if([entry[@"provider"] length])[parts addObject:entry[@"provider"]];[parts addObject:progress];
    cell.detailTextLabel.text=[parts componentsJoinedByString:@" · "];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";if(poster.length)[HostImageLoader.shared loadURL:poster intoImageView:cell.imageView];return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {[tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.onSelect&&indexPath.row<self.entries.count)self.onSelect(self.entries[indexPath.row]);}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.row>=self.entries.count)return nil;NSDictionary *entry=self.entries[indexPath.row];__weak typeof(self) weakSelf=self;
    UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"移除" handler:^(UIContextualAction *action,UIView *sourceView,void(^completion)(BOOL)){
        MediaWatchHistoryViewController *owner=weakSelf;if(!owner){completion(NO);return;}
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"移除此条观看记录？" message:@"只会移除这条本机历史，不会删除收藏、订阅或插件数据。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *cancel){completion(NO);}]];
        [alert addAction:[UIAlertAction actionWithTitle:@"移除记录" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *confirm){[MediaPlaybackStateStore removeHistoryEntryWithKey:entry[@"key"]];NSMutableArray *updated=[owner.entries mutableCopy];[updated removeObjectAtIndex:indexPath.row];owner.entries=updated;[owner.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];[owner updateClearHistoryButton];completion(YES);}]];
        [owner presentViewController:alert animated:YES completion:nil];
    }];remove.image=[UIImage systemImageNamed:@"trash"];
    UISwipeActionsConfiguration *configuration=[UISwipeActionsConfiguration configurationWithActions:@[remove]];configuration.performsFirstActionWithFullSwipe=NO;return configuration;
}
- (void)confirmClearHistory {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清空观看历史" message:@"仅清除本机记录，不会删除影片收藏或插件数据。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){[MediaPlaybackStateStore clearWatchHistory];self.entries=@[];[self updateClearHistoryButton];[self.tableView reloadData];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

static NSString * const MediaHomeModulesDefaultsKey = @"cctv.mediaHome.modules.v1";
static NSString * const MediaHomeModulesSchemaKey = @"cctv.mediaHome.modules.schemaVersion";
static NSString * const MediaHomePinnedSourcesDefaultsKey = @"cctv.mediaHome.pinnedSources.v1";
static NSArray<NSDictionary *> *MediaHomeModuleDefinitions(void) {
    return @[@{@"id":@"recommendations",@"title":@"来源推荐",@"detail":@"显示所选来源已有的推荐缓存；不会在首页自动启动服务"},
             @{@"id":@"continue",@"title":@"继续观看",@"detail":@"显示未看完的本机播放记录"},
             @{@"id":@"favorites",@"title":@"影视收藏",@"detail":@"显示已收藏的影片"},
             @{@"id":@"sources",@"title":@"固定来源",@"detail":@"在首页快速打开常用影视资源"}];
}
static NSSet<NSString *> *MediaHomeEnabledModules(void) {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;NSArray *saved=[defaults arrayForKey:MediaHomeModulesDefaultsKey];
    if(!saved)return [NSSet setWithArray:@[@"recommendations",@"continue",@"favorites",@"sources"]];
    NSMutableSet *valid=[NSMutableSet set];NSSet *allowed=[NSSet setWithArray:@[@"recommendations",@"continue",@"favorites",@"sources"]];for(id value in saved)if([value isKindOfClass:NSString.class]&&[allowed containsObject:value])[valid addObject:value];
    // One-time additive migration: users who configured the original three
    // modules get the new cache-backed shelf, while later opt-outs persist.
    if([defaults integerForKey:MediaHomeModulesSchemaKey]<2){if(valid.count)[valid addObject:@"recommendations"];[defaults setObject:[[valid allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:MediaHomeModulesDefaultsKey];[defaults setInteger:2 forKey:MediaHomeModulesSchemaKey];}
    return valid;
}
static NSSet<NSString *> *MediaHomePinnedSources(void) {
    NSArray *saved=[NSUserDefaults.standardUserDefaults arrayForKey:MediaHomePinnedSourcesDefaultsKey];NSMutableSet *valid=[NSMutableSet set];for(id value in saved?:@[])if([value isKindOfClass:NSString.class]&&[value length])[valid addObject:value];return valid;
}

@interface MediaHomeConfigurationViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *sources;
@property(nonatomic,copy) dispatch_block_t onChange;
@property(nonatomic,strong) NSMutableSet<NSString *> *modules;
@property(nonatomic,strong) NSMutableSet<NSString *> *pinnedSources;
@end
@implementation MediaHomeConfigurationViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"首页模块";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.modules=[MediaHomeEnabledModules() mutableCopy];self.pinnedSources=[MediaHomePinnedSources() mutableCopy];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}
- (void)close {[self dismissViewControllerAnimated:YES completion:self.onChange];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 2;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?MediaHomeModuleDefinitions().count:self.sources.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return section==0?@"显示模块":@"固定的影视来源";}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return section==0?@"首页内容来自本机观看记录、影视收藏和已导入资源。关闭模块只会隐藏首页入口，不会删除数据。":(self.sources.count?@"固定来源只会显示在首页。点按来源后才会启动对应服务。":@"导入影视资源后，可以在这里固定常用来源。");}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"media-home-setting"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media-home-setting"];cell.backgroundColor=HostCard();cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryNone;
    NSString *identifier=nil;BOOL enabled=NO;if(indexPath.section==0){NSDictionary *row=MediaHomeModuleDefinitions()[indexPath.row];identifier=row[@"id"];cell.textLabel.text=row[@"title"];cell.detailTextLabel.text=row[@"detail"];enabled=[self.modules containsObject:identifier];}else{NSDictionary *source=self.sources[indexPath.row];identifier=source[@"id"]?:@"";cell.textLabel.text=source[@"name"]?:@"影视来源";NSString *engine=source[@"engine"]?:@"未知运行引擎";cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · 点按卡片时才启动",engine];enabled=[self.pinnedSources containsObject:identifier];}
    UISwitch *toggle=[UISwitch new];toggle.on=enabled;toggle.accessibilityIdentifier=[NSString stringWithFormat:@"%@:%@",indexPath.section==0?@"module":@"source",identifier];[toggle addTarget:self action:@selector(toggleSetting:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;return cell;
}
- (void)toggleSetting:(UISwitch *)sender {
    NSArray *parts=[sender.accessibilityIdentifier componentsSeparatedByString:@":"];if(parts.count!=2)return;NSString *kind=parts[0],*identifier=parts[1];NSMutableSet *set=[kind isEqual:@"module"]?self.modules:self.pinnedSources;if(sender.isOn)[set addObject:identifier];else[set removeObject:identifier];NSString *key=[kind isEqual:@"module"]?MediaHomeModulesDefaultsKey:MediaHomePinnedSourcesDefaultsKey;[NSUserDefaults.standardUserDefaults setObject:[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:key];if([kind isEqual:@"module"])[NSUserDefaults.standardUserDefaults setInteger:2 forKey:MediaHomeModulesSchemaKey];if(self.onChange)self.onChange();
}
@end

@interface MediaBrowserViewController () <UICollectionViewDataSource,UICollectionViewDelegateFlowLayout,UISearchResultsUpdating>
@property(nonatomic, strong) UICollectionView *grid;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic,strong) UISegmentedControl *modeControl;
@property(nonatomic,strong) UIScrollView *homeScroll;
@property(nonatomic,strong) UIStackView *homeStack;
@property(nonatomic, strong) UIScrollView *categoryScroll;
@property(nonatomic, strong) UIStackView *categories;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UILabel *readinessStageLabel;
@property(nonatomic, strong) UIButton *resourceButton;
@property(nonatomic, strong) UIButton *moreButton;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIStackView *selectionRow;
@property(nonatomic, strong) UIButton *sourceSelectButton;
@property(nonatomic, strong) UIButton *providerSelectButton;
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
@property(nonatomic) NSUInteger capabilityReadinessRetryCount;
@property(nonatomic,copy) NSString *diagnosticTraceID;
@property(nonatomic,strong) MediaAPIClient *configurationClient;
@property(nonatomic) BOOL openConfigurationWhenReady;
@property(nonatomic) BOOL sourceInvalidated;
@property(nonatomic) NSUInteger searchGeneration;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *browseStates;
@property(nonatomic,copy) NSDictionary *pendingBrowseState;
@property(nonatomic,copy) NSDictionary *pendingHistoryEntry;
@property(nonatomic,strong) NSNumber *pendingRestoreOffset;
@property(nonatomic) NSInteger pendingRestorePage;
@property(nonatomic, copy) NSDictionary *filters;
@property(nonatomic, strong) NSMutableDictionary *selectedFilters;
@property(nonatomic) BOOL homeMode;
- (void)showHome:(BOOL)animated;
- (void)showBrowse:(BOOL)animated;
- (void)refreshHomeModules;
- (void)openHomeConfiguration;
- (void)openHomeFavorite:(NSDictionary *)entry;
- (void)openHomeRecommendation:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider;
- (void)browseRecommendations;
- (void)applyHomeResult:(NSDictionary *)result;
- (void)presentPicker:(MediaSourcePicker *)picker;
- (void)openFavorites;
- (void)openHistory;
- (void)openHistoryEntry:(NSDictionary *)entry;
- (void)openHistoryDetail:(NSDictionary *)entry source:(NSDictionary *)source provider:(NSString *)provider;
- (void)saveCurrentBrowseState;
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action;
- (void)updateSelectionControls;
- (void)openGlobalSearch;
@end
@implementation MediaBrowserViewController
- (void)searchHistorySettingChanged:(NSNotification *)notification {if([notification.userInfo[@"enabled"] boolValue])return;for(NSString *key in self.browseStates.allKeys.copy){NSMutableDictionary *state=[self.browseStates[key] mutableCopy];if(state){state[@"keyword"]=@"";self.browseStates[key]=state;}}if(self.pendingBrowseState){NSMutableDictionary *pending=[self.pendingBrowseState mutableCopy];pending[@"keyword"]=@"";self.pendingBrowseState=pending;}}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated];if(!self.homeMode)[self saveCurrentBrowseState]; }
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];if(self.homeMode)[self refreshHomeModules];}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        HostStyleNavigation(self.navigationController);
        HostRefreshAppearanceLayers(self.view.window);
    }
    if(previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self.grid.collectionViewLayout invalidateLayout];
        [self.grid reloadData];
    }
}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"首页";self.view.backgroundColor=HostBackground();self.items=@[];self.keyword=@"";self.homeMode=YES;NSDictionary *savedBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];self.browseStates=[savedBrowse isKindOfClass:NSDictionary.class]?[savedBrowse mutableCopy]:[NSMutableDictionary dictionary];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(searchHistorySettingChanged:) name:@"MediaGlobalSearchHistoryDidChange" object:nil];self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"搜索当前影视来源";self.search.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.definesPresentationContext=YES;
    __weak typeof(self) weakSelf=self;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"ellipsis",@"title":@"更多影视操作",@"menu":[UIMenu menuWithChildren:@[
            [UIAction actionWithTitle:@"配置首页模块" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction *action){[weakSelf openHomeConfiguration];}],
            [UIAction actionWithTitle:@"全站搜索" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *action){[weakSelf openGlobalSearch];}],
            [UIAction actionWithTitle:@"源配置与账号" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *action){[weakSelf openSourceConfiguration];}],
            [UIAction actionWithTitle:@"我的收藏" image:[UIImage systemImageNamed:@"heart.fill"] identifier:nil handler:^(UIAction *action){[weakSelf openFavorites];}],
            [UIAction actionWithTitle:@"观看历史" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(UIAction *action){[weakSelf openHistory];}],
            [UIAction actionWithTitle:@"分类筛选" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(UIAction *action){[weakSelf chooseFilters];}],
            [UIAction actionWithTitle:@"刷新当前来源" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action){[weakSelf refreshCurrentSource];}]
        ]]}
    ])];
    self.modeControl=[[UISegmentedControl alloc] initWithItems:@[@"首页",@"影视库"]];self.modeControl.translatesAutoresizingMaskIntoConstraints=NO;self.modeControl.selectedSegmentIndex=0;self.modeControl.accessibilityIdentifier=@"media-home-browse-mode";[self.modeControl addTarget:self action:@selector(changeMediaMode:) forControlEvents:UIControlEventValueChanged];[self.view addSubview:self.modeControl];
    self.homeScroll=[UIScrollView new];self.homeScroll.translatesAutoresizingMaskIntoConstraints=NO;self.homeScroll.alwaysBounceVertical=YES;self.homeScroll.accessibilityIdentifier=@"media-home-scroll";[self.view addSubview:self.homeScroll];
    self.homeStack=[UIStackView new];self.homeStack.translatesAutoresizingMaskIntoConstraints=NO;self.homeStack.axis=UILayoutConstraintAxisVertical;self.homeStack.spacing=18;self.homeStack.layoutMargins=UIEdgeInsetsMake(10,16,28,16);self.homeStack.layoutMarginsRelativeArrangement=YES;[self.homeScroll addSubview:self.homeStack];
    self.selectionRow=[UIStackView new];self.selectionRow.translatesAutoresizingMaskIntoConstraints=NO;self.selectionRow.axis=UILayoutConstraintAxisHorizontal;self.selectionRow.distribution=UIStackViewDistributionFillEqually;self.selectionRow.spacing=10;[self.view addSubview:self.selectionRow];
    self.sourceSelectButton=[self selectionButtonWithSymbol:@"square.stack.3d.up" identifier:@"media-source-selector" action:@selector(chooseResource)];
    self.providerSelectButton=[self selectionButtonWithSymbol:@"globe" identifier:@"media-provider-selector" action:@selector(chooseProvider)];
    [self.selectionRow addArrangedSubview:self.sourceSelectButton];[self.selectionRow addArrangedSubview:self.providerSelectButton];
    self.categoryScroll=[UIScrollView new];self.categoryScroll.showsHorizontalScrollIndicator=NO;self.categoryScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.categoryScroll.translatesAutoresizingMaskIntoConstraints=NO;
    self.categories=[[UIStackView alloc] init];self.categories.axis=UILayoutConstraintAxisHorizontal;self.categories.spacing=10;self.categories.translatesAutoresizingMaskIntoConstraints=NO;[self.categoryScroll addSubview:self.categories];[self.view addSubview:self.categoryScroll];
    self.readinessStageLabel=[UILabel new];self.readinessStageLabel.translatesAutoresizingMaskIntoConstraints=NO;self.readinessStageLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.readinessStageLabel.adjustsFontForContentSizeCategory=YES;self.readinessStageLabel.textColor=HostSecondaryText();self.readinessStageLabel.numberOfLines=1;self.readinessStageLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.readinessStageLabel.accessibilityIdentifier=@"media-readiness-stage";[self.view addSubview:self.readinessStageLabel];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];layout.minimumInteritemSpacing=10;layout.minimumLineSpacing=16;layout.sectionInset=UIEdgeInsetsMake(12,14,16,14);
    self.grid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];self.grid.translatesAutoresizingMaskIntoConstraints=NO;self.grid.backgroundColor=HostBackground();self.grid.dataSource=self;self.grid.delegate=self;self.grid.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self.grid registerClass:MediaPosterCell.class forCellWithReuseIdentifier:@"movie"];[self.view addSubview:self.grid];
    self.moreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.moreButton.translatesAutoresizingMaskIntoConstraints=NO;[self.moreButton setTitle:@"加载更多" forState:UIControlStateNormal];HostStylePillButton(self.moreButton,YES);[self.moreButton addTarget:self action:@selector(loadMore) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.moreButton];self.moreButton.hidden=YES;
    self.status=[UILabel new];self.status.textColor=UIColor.secondaryLabelColor;self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.status];
    self.resourceButton=[UIButton buttonWithType:UIButtonTypeSystem];self.resourceButton.translatesAutoresizingMaskIntoConstraints=NO;[self.resourceButton setTitle:@"管理资源" forState:UIControlStateNormal];HostStylePillButton(self.resourceButton,NO);[self.resourceButton addTarget:self action:@selector(openResources) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.resourceButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.modeControl.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],[self.modeControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[self.modeControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[self.modeControl.heightAnchor constraintGreaterThanOrEqualToConstant:34],
        [self.homeScroll.topAnchor constraintEqualToAnchor:self.selectionRow.bottomAnchor constant:8],[self.homeScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.homeScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.homeScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.homeStack.leadingAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.leadingAnchor],[self.homeStack.trailingAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.trailingAnchor],[self.homeStack.topAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.topAnchor],[self.homeStack.bottomAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.bottomAnchor],[self.homeStack.widthAnchor constraintEqualToAnchor:self.homeScroll.frameLayoutGuide.widthAnchor],
        [self.selectionRow.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:8],[self.selectionRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],[self.selectionRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],[self.selectionRow.heightAnchor constraintGreaterThanOrEqualToConstant:46],
        [self.categoryScroll.topAnchor constraintEqualToAnchor:self.selectionRow.bottomAnchor constant:8],[self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.categoryScroll.heightAnchor constraintEqualToConstant:44],
        [self.categories.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor constant:14],[self.categories.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor constant:-14],[self.categories.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor constant:4],[self.categories.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor constant:-4],[self.categories.heightAnchor constraintEqualToConstant:36],
        [self.readinessStageLabel.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor constant:2],[self.readinessStageLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[self.readinessStageLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[self.readinessStageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:16],
        [self.grid.topAnchor constraintEqualToAnchor:self.readinessStageLabel.bottomAnchor constant:2],[self.grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.grid.bottomAnchor constraintEqualToAnchor:self.moreButton.topAnchor],
        [self.moreButton.heightAnchor constraintEqualToConstant:40],[self.moreButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.moreButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],[self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.resourceButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:16],[self.resourceButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-16]]];
    [self setBrowseControlsHidden:YES];
    [self loadSources];
}
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);button.layer.cornerRadius=23;button.contentEdgeInsets=UIEdgeInsetsMake(8,12,8,12);button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.82;button.accessibilityIdentifier=identifier;button.accessibilityTraits|=UIAccessibilityTraitButton;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostAccent();button.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,7);[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)updateSelectionControls {
    NSString *sourceName=[self.source[@"name"] isKindOfClass:NSString.class]?self.source[@"name"]:@"";NSString *sourceTitle=sourceName.length?sourceName:@"选择影视资源";
    [self.sourceSelectButton setTitle:[NSString stringWithFormat:@"%@  ▾",sourceTitle] forState:UIControlStateNormal];self.sourceSelectButton.accessibilityLabel=sourceName.length?[NSString stringWithFormat:@"影视资源：%@，点按切换",sourceName]:@"选择影视资源";self.sourceSelectButton.accessibilityHint=@"先选择影视资源，再选择该资源提供的站点";
    NSString *providerTitle=nil;for(NSDictionary *candidate in self.providers){if([candidate[@"id"] isEqual:self.provider]){providerTitle=[candidate[@"name"] isKindOfClass:NSString.class]?candidate[@"name"]:candidate[@"id"];break;}}
    if(!providerTitle.length&&self.provider.length)providerTitle=self.provider;
    if(!providerTitle.length)providerTitle=self.providers.count?@"选择站点":(self.loading?@"加载站点…":(self.source?@"暂无站点":@"选择站点"));
    BOOL directAPI=MediaSourceUsesNativeCatalogAPI(self.source);self.providerSelectButton.hidden=directAPI;[self.providerSelectButton setTitle:directAPI?([self.source[@"protocol"] isEqual:@"maccms-api"]?@"MacCMS API":@"TVBox API"):[NSString stringWithFormat:@"%@  ▾",providerTitle] forState:UIControlStateNormal];self.providerSelectButton.enabled=!directAPI&&self.source!=nil&&self.providers.count>0;self.providerSelectButton.alpha=self.providerSelectButton.enabled?1.0:0.62;self.providerSelectButton.accessibilityLabel=self.providers.count>0?[NSString stringWithFormat:@"影视站点：%@，点按切换",providerTitle]:@"当前影视资源没有可切换的多个站点";self.providerSelectButton.accessibilityHint=self.loading?@"正在加载当前影视站点，请稍候":@"选择当前影视资源下的另一个站点";
}
- (void)setBrowseControlsHidden:(BOOL)hidden {
    self.selectionRow.hidden=NO;self.categoryScroll.hidden=hidden;self.readinessStageLabel.hidden=hidden;self.grid.hidden=hidden;self.moreButton.hidden=hidden||!self.hasMore;self.homeScroll.hidden=!hidden;
    if(hidden){self.navigationItem.searchController=nil;self.search.active=NO;self.status.hidden=YES;self.resourceButton.hidden=YES;[self.spinner stopAnimating];}
    else{self.status.hidden=!self.status.text.length||self.items.count>0;self.resourceButton.hidden=self.loading||self.items.count>0;self.readinessStageLabel.hidden=!self.readinessStageLabel.text.length;}
}
- (void)changeMediaMode:(UISegmentedControl *)sender {if(sender.selectedSegmentIndex==0)[self showHome:YES];else[self showBrowse:YES];}
- (void)showHome:(BOOL)animated {
    if(!self.homeMode)[self saveCurrentBrowseState];self.homeMode=YES;self.modeControl.selectedSegmentIndex=0;self.title=@"首页";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;self.navigationItem.searchController=nil;self.search.active=NO;self.navigationItem.prompt=nil;[self setBrowseControlsHidden:YES];[self refreshHomeModules];if(animated)[UIView transitionWithView:self.homeScroll duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
}
- (void)showBrowse:(BOOL)animated {
    self.homeMode=NO;self.modeControl.selectedSegmentIndex=1;self.title=@"影视库";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;[self setBrowseControlsHidden:NO];
    if(self.source && (!self.client||!self.source[@"capabilities"]||self.sourceInvalidated||(!MediaSourceUsesNativeCatalogAPI(self.source)&&![PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""]))){[self activate:self.source];}
    else if(!self.source){self.items=@[];[self.grid reloadData];[self showMessage:@"尚未导入影视资源，请先在资源页导入并启用影视包" loading:NO];}
    else if(self.pendingBrowseState){[self restorePendingBrowseState];}
    if(animated)[UIView transitionWithView:self.grid duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
}
- (UIButton *)homeActionButton:(NSString *)title symbol:(NSString *)symbol action:(SEL)selector primary:(BOOL)primary {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,primary);[button setTitle:title forState:UIControlStateNormal];[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=primary?HostOnAccent():HostAccent();button.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,7);button.titleLabel.adjustsFontForContentSizeCategory=YES;[button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];return button;
}
- (UIView *)homeSectionHeader:(NSString *)title actionTitle:(NSString *)actionTitle selector:(SEL)selector {
    UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.alignment=UIStackViewAlignmentCenter;row.spacing=8;
    UILabel *label=[UILabel new];label.text=title;label.textColor=HostText();label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];label.adjustsFontForContentSizeCategory=YES;[row addArrangedSubview:label];[row addArrangedSubview:[UIView new]];
    if(actionTitle.length){UIButton *more=[UIButton buttonWithType:UIButtonTypeSystem];[more setTitle:actionTitle forState:UIControlStateNormal];more.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];[more addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];[row addArrangedSubview:more];}
    return row;
}
- (UIButton *)homeCardWithTitle:(NSString *)title subtitle:(NSString *)subtitle imageURL:(NSString *)imageURL symbol:(NSString *)symbol action:(dispatch_block_t)action {
    UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=HostCard();card.layer.cornerRadius=14;card.layer.cornerCurve=kCACornerCurveContinuous;card.layer.borderWidth=0.6;HostSetLayerBorderColor(card,HostBorder());card.clipsToBounds=YES;card.accessibilityLabel=[NSString stringWithFormat:@"%@，%@",title,subtitle?:@""];
    UIImageView *image=[UIImageView new];image.translatesAutoresizingMaskIntoConstraints=NO;image.contentMode=UIViewContentModeScaleAspectFill;image.clipsToBounds=YES;image.backgroundColor=HostNeutralSurface();[card addSubview:image];
    if(imageURL.length)[HostImageLoader.shared loadPosterURL:imageURL intoImageView:image];else if(symbol.length){UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightMedium];image.image=[UIImage systemImageNamed:symbol withConfiguration:config];image.contentMode=UIViewContentModeCenter;image.tintColor=HostAccent();}
    UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.text=title;name.textColor=HostText();name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];name.adjustsFontForContentSizeCategory=YES;name.numberOfLines=2;name.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:name];
    UILabel *detail=[UILabel new];detail.translatesAutoresizingMaskIntoConstraints=NO;detail.text=subtitle;detail.textColor=HostSecondaryText();detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];detail.adjustsFontForContentSizeCategory=YES;detail.numberOfLines=2;detail.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[card.widthAnchor constraintEqualToConstant:148],[card.heightAnchor constraintEqualToConstant:224],[image.topAnchor constraintEqualToAnchor:card.topAnchor],[image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[image.heightAnchor constraintEqualToConstant:145],[name.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:7],[name.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:9],[name.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-9],[detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:3],[detail.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],[detail.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],[detail.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-7]]];
    [card addAction:[UIAction actionWithHandler:^(UIAction *event){if(action)action();}] forControlEvents:UIControlEventTouchUpInside];return card;
}
- (UIButton *)homeFeatureCardForItem:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    NSString *title=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"精选推荐";
    NSString *imageURL=[item[@"banner"] isKindOfClass:NSString.class]?item[@"banner"]:([item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"");
    NSString *remarks=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"";
    UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=HostCard();card.layer.cornerRadius=22;card.layer.cornerCurve=kCACornerCurveContinuous;card.layer.borderWidth=.7;HostSetLayerBorderColor(card,HostBorder());card.clipsToBounds=YES;card.accessibilityIdentifier=@"media-home-feature";card.accessibilityLabel=[NSString stringWithFormat:@"精选影片 %@，%@",title,remarks];
    UIImageView *image=[UIImageView new];image.translatesAutoresizingMaskIntoConstraints=NO;image.contentMode=UIViewContentModeScaleAspectFill;image.clipsToBounds=YES;image.backgroundColor=HostNeutralSurface();[card addSubview:image];if(imageURL.length)[HostImageLoader.shared loadPosterURL:imageURL intoImageView:image];
    UIView *scrim=[UIView new];scrim.translatesAutoresizingMaskIntoConstraints=NO;scrim.backgroundColor=[UIColor colorWithWhite:0 alpha:.46];[card addSubview:scrim];
    UILabel *eyebrow=[UILabel new];eyebrow.translatesAutoresizingMaskIntoConstraints=NO;eyebrow.text=[NSString stringWithFormat:@"%@ · %@",source[@"name"]?:@"影视来源",provider.length?provider:@"精选"];eyebrow.textColor=[UIColor colorWithWhite:1 alpha:.82];eyebrow.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];eyebrow.adjustsFontForContentSizeCategory=YES;eyebrow.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:eyebrow];
    UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.text=title;name.textColor=UIColor.whiteColor;name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];name.adjustsFontForContentSizeCategory=YES;name.numberOfLines=2;name.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:name];
    UILabel *detail=[UILabel new];detail.translatesAutoresizingMaskIntoConstraints=NO;detail.text=remarks.length?remarks:@"点按查看影片详情";detail.textColor=[UIColor colorWithWhite:1 alpha:.86];detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];detail.adjustsFontForContentSizeCategory=YES;detail.numberOfLines=1;detail.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[card.heightAnchor constraintEqualToConstant:214],[image.topAnchor constraintEqualToAnchor:card.topAnchor],[image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[image.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],[scrim.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[scrim.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[scrim.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],[scrim.heightAnchor constraintEqualToConstant:96],[eyebrow.leadingAnchor constraintEqualToAnchor:scrim.leadingAnchor constant:16],[eyebrow.trailingAnchor constraintEqualToAnchor:scrim.trailingAnchor constant:-16],[eyebrow.topAnchor constraintEqualToAnchor:scrim.topAnchor constant:10],[name.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],[name.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],[name.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:2],[detail.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],[detail.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],[detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],[detail.bottomAnchor constraintLessThanOrEqualToAnchor:scrim.bottomAnchor constant:-8]]];
    __weak typeof(self) weakSelf=self;[card addAction:[UIAction actionWithHandler:^(UIAction *event){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHomeRecommendation:item source:source provider:provider];}] forControlEvents:UIControlEventTouchUpInside];return card;
}
- (NSDictionary *)cachedHomeResultForSelectedProvider:(NSString **)providerOut {
    if(!self.source)return nil;
    NSString *provider=self.provider.length?self.provider:[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",self.source[@"id"]?:@""]];
    if(providerOut)*providerOut=provider?:@"";
    NSMutableDictionary *arguments=[NSMutableDictionary dictionary];if(provider.length)arguments[@"provider"]=provider;
    id result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:arguments maximumAge:24*60*60 isStale:NULL];
    return [result isKindOfClass:NSDictionary.class]?result:nil;
}
- (void)addHomeCards:(NSArray<UIButton *> *)cards emptyText:(NSString *)emptyText {
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.showsHorizontalScrollIndicator=NO;scroll.alwaysBounceHorizontal=YES;UIStackView *row=[UIStackView new];row.translatesAutoresizingMaskIntoConstraints=NO;row.axis=UILayoutConstraintAxisHorizontal;row.spacing=10;[scroll addSubview:row];
    if(cards.count){for(UIButton *card in cards)[row addArrangedSubview:card];}else{UILabel *empty=[UILabel new];empty.text=emptyText;empty.textColor=HostSecondaryText();empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];empty.numberOfLines=0;empty.backgroundColor=HostCard();empty.layer.cornerRadius=14;empty.clipsToBounds=YES;empty.textAlignment=NSTextAlignmentCenter;[row addArrangedSubview:empty];[empty.widthAnchor constraintGreaterThanOrEqualToConstant:240].active=YES;[empty.heightAnchor constraintEqualToConstant:78].active=YES;}
    [NSLayoutConstraint activateConstraints:@[[scroll.heightAnchor constraintEqualToConstant:224],[row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],[row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],[row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor]]];[self.homeStack addArrangedSubview:scroll];
}
- (void)refreshHomeModules {
    if(!self.homeStack)return;__weak typeof(self) weakSelf=self;for(UIView *view in self.homeStack.arrangedSubviews.copy){[self.homeStack removeArrangedSubview:view];[view removeFromSuperview];}
    UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisHorizontal;actions.spacing=10;actions.distribution=UIStackViewDistributionFillEqually;UIButton *search=[self homeActionButton:@"全站搜索" symbol:@"magnifyingglass" action:@selector(openGlobalSearchFromHome) primary:YES];UIButton *manage=[self homeActionButton:@"配置首页" symbol:@"slider.horizontal.3" action:@selector(openHomeConfiguration) primary:NO];[actions addArrangedSubview:search];[actions addArrangedSubview:manage];[self.homeStack addArrangedSubview:actions];
    NSSet *enabled=MediaHomeEnabledModules();
    if([enabled containsObject:@"recommendations"]){NSString *cachedProvider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&cachedProvider];NSArray *recommendations=[home[@"items"] isKindOfClass:NSArray.class]?home[@"items"]:@[];NSString *sourceName=[self.source[@"name"] isKindOfClass:NSString.class]?self.source[@"name"]:@"影视来源";
        if(recommendations.count){[self.homeStack addArrangedSubview:[self homeSectionHeader:[NSString stringWithFormat:@"%@ · 为你推荐",sourceName] actionTitle:@"进入影视库" selector:@selector(browseRecommendations)]];[self.homeStack addArrangedSubview:[self homeFeatureCardForItem:recommendations.firstObject source:self.source provider:cachedProvider]];NSMutableArray *cards=[NSMutableArray array];for(NSUInteger index=1;index<recommendations.count&&cards.count<8;index++){NSDictionary *item=recommendations[index];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"影视内容" subtitle:item[@"remarks"]?:@"来自当前影视来源" imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHomeRecommendation:item source:weakSelf.source provider:cachedProvider];}]];}if(cards.count)[self addHomeCards:cards emptyText:@""];}
        else{[self.homeStack addArrangedSubview:[self homeSectionHeader:@"影视推荐" actionTitle:self.source?@"打开影视库":@"导入资源" selector:self.source?@selector(browseRecommendations):@selector(openResources)]];UIButton *empty=[self homeActionButton:self.source?([NSString stringWithFormat:@"%@ · 进入影视库加载推荐",sourceName]):@"添加影视资源后浏览推荐" symbol:self.source?@"sparkles.tv":@"plus" action:self.source?@selector(browseRecommendations):@selector(openResources) primary:NO];empty.accessibilityIdentifier=@"media-home-recommendations-empty";[self.homeStack addArrangedSubview:empty];}}
    if([enabled containsObject:@"continue"]){NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *entry in MediaPlaybackStateStore.watchHistory){if([entry[@"completed"] boolValue]||[entry[@"position"] doubleValue]<=0)continue;NSDictionary *item=entry[@"item"]?:@{};NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",entry[@"episodeName"]?:@"继续观看",entry[@"sourceName"]?:@"本机记录"];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"继续观看" subtitle:subtitle imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHistoryEntry:entry];}]];if(cards.count>=10)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"继续观看" actionTitle:@"全部" selector:@selector(openHistory)]];[self addHomeCards:cards emptyText:@"还没有未看完的影片，开始播放后会显示在这里"];
    }
    if([enabled containsObject:@"favorites"]){NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};NSArray *entries=[saved.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[a[@"item"][@"name"] description] localizedStandardCompare:[b[@"item"][@"name"] description]];}];NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *entry in entries){NSDictionary *item=entry[@"item"]?:@{};NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",entry[@"sourceName"]?:@"影视资源",entry[@"provider"]?:@"站点"];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"已收藏影片" subtitle:subtitle imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHomeFavorite:entry];}]];if(cards.count>=10)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"影视收藏" actionTitle:@"全部" selector:@selector(openFavorites)]];[self addHomeCards:cards emptyText:@"还没有收藏影片，打开影片详情后点按收藏"];
    }
    if([enabled containsObject:@"sources"]){NSMutableSet *pins=[MediaHomePinnedSources() mutableCopy];if(![NSUserDefaults.standardUserDefaults objectForKey:MediaHomePinnedSourcesDefaultsKey]&&self.sources.count){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];if(saved.length)[pins addObject:saved];else for(NSDictionary *source in [self.sources subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)3,self.sources.count))])[pins addObject:source[@"id"]?:@""];[NSUserDefaults.standardUserDefaults setObject:pins.allObjects forKey:MediaHomePinnedSourcesDefaultsKey];}
        NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *source in self.sources){NSString *sourceID=source[@"id"]?:@"";if(![pins containsObject:sourceID])continue;BOOL running=MediaSourceUsesNativeCatalogAPI(source)||[PyHost isRunningServiceIdentifier:sourceID];NSString *engine=source[@"engine"]?:@"影视资源";NSString *subtitle=running?([source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"可直接访问"):engine;[cards addObject:[self homeCardWithTitle:source[@"name"]?:@"影视来源" subtitle:subtitle imageURL:nil symbol:@"square.stack.3d.up" action:^{[weakSelf browsePinnedSource:source];}]];if(cards.count>=12)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"固定来源" actionTitle:@"管理" selector:@selector(openHomeConfiguration)]];[self addHomeCards:cards emptyText:self.sources.count?@"还没有固定来源，点按右上角配置首页添加":@"尚未导入影视资源。可先到资源页导入 Python、JavaScript 或 ZIP 影视包"];
    }
    if(!enabled.count){UILabel *empty=[UILabel new];empty.text=@"首页模块已全部隐藏。使用“配置首页”选择要显示的内容。";empty.textColor=HostSecondaryText();empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];[self.homeStack addArrangedSubview:empty];}
    if(!self.sources.count){UIButton *import=[self homeActionButton:@"导入影视资源" symbol:@"plus" action:@selector(openResources) primary:NO];[self.homeStack addArrangedSubview:import];}
}
- (void)openGlobalSearchFromHome {[self openGlobalSearch];}
- (void)browseRecommendations {[self showBrowse:YES];}
- (void)openHomeRecommendation:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    if(![item isKindOfClass:NSDictionary.class]||![source isKindOfClass:NSDictionary.class])return;
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=self.onPlay;
    NSString *identifier=source[@"id"]?:@"";
    if(MediaSourceUsesNativeCatalogAPI(source)||[PyHost isRunningServiceIdentifier:identifier]){[self.navigationController pushViewController:detail animated:YES];return;}
    if(!self.onActivateService){[self showMessage:@"此影视资源尚未启动，请从资源页启用后再试" loading:NO];return;}
    __weak typeof(self) weakSelf=self;self.onActivateService(source,^(NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner)return;if(error){[owner showMessage:error.localizedDescription?:@"影视资源启动失败" loading:NO];return;}[owner.navigationController pushViewController:detail animated:YES];});
}
- (void)browsePinnedSource:(NSDictionary *)source {self.pendingBrowseState=nil;self.provider=nil;[self activate:source];}
- (void)openHomeConfiguration {
    MediaHomeConfigurationViewController *page=[MediaHomeConfigurationViewController new];page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];__weak typeof(self) weakSelf=self;page.onChange=^{[weakSelf refreshHomeModules];};UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];HostStyleNavigation(navigation);navigation.modalPresentationStyle=UIModalPresentationPageSheet;UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;}[self presentViewController:navigation animated:YES completion:nil];
}
- (void)openHomeFavorite:(NSDictionary *)entry {
    NSString *sourceID=entry[@"sourceID"]?:@"";NSDictionary *source=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:sourceID]){source=candidate;break;}
    if(!source){[self showMessage:@"该收藏对应的影视资源已移除，请重新导入后打开" loading:NO];return;}MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=entry[@"item"]?:@{};detail.source=source;detail.provider=entry[@"provider"]?:@"";detail.onPlay=self.onPlay;
    if(MediaSourceUsesNativeCatalogAPI(source)||[PyHost isRunningServiceIdentifier:sourceID]){[self.navigationController pushViewController:detail animated:YES];return;}
    if(!self.onActivateService){[self showMessage:@"该资源尚未启动，请先到资源页启用后重试" loading:NO];return;}__weak typeof(self) weakSelf=self;self.onActivateService(source,^(NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner)return;if(error){[owner showMessage:error.localizedDescription loading:NO];return;}[owner.navigationController pushViewController:detail animated:YES];});
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];}
- (NSString *)stateKeyForSource:(NSDictionary *)source provider:(NSString *)provider {return [NSString stringWithFormat:@"%@|%@",source[@"id"]?:@"",provider?:@""];}
- (void)saveCurrentBrowseState {if(!self.source)return;if(!self.browseStates)self.browseStates=[NSMutableDictionary dictionary];NSString *key=[self stateKeyForSource:self.source provider:self.provider];NSString *keyword=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]&&[self.keyword isKindOfClass:NSString.class]?self.keyword:@"";if(keyword.length>256)keyword=[keyword substringToIndex:256];NSDictionary *filters=[self.selectedFilters isKindOfClass:NSDictionary.class]?self.selectedFilters:@{};self.browseStates[key]=@{@"keyword":keyword,@"category":self.category?:@"",@"filters":filters,@"provider":self.provider?:@"",@"page":@(MAX(1,MIN(100,self.page))),@"season":@(MAX(1,self.widgetSeason)),@"episode":@(MAX(1,self.widgetEpisode)),@"offset":@(MAX(0,self.grid.contentOffset.y)),@"savedAt":@(NSDate.date.timeIntervalSince1970)};while(self.browseStates.count>32){NSString *oldest=nil;double timestamp=DBL_MAX;for(NSString *candidate in self.browseStates){double value=[self.browseStates[candidate][@"savedAt"] doubleValue];if(value<timestamp){timestamp=value;oldest=candidate;}}if(!oldest)break;[self.browseStates removeObjectForKey:oldest];}[NSUserDefaults.standardUserDefaults setObject:self.browseStates forKey:@"media.browseStates.v1"];}
- (void)restorePendingBrowseState {NSDictionary *state=self.pendingBrowseState;self.pendingBrowseState=nil;if(!state)return;self.keyword=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]&&[state[@"keyword"] isKindOfClass:NSString.class]?state[@"keyword"]:@"";self.category=state[@"category"];self.selectedFilters=[state[@"filters"] isKindOfClass:NSDictionary.class]?[state[@"filters"] mutableCopy]:[NSMutableDictionary dictionary];self.pendingRestorePage=MAX(1,MIN(100,[state[@"page"] integerValue]));self.page=self.pendingRestorePage;self.widgetSeason=MAX(1,[state[@"season"] integerValue]);self.widgetEpisode=MAX(1,[state[@"episode"] integerValue]);self.pendingRestoreOffset=@([state[@"offset"] doubleValue]);self.search.searchBar.text=self.keyword;self.navigationItem.prompt=[self.source[@"protocol"] isEqual:@"widget-extractor"]?[NSString stringWithFormat:@"第 %ld 季 · 第 %ld 集",(long)self.widgetSeason,(long)self.widgetEpisode]:nil;for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.category];button.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:HostNeutralSurface();HostSetLayerBorderColor(button,selected?[HostAccent() colorWithAlphaComponent:0.42]:HostBorder());[button setTitleColor:selected?HostAccent():HostText() forState:UIControlStateNormal];}if(self.keyword.length||self.category.length){self.page=1;[self loadListing:NO];return;}self.pendingRestorePage=0;CGFloat offset=self.pendingRestoreOffset.doubleValue;self.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[self.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
- (void)openFavorites {
    MediaFavoritesViewController *page=[MediaFavoritesViewController new];__weak typeof(self) weakSelf=self;
    page.onSelect=^(NSDictionary *entry){MediaBrowserViewController *owner=weakSelf;if(!owner)return;NSArray *available=owner.sourcesProvider?owner.sourcesProvider():owner.sources?:@[];NSString *sourceID=entry[@"sourceID"]?:@"";NSDictionary *source=nil;
        for(NSDictionary *candidate in available)if([candidate[@"id"] isEqual:sourceID]){source=candidate;break;}
        if(!source){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"影视资源不可用" message:@"该收藏对应的资源未启用或已移除。重新启用资源后即可继续播放。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[owner presentViewController:alert animated:YES completion:nil];return;}
        MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=entry[@"item"]?:@{};detail.source=source;detail.provider=entry[@"provider"]?:@"";detail.onPlay=owner.onPlay;[owner.navigationController pushViewController:detail animated:YES];
    };
    [self.navigationController pushViewController:page animated:YES];
}
- (void)openHistory {
    MediaWatchHistoryViewController *page=[MediaWatchHistoryViewController new];__weak typeof(self) weakSelf=self;
    page.onSelect=^(NSDictionary *entry){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHistoryEntry:entry];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)openHistoryEntry:(NSDictionary *)entry {
    NSString *sourceID=[entry[@"sourceID"] isKindOfClass:NSString.class]?entry[@"sourceID"]:@"";
    NSArray *available=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];NSDictionary *source=nil;
    for(NSDictionary *candidate in available)if([candidate[@"id"] isEqual:sourceID]){source=candidate;break;}
    if(!source){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"影视资源不可用" message:@"这条记录对应的资源已停用或移除。重新导入并启用资源后，可以从资源页继续浏览。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];return;}
    NSString *provider=[entry[@"provider"] isKindOfClass:NSString.class]?entry[@"provider"]:@"";
    BOOL providerAvailable=NO;for(NSDictionary *candidate in self.providers)if([candidate[@"id"] isEqual:provider]){providerAvailable=YES;break;}
    if([self.source[@"id"] isEqual:sourceID]&&providerAvailable&&!self.loading){[self openHistoryDetail:entry source:source provider:provider];return;}
    self.pendingHistoryEntry=entry;[self activate:source];
}
- (void)openHistoryDetail:(NSDictionary *)entry source:(NSDictionary *)source provider:(NSString *)provider {
    NSDictionary *item=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};
    id itemID=item[@"id"];if(![itemID isKindOfClass:NSString.class]&&![itemID isKindOfClass:NSNumber.class]){[self showMessage:@"观看记录缺少影片标识，无法重新打开详情" loading:NO];return;}
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.resumeEntry=entry;detail.onPlay=self.onPlay;[self.navigationController pushViewController:detail animated:YES];
}
- (void)openResources {if(self.onResources)self.onResources();}
- (void)openGlobalSearch {
    MediaGlobalSearchViewController *page=[MediaGlobalSearchViewController new];page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];page.onActivateService=self.onActivateService;__weak typeof(self) weakSelf=self;
    page.onSelectResult=^(NSDictionary *item,NSDictionary *source,NSString *provider){MediaBrowserViewController *owner=weakSelf;if(!owner)return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=owner.onPlay;[owner.navigationController pushViewController:detail animated:YES];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)presentPicker:(MediaSourcePicker *)picker {
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker];HostStyleNavigation(navigation);navigation.navigationBar.prefersLargeTitles=NO;navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;}
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)loadSources {
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    if(!self.sources.count){self.source=nil;self.providers=@[];[self updateSelectionControls];[self refreshHomeModules];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=self.sources.firstObject;for(NSDictionary *source in self.sources)if([source[@"id"] isEqual:saved])selected=source;
    self.source=selected;[self updateSelectionControls];[self refreshHomeModules];
}
- (void)invalidateServiceIdentifier:(NSString *)identifier {
    if(![self.source[@"id"] isEqual:identifier])return;
    [self saveCurrentBrowseState];self.sourceInvalidated=YES;self.generation++;[self.client cancel];[self.configurationClient cancel];[self.readiness cancel];self.loading=NO;self.items=@[];self.providers=@[];self.provider=nil;[self.grid reloadData];[self updateSelectionControls];[self showMessage:@"此资源服务已停止。点按顶部资源重新选择，或在菜单中刷新后启动。" loading:NO];
}
- (void)refreshSources {
    NSArray<NSDictionary *> *updated=self.sourcesProvider?self.sourcesProvider():@[];
    self.sources=updated;
    if(!updated.count){
        self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.source=nil;self.provider=nil;self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.loading=NO;self.moreButton.hidden=YES;[self.grid reloadData];[self updateSelectionControls];[self refreshHomeModules];
        for(UIView *view in self.categories.arrangedSubviews.copy){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
        return;
    }
    if(self.homeMode){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];for(NSDictionary *candidate in updated)if(saved.length&&[candidate[@"id"] isEqual:saved]&&![candidate[@"id"] isEqual:self.source[@"id"]]){self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.source=candidate;self.provider=nil;self.providers=@[];self.items=@[];self.sourceInvalidated=NO;[self.grid reloadData];[self updateSelectionControls];[self refreshHomeModules];return;}}
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:self.source[@"id"]]){BOOL changed=![(candidate[@"packageRoot"]?:@"") isEqual:(self.source[@"packageRoot"]?:@"")]||![(candidate[@"api"]?:@"") isEqual:(self.source[@"api"]?:@"")];self.source=candidate;if(self.homeMode){if(changed){self.generation++;[self.readiness cancel];[self.client cancel];self.client=nil;self.providers=@[];self.items=@[];self.sourceInvalidated=NO;}[self updateSelectionControls];[self refreshHomeModules];return;}if((self.sourceInvalidated||changed)&&MediaSourceUsesNativeCatalogAPI(candidate)){[self activate:candidate];return;}if((self.sourceInvalidated||changed)&&[PyHost isRunningServiceIdentifier:candidate[@"id"]]){[self activate:candidate];return;}if(changed)[self invalidateServiceIdentifier:candidate[@"id"]];[self updateSelectionControls];[self refreshHomeModules];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=updated.firstObject;
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:saved]){selected=candidate;break;}
    if(self.homeMode){self.source=selected;self.provider=nil;self.providers=@[];self.client=nil;[self updateSelectionControls];[self refreshHomeModules];}
    else [self activate:selected];
}
- (void)openSourceIdentifier:(NSString *)identifier {
    NSString *targetID=[identifier isKindOfClass:NSString.class]?[identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(!targetID.length){[self showMessage:@"没有指定影视来源" loading:NO];return;}
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    NSDictionary *target=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:targetID]){target=candidate;break;}
    if(!target){[self updateSelectionControls];[self showMessage:@"此来源已从资源合集移除，请回到资源页重新选择" loading:NO];return;}
    [NSUserDefaults.standardUserDefaults setObject:targetID forKey:@"selectedMediaSource"];
    [self activate:target];
}
- (void)showMessage:(NSString *)message loading:(BOOL)loading {
    self.status.text=message;self.status.hidden=!message.length;self.resourceButton.hidden=loading || self.items.count>0;
    if(loading)[self.spinner startAnimating];else[self.spinner stopAnimating];
}
- (void)chooseResource {
    if(!self.sources.count){[self openResources];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *source in self.sources){BOOL current=[source[@"id"] isEqual:self.source[@"id"]];NSString *engineValue=[source[@"engine"] isKindOfClass:NSString.class]?source[@"engine"]:@"";NSString *engine=engineValue.lowercaseString;NSString *scope=([engine containsString:@"python"]||[engine containsString:@"py"])?@"python":([engine containsString:@"node"])?@"node":([engine containsString:@"javascript"]||[engine isEqual:@"js"])?@"javascriptcore":@"other";NSString *scopeName=[scope isEqual:@"python"]?@"Python":([scope isEqual:@"node"]?@"Node.js":([scope isEqual:@"javascriptcore"]?@"JavaScriptCore":@"其他"));NSString *status=[source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"已导入";NSString *name=[source[@"name"] isKindOfClass:NSString.class]?source[@"name"]:@"影视资源";NSString *url=[source[@"url"] isKindOfClass:NSString.class]?source[@"url"]:@"";NSString *subtitle=[NSString stringWithFormat:@"%@ · %@%@",scopeName,current?@"当前资源 · ":@"",status];[choices addObject:@{@"name":name,@"subtitle":subtitle,@"url":url,@"source":source,@"scope":scope,@"scopeName":scopeName,@"selected":@(current)}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"切换影视资源";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(choice[@"source"])[owner activate:choice[@"source"]];};[self presentPicker:picker];
}
- (void)refreshCurrentSource {
    if(!self.source){[self loadSources];return;}
    if(self.sourceInvalidated||![PyHost isRunningServiceIdentifier:self.source[@"id"]]){[self activate:self.source];return;}
    [self.client cancel];[self.configurationClient cancel];self.configurationClient=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];
    NSString *sourceID=[self.source[@"id"] copy];self.loading=YES;[self showMessage:@"正在刷新资源配置与缓存…" loading:YES];__weak typeof(self) weakSelf=self;
    [self.configurationClient call:@"invalidate" arguments:@{} correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner||![owner.source[@"id"] isEqual:sourceID])return;if(error){owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];[owner updateSelectionControls];return;}[owner activate:owner.source];}];
}
- (void)showConfigurationForSource:(NSDictionary *)source {self.openConfigurationWhenReady=YES;[self activate:source];}
- (void)openSourceConfiguration {
    if(!self.source){[self openResources];return;}
    if(![self.source[@"capabilities"] containsObject:@"configuration"]){self.navigationItem.prompt=@"当前资源尚未提供源配置接口，请先启动并加载资源";return;}
    [self.configurationClient cancel];self.configurationClient=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];
    NSString *sourceID=[self.source[@"id"] copy];__weak typeof(self) weakSelf=self;
    [self.configurationClient call:@"configuration" arguments:@{} correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner||![owner.source[@"id"] isEqual:sourceID])return;
        if(error||![result isKindOfClass:NSDictionary.class]){owner.navigationItem.prompt=error.localizedDescription?:@"源未返回配置页";return;}
        NSURL *url=[result[@"url"] isKindOfClass:NSString.class]?[NSURL URLWithString:result[@"url"]]:nil;
        if(![url.scheme isEqual:@"http"]||![@[@"127.0.0.1",@"localhost",@"::1"] containsObject:url.host.lowercaseString]||url.port.integerValue<1||url.port.integerValue>65535||url.user.length||url.password.length){owner.navigationItem.prompt=@"来源未提供有效的本机配置页";return;}
        NSMutableDictionary *configuration=[result mutableCopy];configuration[@"configurationPage"]=@YES;
        MediaWebViewController *page=[[MediaWebViewController alloc] initWithResult:configuration title:@"源配置与账号"];page.modalInPresentation=YES;
        page.onClose=^{MediaBrowserViewController *browser=weakSelf;if(browser&&[browser.source[@"id"] isEqual:sourceID])[browser refreshCurrentSource];};
        UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];navigation.modalInPresentation=YES;HostStyleNavigation(navigation);[owner presentViewController:navigation animated:YES completion:nil];
    }];
}
- (void)chooseProvider {
    if(!self.source){[self openResources];return;}if(!self.providers.count){[self showMessage:@"当前影视资源没有公开多个站点，或尚未加载站点列表" loading:NO];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *provider in self.providers){BOOL current=[provider[@"id"] isEqual:self.provider];[choices addObject:@{@"name":provider[@"name"]?:provider[@"id"]?:@"影视站点",@"subtitle":current?@"当前平台":(self.source[@"name"]?:@"当前影视资源"),@"provider":provider[@"id"]?:@"",@"selected":@(current)}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"切换影视平台";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner||![choice[@"provider"] length]||[owner.provider isEqual:choice[@"provider"]])return;[owner saveCurrentBrowseState];owner.provider=choice[@"provider"];[NSUserDefaults.standardUserDefaults setObject:owner.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",owner.source[@"id"]]];owner.pendingBrowseState=owner.browseStates[[owner stateKeyForSource:owner.source provider:owner.provider]];[owner updateSelectionControls];[owner loadHome];};[self presentPicker:picker];
}
- (void)chooseFilters {
    if([self.source[@"protocol"] isEqual:@"widget-extractor"]){[self chooseWidgetEpisode];return;}
    NSArray *groups=[self.filters[self.category?:@""] isKindOfClass:NSArray.class]?self.filters[self.category?:@""]:@[];
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=self.selectedFilters.count?[NSString stringWithFormat:@"分类筛选 · 已选 %lu 项",(unsigned long)self.selectedFilters.count]:@"分类筛选";NSMutableArray *choices=[NSMutableArray array];
    if(self.selectedFilters.count)[choices addObject:@{@"name":@"清除当前筛选",@"subtitle":@"移除已选条件并重新加载分类",@"clearFilters":@YES}];
    for(id raw in groups){if(![raw isKindOfClass:NSDictionary.class])continue;NSDictionary *group=raw;NSString *key=group[@"key"];if(![key isKindOfClass:NSString.class])continue;
        for(id rawOption in [group[@"value"] isKindOfClass:NSArray.class]?group[@"value"]:@[]){if(![rawOption isKindOfClass:NSDictionary.class])continue;NSDictionary *option=rawOption;if(![option[@"v"] isKindOfClass:NSString.class] && ![option[@"v"] isKindOfClass:NSNumber.class])continue;[choices addObject:@{@"name":[NSString stringWithFormat:@"%@ · %@",group[@"name"]?:key,option[@"n"]?:option[@"v"]],@"subtitle":[self.selectedFilters[key] isEqual:option[@"v"]]?@"已选":@"",@"key":key,@"value":option[@"v"]}];}}
    if(!choices.count){[self showMessage:@"当前分类没有筛选条件，请先选择分类" loading:NO];return;}
    picker.choices=choices;__weak typeof(self) weakSelf=self;picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner)return;if([choice[@"clearFilters"] boolValue])[owner.selectedFilters removeAllObjects];else{if(!owner.selectedFilters)owner.selectedFilters=[NSMutableDictionary dictionary];owner.selectedFilters[choice[@"key"]]=choice[@"value"];}owner.page=1;if(!owner.loading)[owner loadListing:NO];};[self presentPicker:picker];
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
    self.homeMode=NO;self.modeControl.selectedSegmentIndex=1;self.title=@"影视库";self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;[self setBrowseControlsHidden:NO];
    self.sourceInvalidated=NO;self.capabilityReadinessRetryCount=0;[self saveCurrentBrowseState];self.generation++;NSUInteger generation=self.generation;self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.source=source;NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",source[@"id"]]];self.provider=nil;self.pendingBrowseState=self.browseStates[[self stateKeyForSource:source provider:preferredProvider]]?:self.browseStates[[self stateKeyForSource:source provider:nil]];self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.page=1;self.loading=YES;self.moreButton.hidden=YES;[self.grid reloadData];
    [self updateSelectionControls];
    self.widgetSeason=1;self.widgetEpisode=1;BOOL widget=[source[@"protocol"] isEqual:@"widget-extractor"];self.navigationItem.prompt=widget?@"第 1 季 · 第 1 集 · 工具栏筛选可修改":nil;self.search.searchBar.placeholder=widget?@"输入完整剧名，筛选中选择季 / 集":@"搜索当前影视来源";
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    [NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];
    if(MediaSourceUsesNativeCatalogAPI(source)){
        self.client=[[MediaAPIClient alloc] initWithTVBoxSource:source];NSMutableDictionary *saved=[source mutableCopy];saved[@"capabilities"]=@[@"home",@"category",@"search",@"detail",@"play"];self.source=saved;self.provider=@"";self.providers=@[];self.readinessStageLabel.text=[source[@"protocol"] isEqual:@"maccms-api"]?@"MacCMS JSON/XML API · 按需连接，不启动插件运行时":@"TVBox JSON API · 不启动插件运行时";self.loading=NO;[self updateSelectionControls];[self loadHome];NSDictionary *resume=self.pendingHistoryEntry;if(resume&&[resume[@"sourceID"] isEqual:self.source[@"id"]]){self.pendingHistoryEntry=nil;[self openHistoryDetail:resume source:self.source provider:@""];}return;
    }
    self.readinessStageLabel.text=@"准备启动已选资源";[self showMessage:[NSString stringWithFormat:@"正在启动 %@…",source[@"name"]] loading:YES];
    self.client=[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue]];__weak typeof(self) weakSelf=self;
    void (^started)(NSError *)=^(NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner || owner.generation!=generation)return;
        if(error){owner.readinessStageLabel.text=@"启动失败 · HTTP 健康状态未知";[RuntimeDiagnostics.shared recordEvent:@"media_source_activation_failed" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"port":owner.source[@"port"]?:@0, @"engine":owner.source[@"engine"]?:@"unknown", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];return;}
        owner.readinessStageLabel.text=@"启动请求已接受 · 等待 HTTP 健康检查";[RuntimeDiagnostics.shared recordEvent:@"media_runtime_start_request_accepted" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown"}];
        NSURL *health=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",source[@"port"]]];
        owner.readiness=[[LocalServiceReadiness alloc] initWithURL:health timeout:25 requiresHealthJSON:YES];
        NSError *(^startupProvider)(NSDictionary *)=[owner.startupErrorForService copy];
        owner.readiness.failureProvider=startupProvider?^NSError *{return startupProvider(source);}:owner.startupErrorProvider;
        [owner.readiness start:^(NSError *failure,NSTimeInterval elapsed){
            MediaBrowserViewController *page=weakSelf;if(!page || page.generation!=generation)return;
            NSMutableDictionary *probeFields=[@{@"correlation_id":page.diagnosticTraceID?:@"", @"port":page.source[@"port"]?:@0, @"engine":page.source[@"engine"]?:@"unknown", @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:page.readiness.diagnosticSummary];
            if(failure){page.readinessStageLabel.text=@"HTTP 健康检查失败 · 内容接口未读取";probeFields[@"error_domain"]=failure.domain?:@"";probeFields[@"error_code"]=@(failure.code);probeFields[@"error_message"]=failure.localizedDescription?:@"";[RuntimeDiagnostics.shared recordEvent:@"media_service_health_failed" category:@"service" fields:probeFields];page.loading=NO;[page showMessage:failure.localizedDescription loading:NO];return;}
            [RuntimeDiagnostics.shared recordEvent:@"media_service_health_ready" category:@"service" fields:probeFields];
            page.readinessStageLabel.text=@"HTTP 健康检查通过 · 正在读取资源能力";
            [page loadCapabilities];
        }];
    };
    if(self.onActivateService)self.onActivateService(source,started);else started(nil);
}
- (NSDictionary *)arguments:(NSDictionary *)args {NSMutableDictionary *value=[args mutableCopy];if(self.provider.length)value[@"provider"]=self.provider;return value;}
- (void)loadCapabilities {
    self.readinessStageLabel.text=@"HTTP 健康通过 · 查询资源声明的接口能力";
    __weak typeof(self) weakSelf=self;
    [self.client call:@"capabilities" arguments:@{} correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;
        if(error){
            BOOL retryable=[error.userInfo[@"plugin_retryable"] boolValue];
            if(retryable&&owner.capabilityReadinessRetryCount<45){
                owner.capabilityReadinessRetryCount++;
                NSUInteger retry=owner.capabilityReadinessRetryCount,generation=owner.generation;
                owner.readinessStageLabel.text=[NSString stringWithFormat:@"本机接口已监听 · 资源脚本正在准备（%lu/45）",(unsigned long)retry];
                if(retry==1||retry%10==0)[RuntimeDiagnostics.shared recordEvent:@"media_runtime_preparing" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown",@"port":owner.source[@"port"]?:@0,@"retry_count":@(retry),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
                NSTimeInterval delay=retry<2?0.5:(retry<5?1.0:2.0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{MediaBrowserViewController *page=weakSelf;if(!page||page.generation!=generation||page.sourceInvalidated)return;[page loadCapabilities];});
                return;
            }
            if(retryable)[RuntimeDiagnostics.shared recordEvent:@"media_runtime_prepare_timeout" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown",@"port":owner.source[@"port"]?:@0,@"retry_count":@(owner.capabilityReadinessRetryCount),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];
            owner.readinessStageLabel.text=retryable?@"资源脚本准备超时 · 重新选择来源可重试":@"资源能力接口读取失败";owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];return;
        }
        owner.capabilityReadinessRetryCount=0;
        NSArray *caps=[result isKindOfClass:NSDictionary.class] && [result[@"capabilities"] isKindOfClass:NSArray.class]?result[@"capabilities"]:@[];
        [RuntimeDiagnostics.shared recordEvent:@"media_capabilities_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"capability_count":@(caps.count)}];
        NSMutableDictionary *saved=[owner.source mutableCopy];saved[@"capabilities"]=caps;[ServiceStore save:saved];owner.source=saved;
        if(owner.openConfigurationWhenReady){owner.openConfigurationWhenReady=NO;[owner openSourceConfiguration];}
        if([caps containsObject:@"live"] && ![caps containsObject:@"detail"] && ![caps containsObject:@"play"]){owner.loading=NO;if(owner.onSubscribeLive)owner.onSubscribeLive(owner.source);else[owner showMessage:@"此资源提供直播频道，可添加到频道订阅" loading:NO];return;}
        if([caps containsObject:@"providers"]){[owner.client call:@"providers" arguments:@{} correlationID:owner.diagnosticTraceID completion:^(id providers,NSError *failure){MediaBrowserViewController *page=weakSelf;if(!page)return;if(failure){page.loading=NO;[page showMessage:[NSString stringWithFormat:@"站点列表加载失败：%@",failure.localizedDescription] loading:NO];[page updateSelectionControls];return;}page.providers=[providers isKindOfClass:NSArray.class]?providers:@[];if(!page.providers.count){page.loading=NO;[page showMessage:@"资源已启动，但没有可用影视站点。请打开“源配置与账号”检查配置，再刷新。" loading:NO];[page updateSelectionControls];return;}NSDictionary *resume=page.pendingHistoryEntry;BOOL openingHistory=resume&&[resume[@"sourceID"] isEqual:page.source[@"id"]];NSString *savedProvider=page.pendingBrowseState[@"provider"];NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",page.source[@"id"]]];NSString *chosen=openingHistory?resume[@"provider"]:(savedProvider.length?savedProvider:preferredProvider);BOOL found=NO;for(NSDictionary *candidate in page.providers)if([candidate[@"id"] isEqual:chosen]){found=YES;break;}if(chosen.length&&!found){page.provider=nil;page.loading=NO;[page updateSelectionControls];page.pendingHistoryEntry=nil;[page showMessage:openingHistory?@"这条记录对应的站点已从资源中移除。请选择其他站点重新查找影片。":@"之前选择的站点已失效，请点按顶部站点按钮重新选择" loading:NO];return;}page.provider=found?chosen:page.providers.firstObject[@"id"];if(page.provider)[NSUserDefaults.standardUserDefaults setObject:page.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",page.source[@"id"]]];if(page.pendingBrowseState.count){NSMutableDictionary *state=[page.pendingBrowseState mutableCopy];state[@"provider"]=page.provider?:@"";page.pendingBrowseState=state;}[page updateSelectionControls];[page loadHome];if(openingHistory){page.pendingHistoryEntry=nil;[page openHistoryDetail:resume source:page.source provider:page.provider?:@""];}}];}
        else if([caps containsObject:@"home"]){owner.provider=@"";[owner loadHome];NSDictionary *resume=owner.pendingHistoryEntry;if(resume&&[resume[@"sourceID"] isEqual:owner.source[@"id"]]){owner.pendingHistoryEntry=nil;[owner openHistoryDetail:resume source:owner.source provider:@""];}}
        else{owner.loading=NO;if(owner.pendingBrowseState){NSDictionary *pending=owner.pendingBrowseState;[owner restorePendingBrowseState];if(![pending[@"keyword"] length])[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];}else[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];}
    }];
}
- (void)loadHome {
    NSUInteger generation=++self.generation;
    NSDictionary *requestedSource=[self.source copy]?:@{};
    NSString *requestedSourceID=[requestedSource[@"id"] isKindOfClass:NSString.class]?requestedSource[@"id"]:@"";
    NSString *requestedProvider=[self.provider isKindOfClass:NSString.class]?self.provider:@"";
    self.filters=@{};self.selectedFilters=[NSMutableDictionary dictionary];
    BOOL hasProviderDirectory=[self.source[@"capabilities"] containsObject:@"providers"];
    self.readinessStageLabel.text=hasProviderDirectory?@"站点目录已读取 · 正在加载影视内容":@"资源能力已读取 · 正在加载影视内容";
    if(hasProviderDirectory)[RuntimeDiagnostics.shared recordEvent:@"media_provider_list_readable" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.source[@"id"]?:@"",@"provider_count":@(self.providers.count)}];
    self.loading=YES;[self updateSelectionControls];self.keyword=@"";self.category=nil;self.page=1;self.hasMore=NO;self.moreButton.hidden=YES;self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载推荐与分类…" loading:YES];
    NSDictionary *requestArguments=[self arguments:@{}];BOOL cacheStale=NO;id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:requestArguments maximumAge:6*3600 isStale:&cacheStale];CFTimeInterval requestStartedAt=CACurrentMediaTime();
    if([cached isKindOfClass:NSDictionary.class]){[self applyHomeResult:cached];if(self.homeMode){[self refreshHomeModules];[self showMessage:@"" loading:NO];}else[self showMessage:cacheStale?@"正在更新 · 暂用缓存推荐":@"正在校验 · 显示上次推荐" loading:YES];}
    __weak typeof(self) weakSelf=self;
    [self.client call:@"home" arguments:requestArguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner||owner.generation!=generation||![owner.source[@"id"] isEqual:requestedSourceID]||![(owner.provider?:@"") isEqual:requestedProvider])return;owner.loading=NO;[owner updateSelectionControls];[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil elapsed:MAX(0,CACurrentMediaTime()-requestStartedAt)];
        if(error){owner.readinessStageLabel.text=owner.items.count?@"内容接口失败 · 当前仍显示有界缓存":@"内容接口读取失败";[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存内容 · 更新失败：%@",error.localizedDescription]:error.localizedDescription loading:NO];return;}
        if(owner.keyword.length || owner.category.length){owner.page=1;[owner loadListing:NO];return;}
        [[MediaMetadataCache shared] storeResult:result forSource:owner.source operation:@"home" arguments:requestArguments];
        [owner applyHomeResult:result];
        if(owner.homeMode)[owner refreshHomeModules];
        owner.readinessStageLabel.text=@"影视内容接口已读取 · 实际播放需以视频首帧确认";
        [RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(owner.items.count),@"operation":@"home"}];
        if(owner.pendingBrowseState){[owner restorePendingBrowseState];return;}
        [owner showMessage:owner.items.count?@"":@"选择分类或输入关键词搜索" loading:NO];
    }];
}
- (void)applyHomeResult:(NSDictionary *)result {
    self.items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];[self.grid reloadData];
    self.filters=[result[@"filters"] isKindOfClass:NSDictionary.class]?result[@"filters"]:@{};
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSDictionary *category in [result[@"categories"] isKindOfClass:NSArray.class]?result[@"categories"]:@[]){if(![category isKindOfClass:NSDictionary.class])continue;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:category[@"name"] forState:UIControlStateNormal];HostStylePillButton(button,NO);button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];button.accessibilityIdentifier=category[@"id"];[button addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[self.categories addArrangedSubview:button];}
}
- (void)selectCategory:(UIButton *)button {self.category=button.accessibilityIdentifier;self.selectedFilters=[NSMutableDictionary dictionary];self.keyword=@"";self.search.searchBar.text=@"";for(UIButton *item in self.categories.arrangedSubviews){BOOL selected=item==button;item.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:HostNeutralSurface();HostSetLayerBorderColor(item,selected?[HostAccent() colorWithAlphaComponent:0.42]:HostBorder());[item setTitleColor:selected?HostAccent():HostText() forState:UIControlStateNormal];}self.page=1;if(!self.loading)[self loadListing:NO];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *keyword=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.keyword=keyword;
    NSUInteger generation=++self.searchGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner || owner.searchGeneration!=generation || !owner.source || owner.loading)return;owner.page=1;if(keyword.length)[owner loadListing:NO];else if(!owner.category.length)[owner loadHome];});
}
- (void)loadMore {if(!self.loading && self.hasMore){self.page++;[self loadListing:YES];}}
- (void)loadListing:(BOOL)append {
    if(!self.source)return;if(!self.keyword.length && !self.category.length){[self loadHome];return;}NSUInteger generation=self.generation;NSString *requestedSourceID=[[self.source[@"id"] description] copy]?:@"";NSString *requestedProvider=[self.provider copy]?:@"";self.loading=YES;[self updateSelectionControls];NSString *operation=self.keyword.length?@"search":@"category";NSString *requestedKeyword=self.keyword?:@"",*requestedCategory=self.category?:@"";
    self.readinessStageLabel.text=self.keyword.length?@"资源运行中 · 正在搜索影视内容":@"资源运行中 · 正在加载分类内容";
    NSInteger requestedPage=self.page;
    NSMutableDictionary *args=[[self arguments:@{@"page":@(self.page)}] mutableCopy];if(self.keyword.length)args[@"keyword"]=self.keyword;else args[@"categoryId"]=self.category?:@"";
    NSInteger episode=self.widgetEpisode,season=self.widgetSeason;if([self.source[@"protocol"] isEqual:@"widget-extractor"]){args[@"episode"]=@(MAX(1,episode));args[@"season"]=@(MAX(1,season));}
    args[@"filters"]=self.selectedFilters?:@{};NSDictionary *requestedFilters=[self.selectedFilters copy]?:@{};
    BOOL hadCachedResult=NO;
    if(!append){BOOL cacheStale=NO;id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:operation arguments:args maximumAge:6*3600 isStale:&cacheStale];if([cached isKindOfClass:NSDictionary.class]){hadCachedResult=YES;self.items=[cached[@"items"] isKindOfClass:NSArray.class]?cached[@"items"]:@[];self.hasMore=[cached[@"hasMore"] boolValue];self.moreButton.hidden=!self.hasMore;[self.grid reloadData];[self showMessage:cacheStale?@"正在更新 · 暂用缓存结果":@"正在校验 · 显示上次结果" loading:YES];}}
    if(!append&&!hadCachedResult){self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载…" loading:YES];}self.moreButton.enabled=NO;
    CFTimeInterval requestStartedAt=CACurrentMediaTime();__weak typeof(self) weakSelf=self;
    [self.client call:operation arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner||owner.generation!=generation||![[owner.source[@"id"] description] isEqual:requestedSourceID]||![(owner.provider?:@"") isEqual:requestedProvider])return;owner.loading=NO;[owner updateSelectionControls];owner.moreButton.enabled=YES;[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil elapsed:MAX(0,CACurrentMediaTime()-requestStartedAt)];
        if(episode!=owner.widgetEpisode || season!=owner.widgetSeason || ![requestedKeyword isEqualToString:owner.keyword?:@""] || (!requestedKeyword.length && (![requestedCategory isEqualToString:owner.category?:@""] || ![requestedFilters isEqual:owner.selectedFilters?:@{}]))){owner.page=1;[owner loadListing:NO];return;}
        if(error){owner.readinessStageLabel.text=owner.items.count?@"搜索接口失败 · 当前仍显示有界缓存":@"影视内容接口读取失败";if(append)owner.page=MAX(1,owner.page-1);[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存结果 · 更新失败：%@",error.localizedDescription]:error.localizedDescription loading:NO];return;}
        if(!append)[[MediaMetadataCache shared] storeResult:result forSource:owner.source operation:operation arguments:args];
        NSArray *incoming=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];
        NSMutableArray *all=append?[owner.items mutableCopy]:[NSMutableArray array];NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *item in all)[ids addObject:item[@"id"]];for(NSDictionary *item in incoming)if(![ids containsObject:item[@"id"]]){[all addObject:item];[ids addObject:item[@"id"]];}
        owner.items=all;owner.readinessStageLabel.text=@"影视内容接口已读取 · 实际播放需以视频首帧确认";[RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(all.count),@"operation":operation}];if(owner.pendingRestorePage>requestedPage && [result[@"hasMore"] boolValue] && incoming.count && requestedPage<owner.pendingRestorePage){owner.page=requestedPage+1;[owner loadListing:YES];return;}if(owner.pendingRestorePage){owner.page=requestedPage;owner.pendingRestorePage=0;}owner.hasMore=[result[@"hasMore"] boolValue];owner.moreButton.hidden=!owner.hasMore;[owner.grid reloadData];[owner showMessage:all.count?@"":@"没有找到影片，请更换关键词或分类" loading:NO];
        if(owner.pendingRestoreOffset){CGFloat offset=owner.pendingRestoreOffset.doubleValue;owner.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[owner.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
    }];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.items.count;}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {NSInteger columns=collectionView.bounds.size.width>700?4:2;CGFloat width=floor((collectionView.bounds.size.width-28-(columns-1)*10)/columns);UIFont *name=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection],*remarks=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11] compatibleWithTraitCollection:self.traitCollection];return CGSizeMake(width,width*1.4+10+ceil(name.lineHeight)+ceil(remarks.lineHeight));}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    MediaPosterCell *cell=(MediaPosterCell *)[collectionView dequeueReusableCellWithReuseIdentifier:@"movie" forIndexPath:ip];
    [cell configureWithItem:self.items[ip.item]];
    return cell;
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    HostAnimateSelection([collectionView cellForItemAtIndexPath:ip]);
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=self.items[ip.item];detail.source=self.source;detail.provider=self.provider;detail.onPlay=self.onPlay;[self.navigationController pushViewController:detail animated:YES];
}
@end
