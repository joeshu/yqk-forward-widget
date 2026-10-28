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
#import <QuartzCore/QuartzCore.h>

@interface MediaHomePosterFade : UIView
@end
@implementation MediaHomePosterFade
+ (Class)layerClass {return CAGradientLayer.class;}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CAGradientLayer *fade=(CAGradientLayer *)self.layer;
    UIColor *base=[HostBackground() resolvedColorWithTraitCollection:self.traitCollection];
    fade.colors=@[(__bridge id)[base colorWithAlphaComponent:0].CGColor,(__bridge id)[base colorWithAlphaComponent:0.94].CGColor,(__bridge id)base.CGColor];
    fade.locations=@[@0,@0.32,@1];
    [CATransaction commit];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {[super traitCollectionDidChange:previous];[self setNeedsLayout];}
@end

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
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchResultsUpdater=self;self.search.searchBar.placeholder=([self.title containsString:@"平台"]||[self.title containsString:@"站点"])?@"搜索当前资源的站点":([self.title containsString:@"资源"]?@"搜索已导入资源":@"搜索选项");self.search.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
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
- (void)selectScope:(UIButton *)sender {self.selectedScope=sender.accessibilityIdentifier?:@"*";for(UIButton *button in self.scopeStack.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.selectedScope];HostStylePillButton(button,selected);}[self updateSearchResultsForSearchController:self.search];}
- (void)closePicker { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.shown.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"source"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];NSDictionary *choice=self.shown[index.row];cell.backgroundColor=HostCard();cell.textLabel.text=choice[@"name"];cell.textLabel.textColor=UIColor.labelColor;cell.textLabel.numberOfLines=0;NSMutableArray *details=[NSMutableArray array];if([choice[@"subtitle"] length])[details addObject:choice[@"subtitle"]];if([choice[@"url"] length])[details addObject:choice[@"url"]];cell.detailTextLabel.text=[details componentsJoinedByString:@"\n"];cell.detailTextLabel.textColor=UIColor.secondaryLabelColor;cell.detailTextLabel.numberOfLines=0;BOOL selected=[choice[@"selected"] boolValue];cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {NSString *query=controller.searchBar.text?:@"";self.shown=[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){NSString *scope=[choice[@"scope"] isKindOfClass:NSString.class]?choice[@"scope"]:@"";if(![self.selectedScope isEqual:@"*"]&&![scope isEqual:self.selectedScope])return NO;BOOL matches=![query length];for(NSString *key in @[@"name",@"subtitle",@"url"]){NSString *value=[choice[key] isKindOfClass:NSString.class]?choice[key]:@"";if(query.length&&[value rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)matches=YES;}return matches;}]];if(!self.shown.count){UILabel *empty=[UILabel new];empty.text=query.length?@"没有匹配的选项，请修改或清除搜索词":@"当前分组暂无选项，请切换到全部";empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];empty.adjustsFontForContentSizeCategory=YES;empty.textColor=HostSecondaryText();empty.accessibilityIdentifier=@"media-picker-empty";self.tableView.backgroundView=empty;}else self.tableView.backgroundView=nil;[self.tableView reloadData];}
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
@property(nonatomic,copy) dispatch_block_t onReturnHome;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIImageView *posterView;
@property(nonatomic,strong) UILabel *heroTitle;
@property(nonatomic,strong) UILabel *heroMetadata;
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
@property(nonatomic,strong) UILabel *castTitle;
@property(nonatomic,strong) UIScrollView *castScroll;
@property(nonatomic,strong) UIStackView *castStack;
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
- (void)shareTitle;
- (void)copyTitle;
- (void)scrollToEpisodes;
@end
@implementation MediaDetailViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithNibName:nil bundle:nil];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"";self.view.backgroundColor=HostBackground();self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.selectedLineIndex=0;self.selectedEpisodeIndex=0;self.episodePage=0;self.episodeButtons=[NSMutableArray array];self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];back.frame=CGRectMake(0,0,44,44);[back setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];back.tintColor=HostText();HostStyleGlassCard(back,14);HostInstallPressFeedback(back);back.accessibilityLabel=@"返回";back.accessibilityIdentifier=@"media-detail-back";[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:back];
    __weak typeof(self) weakSelf=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"ellipsis",@"title":@"更多影片操作",@"menu":[UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"返回影视首页" image:[UIImage systemImageNamed:@"house"] identifier:nil handler:^(UIAction *action){if(weakSelf.onReturnHome)weakSelf.onReturnHome();}],[UIAction actionWithTitle:@"重新加载详情" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action){[weakSelf loadDetail];}],[UIAction actionWithTitle:@"复制片名" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action){[weakSelf copyTitle];}],[UIAction actionWithTitle:@"分享影片信息" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action){[weakSelf shareTitle];}]]]}])];
    self.client=MediaSourceUsesNativeCatalogAPI(self.source)?[[MediaAPIClient alloc] initWithTVBoxSource:self.source]:[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];[self buildDetailLayout];[self loadDetail];
}
- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label=[UILabel new];label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];label.adjustsFontForContentSizeCategory=YES;label.textColor=HostText();label.text=text;return label;
}
- (UIButton *)actionButton:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;
    button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;
    HostStyleGlassCard(button,16);HostInstallPressFeedback(button);[button setTitleColor:HostText() forState:UIControlStateNormal];button.layer.cornerCurve=kCACornerCurveContinuous;
    button.layer.borderWidth=0.6;HostSetLayerBorderColor(button,HostBorder());button.contentEdgeInsets=UIEdgeInsetsMake(13,16,13,16);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[button setTitle:title forState:UIControlStateNormal];return button;
}
- (UIButton *)detailIconButton:(NSString *)symbol label:(NSString *)label identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;button.accessibilityLabel=label;button.accessibilityTraits|=UIAccessibilityTraitButton;
    HostStyleGlassCard(button,22);HostInstallPressFeedback(button);button.layer.borderWidth=0.6;HostSetLayerBorderColor(button,HostBorder());[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostAccent();
    [button.widthAnchor constraintEqualToConstant:46].active=YES;[button.heightAnchor constraintEqualToConstant:46].active=YES;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)buildDetailLayout {
    self.scrollView=[UIScrollView new];self.scrollView.translatesAutoresizingMaskIntoConstraints=NO;self.scrollView.alwaysBounceVertical=YES;self.scrollView.accessibilityIdentifier=@"media-detail-scroll";[self.view addSubview:self.scrollView];
    self.contentStack=[UIStackView new];self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=13;
    self.contentStack.layoutMargins=UIEdgeInsetsMake(4,14,24,14);self.contentStack.layoutMarginsRelativeArrangement=YES;[self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[[self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],[self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor]]];
    self.status=[UILabel new];self.status.textColor=HostSecondaryText();self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.status.adjustsFontForContentSizeCategory=YES;
    self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.hidden=YES;[self.contentStack addArrangedSubview:self.status];
    UIView *hero=[UIView new];hero.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(hero,24);hero.clipsToBounds=YES;hero.accessibilityIdentifier=@"media-detail-backdrop";
    self.posterView=[UIImageView new];self.posterView.translatesAutoresizingMaskIntoConstraints=NO;self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;[hero addSubview:self.posterView];
    UIVisualEffectView *blur=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];blur.translatesAutoresizingMaskIntoConstraints=NO;blur.userInteractionEnabled=NO;[hero addSubview:blur];
    UIView *shade=[UIView new];shade.translatesAutoresizingMaskIntoConstraints=NO;shade.backgroundColor=[UIColor colorWithWhite:0 alpha:0.12];[hero addSubview:shade];
    self.heroTitle=[UILabel new];self.heroTitle.translatesAutoresizingMaskIntoConstraints=NO;self.heroTitle.font=[UIFont systemFontOfSize:27 weight:UIFontWeightBold];self.heroTitle.adjustsFontForContentSizeCategory=YES;self.heroTitle.textColor=HostText();self.heroTitle.textAlignment=NSTextAlignmentCenter;self.heroTitle.numberOfLines=2;
    self.heroMetadata=[UILabel new];self.heroMetadata.translatesAutoresizingMaskIntoConstraints=NO;self.heroMetadata.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.heroMetadata.adjustsFontForContentSizeCategory=YES;self.heroMetadata.textColor=HostSecondaryText();self.heroMetadata.textAlignment=NSTextAlignmentCenter;self.heroMetadata.numberOfLines=2;
    [hero addSubview:self.heroTitle];[hero addSubview:self.heroMetadata];[self.contentStack addArrangedSubview:hero];
    [NSLayoutConstraint activateConstraints:@[[hero.heightAnchor constraintEqualToAnchor:hero.widthAnchor multiplier:0.94],
        [self.posterView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.posterView.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.posterView.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.posterView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[blur.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[blur.topAnchor constraintEqualToAnchor:hero.topAnchor],[blur.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [shade.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[shade.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[shade.topAnchor constraintEqualToAnchor:hero.topAnchor],[shade.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [self.heroTitle.leadingAnchor constraintGreaterThanOrEqualToAnchor:hero.leadingAnchor constant:20],[self.heroTitle.trailingAnchor constraintLessThanOrEqualToAnchor:hero.trailingAnchor constant:-20],
        [self.heroTitle.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],[self.heroTitle.centerYAnchor constraintEqualToAnchor:hero.centerYAnchor constant:-10],
        [self.heroMetadata.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:20],[self.heroMetadata.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-20],
        [self.heroMetadata.topAnchor constraintEqualToAnchor:self.heroTitle.bottomAnchor constant:6]]];
    self.metadataLabel=[UILabel new];self.metadataLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.metadataLabel.adjustsFontForContentSizeCategory=YES;self.metadataLabel.textColor=HostSecondaryText();self.metadataLabel.numberOfLines=0;[self.contentStack addArrangedSubview:self.metadataLabel];
    self.descriptionLabel=[UILabel new];self.descriptionLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.descriptionLabel.adjustsFontForContentSizeCategory=YES;self.descriptionLabel.textColor=HostSecondaryText();self.descriptionLabel.numberOfLines=5;[self.contentStack addArrangedSubview:self.descriptionLabel];
    self.descriptionToggle=[UIButton buttonWithType:UIButtonTypeSystem];self.descriptionToggle.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;[self.descriptionToggle setTitle:@"展开简介" forState:UIControlStateNormal];[self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];self.descriptionToggle.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];[self.descriptionToggle addTarget:self action:@selector(toggleDescription) forControlEvents:UIControlEventTouchUpInside];self.descriptionToggle.hidden=YES;[self.contentStack addArrangedSubview:self.descriptionToggle];
    self.playButton=[self actionButton:@"▶︎  播放" identifier:@"media-detail-play" action:@selector(playCurrentEpisode)];[self.contentStack addArrangedSubview:self.playButton];[self.playButton.heightAnchor constraintGreaterThanOrEqualToConstant:52].active=YES;
    UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisHorizontal;actions.alignment=UIStackViewAlignmentCenter;actions.distribution=UIStackViewDistributionEqualSpacing;actions.layoutMargins=UIEdgeInsetsMake(2,18,2,18);actions.layoutMarginsRelativeArrangement=YES;
    UIButton *copyButton=[self detailIconButton:@"doc.on.doc" label:@"复制片名" identifier:@"media-detail-copy-title" action:@selector(copyTitle)];UIButton *shareButton=[self detailIconButton:@"square.and.arrow.up" label:@"分享影片信息" identifier:@"media-detail-share" action:@selector(shareTitle)];self.favoriteButton=[self detailIconButton:@"heart" label:@"收藏影片" identifier:@"media-detail-favorite" action:@selector(toggleFavorite)];UIButton *episodesButton=[self detailIconButton:@"list.number" label:@"查看选集" identifier:@"media-detail-jump-episodes" action:@selector(scrollToEpisodes)];
    [actions addArrangedSubview:copyButton];[actions addArrangedSubview:shareButton];[actions addArrangedSubview:self.favoriteButton];[actions addArrangedSubview:episodesButton];[self.contentStack addArrangedSubview:actions];
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
    self.castTitle=[self sectionLabel:@"演职阵容"];[self.contentStack addArrangedSubview:self.castTitle];self.castScroll=[UIScrollView new];self.castScroll.translatesAutoresizingMaskIntoConstraints=NO;self.castScroll.showsHorizontalScrollIndicator=NO;self.castScroll.alwaysBounceHorizontal=YES;[self.contentStack addArrangedSubview:self.castScroll];self.castStack=[UIStackView new];self.castStack.translatesAutoresizingMaskIntoConstraints=NO;self.castStack.axis=UILayoutConstraintAxisHorizontal;self.castStack.alignment=UIStackViewAlignmentTop;self.castStack.spacing=14;[self.castScroll addSubview:self.castStack];
    [NSLayoutConstraint activateConstraints:@[[self.castScroll.heightAnchor constraintEqualToConstant:94],[self.castStack.leadingAnchor constraintEqualToAnchor:self.castScroll.contentLayoutGuide.leadingAnchor],[self.castStack.trailingAnchor constraintEqualToAnchor:self.castScroll.contentLayoutGuide.trailingAnchor],[self.castStack.topAnchor constraintEqualToAnchor:self.castScroll.contentLayoutGuide.topAnchor],[self.castStack.bottomAnchor constraintEqualToAnchor:self.castScroll.contentLayoutGuide.bottomAnchor],[self.castStack.heightAnchor constraintEqualToAnchor:self.castScroll.frameLayoutGuide.heightAnchor]]];self.castTitle.hidden=YES;self.castScroll.hidden=YES;
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.hidesWhenStopped=YES;self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[[self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)dealloc {[self.client cancel];}
- (void)goBack {[self.navigationController popViewControllerAnimated:YES];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController){self.generation++;[self.client cancel];}}
- (void)scrollToEpisodes {CGRect rect=[self.episodeTitle convertRect:self.episodeTitle.bounds toView:self.scrollView];CGFloat y=MAX(-self.scrollView.adjustedContentInset.top,rect.origin.y-12);[self.scrollView setContentOffset:CGPointMake(0,y) animated:YES];}
- (void)copyTitle {NSString *name=[self.detail[@"name"] isKindOfClass:NSString.class]?self.detail[@"name"]:([self.item[@"name"] isKindOfClass:NSString.class]?self.item[@"name"]:@"");if(!name.length)return;UIPasteboard.generalPasteboard.string=name;self.status.text=@"片名已复制";self.status.hidden=NO;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if([self.status.text isEqualToString:@"片名已复制"])self.status.hidden=YES;});}
- (void)shareTitle {NSString *name=[self.detail[@"name"] isKindOfClass:NSString.class]?self.detail[@"name"]:([self.item[@"name"] isKindOfClass:NSString.class]?self.item[@"name"]:@"影片");NSMutableArray *parts=[NSMutableArray arrayWithObject:name];NSString *metadata=[self metadataSummary];if(metadata.length)[parts addObject:metadata];NSString *text=[parts componentsJoinedByString:@" · "];UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];UIPopoverPresentationController *popover=share.popoverPresentationController;if(popover){popover.sourceView=self.view;popover.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);} [self presentViewController:share animated:YES completion:nil];}
- (void)refreshCastRow {
    for(UIView *view in self.castStack.arrangedSubviews.copy){[self.castStack removeArrangedSubview:view];[view removeFromSuperview];}
    NSString *raw=[self.detail[@"actor"] isKindOfClass:NSString.class]?self.detail[@"actor"]:@"";NSCharacterSet *separators=[NSCharacterSet characterSetWithCharactersInString:@"/／,，、;；|\n\r#"];NSMutableOrderedSet<NSString *> *names=[NSMutableOrderedSet orderedSet];for(NSString *part in [raw componentsSeparatedByCharactersInSet:separators]){NSString *name=[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(name.length&&name.length<=64)[names addObject:name];if(names.count>=12)break;}
    self.castTitle.hidden=names.count==0;self.castScroll.hidden=names.count==0;
    for(NSString *name in names){UIView *entry=[UIView new];entry.translatesAutoresizingMaskIntoConstraints=NO;entry.accessibilityLabel=name;entry.isAccessibilityElement=YES;UIImageView *avatar=[UIImageView new];avatar.translatesAutoresizingMaskIntoConstraints=NO;avatar.image=[UIImage systemImageNamed:@"person.crop.circle.fill"];avatar.contentMode=UIViewContentModeScaleAspectFit;avatar.tintColor=HostSecondaryText();avatar.backgroundColor=HostNeutralSurface();avatar.layer.cornerRadius=24;avatar.clipsToBounds=YES;UILabel *label=[UILabel new];label.translatesAutoresizingMaskIntoConstraints=NO;label.text=name;label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];label.adjustsFontForContentSizeCategory=YES;label.textColor=HostSecondaryText();label.textAlignment=NSTextAlignmentCenter;label.numberOfLines=2;label.lineBreakMode=NSLineBreakByTruncatingTail;[entry addSubview:avatar];[entry addSubview:label];[NSLayoutConstraint activateConstraints:@[[entry.widthAnchor constraintEqualToConstant:68],[avatar.widthAnchor constraintEqualToConstant:48],[avatar.heightAnchor constraintEqualToConstant:48],[avatar.centerXAnchor constraintEqualToAnchor:entry.centerXAnchor],[avatar.topAnchor constraintEqualToAnchor:entry.topAnchor],[label.topAnchor constraintEqualToAnchor:avatar.bottomAnchor constant:3],[label.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor],[label.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor],[label.bottomAnchor constraintLessThanOrEqualToAnchor:entry.bottomAnchor]]];[self.castStack addArrangedSubview:entry];}
}
- (void)loadDetail {
    NSUInteger generation=++self.generation;
    [self.client cancel];
    self.status.text=@"正在加载影片详情…";
    self.status.hidden=NO;
    [self.spinner startAnimating];
    NSMutableDictionary *args=[@{@"id":self.item[@"id"]?:@""} mutableCopy];
    if(self.provider.length)args[@"provider"]=self.provider;
    BOOL hadCachedDetail=[self.detail isKindOfClass:NSDictionary.class];
    CFTimeInterval startedAt=CACurrentMediaTime();
    [RuntimeDiagnostics.shared recordEvent:@"media_detail_request_started" category:@"media_api" fields:@{
        @"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"",
        @"provider_id":self.provider?:@"", @"request_generation":@(generation),
        @"has_cached_detail":@(hadCachedDetail), @"cached_line_count":@(self.lines.count)
    }];
    __weak typeof(self) weakSelf=self;
    [self.client call:@"detail" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaDetailViewController *owner=weakSelf;
        if(!owner)return;
        if(owner.generation!=generation){
            [RuntimeDiagnostics.shared recordEvent:@"media_detail_response_discarded" category:@"media_api" fields:@{
                @"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"",
                @"request_generation":@(generation), @"current_generation":@(owner.generation), @"reason":@"superseded_generation"
            }];
            return;
        }
        [owner.spinner stopAnimating];
        NSInteger elapsedMS=(NSInteger)(MAX(0,CACurrentMediaTime()-startedAt)*1000);
        if(error||![result isKindOfClass:NSDictionary.class]){
            [RuntimeDiagnostics.shared recordEvent:@"media_detail_failed" category:@"media_api" fields:@{
                @"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"",
                @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"elapsed_ms":@(elapsedMS),
                @"has_cached_detail":@(hadCachedDetail), @"error_domain":error.domain?:@"",
                @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"invalid_response_shape"
            }];
            if(owner.detail){owner.status.text=[NSString stringWithFormat:@"刷新失败 · 保留当前详情：%@",error.localizedDescription?:@"来源未返回详情"];owner.status.hidden=NO;}
            else{owner.status.text=[NSString stringWithFormat:@"影片详情加载失败\n%@",error.localizedDescription?:@"来源没有提供影片详情"];owner.status.hidden=NO;}
            return;
        }
        owner.detail=result;
        NSUInteger episodeCount=0;
        for(id line in owner.lines){if([line isKindOfClass:NSDictionary.class]&&[line[@"episodes"] isKindOfClass:NSArray.class])episodeCount+=[line[@"episodes"] count];}
        [RuntimeDiagnostics.shared recordEvent:@"media_detail_readable" category:@"media_api" fields:@{
            @"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"",
            @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"elapsed_ms":@(elapsedMS),
            @"line_count":@(owner.lines.count), @"episode_count":@(episodeCount),
            @"has_description":@([owner.detail[@"description"] isKindOfClass:NSString.class]&&[owner.detail[@"description"] length]>0),
            @"has_poster":@(([owner.detail[@"banner"] isKindOfClass:NSString.class]&&[owner.detail[@"banner"] length]>0)||([owner.detail[@"poster"] isKindOfClass:NSString.class]&&[owner.detail[@"poster"] length]>0))
        }];
        owner.status.text=@"";
        owner.status.hidden=YES;
        if(!owner.resumeEntry){NSString *sourceID=owner.source[@"id"]?:@"",*itemID=owner.item[@"id"]?[owner.item[@"id"] description]:@"";owner.resumeEntry=[MediaPlaybackStateStore latestHistoryForSourceID:sourceID provider:owner.provider?:@"" itemID:itemID];}
        [owner restoreResumeEntrySelection];
        [owner refreshDetailHeader];
        [owner updateRouteAndEpisodeViews];
        if(!owner.lines.count){
            owner.status.text=@"此来源未返回可播放分集，请更换站点或检查源配置";
            owner.status.hidden=NO;
            [RuntimeDiagnostics.shared recordEvent:@"media_detail_no_episodes" category:@"media_api" fields:@{
                @"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"",
                @"line_count":@(owner.lines.count), @"episode_count":@(episodeCount)
            }];
        }
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
    NSString *poster=[self.detail[@"banner"] isKindOfClass:NSString.class]&&[self.detail[@"banner"] length]?self.detail[@"banner"]:([self.item[@"banner"] isKindOfClass:NSString.class]&&[self.item[@"banner"] length]?self.item[@"banner"]:([self.detail[@"poster"] isKindOfClass:NSString.class]&&[self.detail[@"poster"] length]?self.detail[@"poster"]:([self.item[@"poster"] isKindOfClass:NSString.class]?self.item[@"poster"]:@"")));self.posterView.image=nil;if(poster.length)[HostImageLoader.shared loadPosterURL:poster intoImageView:self.posterView];
    NSString *name=[self.detail[@"name"] length]?self.detail[@"name"]:(self.item[@"name"]?:@"影片详情");self.heroTitle.text=name;self.heroMetadata.text=[self metadataSummary];
    NSMutableArray *info=[NSMutableArray array];NSString *metadata=[self metadataSummary];if(metadata.length)[info addObject:metadata];NSString *actors=[self.detail[@"actor"] isKindOfClass:NSString.class]?self.detail[@"actor"]:@"";NSString *director=[self.detail[@"director"] isKindOfClass:NSString.class]?self.detail[@"director"]:@"";
    if(director.length)[info addObject:[NSString stringWithFormat:@"导演：%@",director]];if(actors.length)[info addObject:[NSString stringWithFormat:@"主演：%@",actors]];self.metadataLabel.text=[info componentsJoinedByString:@"\n"];[self refreshCastRow];
    NSString *synopsis=[self.detail[@"description"] isKindOfClass:NSString.class]?self.detail[@"description"]:@"";if(synopsis.length>1200)synopsis=[[synopsis substringToIndex:1200] stringByAppendingString:@"…"];self.descriptionLabel.text=synopsis.length?synopsis:@"暂无简介";self.descriptionToggle.hidden=synopsis.length<220;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:5;[self updateFavoriteButton];
}
- (NSString *)favoriteKey {NSString *sourceID=self.source[@"id"]?:@"",*provider=self.provider?:@"",*itemID=self.item[@"id"]?:@"";return [NSString stringWithFormat:@"%lu:%@%lu:%@%lu:%@",(unsigned long)sourceID.length,sourceID,(unsigned long)provider.length,provider,(unsigned long)itemID.length,itemID];}
- (void)updateFavoriteButton {
    NSDictionary *favorites=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};BOOL favorite=favorites[[self favoriteKey]]!=nil;[self.favoriteButton setImage:[UIImage systemImageNamed:favorite?@"heart.fill":@"heart"] forState:UIControlStateNormal];self.favoriteButton.tintColor=favorite?HostAccent():HostSecondaryText();self.favoriteButton.accessibilityLabel=favorite?@"取消收藏影片":@"收藏影片";
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
    for(NSUInteger rowIndex=0;rowIndex<3;rowIndex++){UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=8;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<4;col++){NSUInteger index=start+rowIndex*4+col;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.layer.cornerRadius=15;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
            if(index<end){NSDictionary *episode=episodes[index];NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];[button setTitle:name forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-episode-%lu",(unsigned long)index];HostStylePillButton(button,(NSInteger)index==self.selectedEpisodeIndex);[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.episodeButtons addObject:button];}
            else button.hidden=YES;[row addArrangedSubview:button];}
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
}
- (void)selectRoute:(UIButton *)sender {
    if(sender.tag>=self.lines.count||sender.tag==self.selectedLineIndex)return;
    NSUInteger previousLine=self.selectedLineIndex;
    NSDictionary *line=self.lines[sender.tag];
    NSArray *episodes=[line[@"episodes"] isKindOfClass:NSArray.class]?line[@"episodes"]:@[];
    [RuntimeDiagnostics.shared recordEvent:@"media_route_selected" category:@"media_api" fields:@{
        @"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"", @"provider_id":self.provider?:@"",
        @"from_line_index":@(previousLine), @"line_index":@(sender.tag), @"line_count":@(self.lines.count), @"episode_count":@(episodes.count), @"selection_source":@"detail_ui"
    }];
    self.generation++;
    [self.client cancel];
    [self.spinner stopAnimating];
    self.status.hidden=YES;
    self.resumeEntry=nil;
    self.selectedLineIndex=sender.tag;
    self.selectedEpisodeIndex=0;
    self.episodePage=0;
    [self updateRouteAndEpisodeViews];
}
- (void)previousEpisodePage {if(self.episodePage>0){self.episodePage--;[self updateRouteAndEpisodeViews];}}
- (void)nextEpisodePage {NSArray *episodes=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(self.episodePage+1<(NSInteger)(episodes.count+11)/12){self.episodePage++;[self updateRouteAndEpisodeViews];}}
- (void)selectEpisode:(UIButton *)sender {
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];
    if(sender.tag>=episodes.count)return;
    self.resumeEntry=nil;
    self.selectedEpisodeIndex=sender.tag;
    [RuntimeDiagnostics.shared recordEvent:@"media_episode_selected" category:@"media_api" fields:@{
        @"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"", @"provider_id":self.provider?:@"",
        @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex), @"line_count":@(self.lines.count), @"episode_count":@(episodes.count), @"selection_source":@"detail_ui"
    }];
    [self resolveAndPlaySelectedEpisode];
}
- (void)playCurrentEpisode {NSArray *episodes=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(!episodes.count)return;if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;[self resolveAndPlaySelectedEpisode];}
- (void)resolveAndPlaySelectedEpisode {
    if(self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=self.lines[self.selectedLineIndex][@"episodes"];if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)return;
    NSDictionary *line=self.lines[self.selectedLineIndex],*episode=episodes[self.selectedEpisodeIndex];NSUInteger generation=++self.generation;[self.client cancel];self.status.hidden=NO;self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];[self.spinner startAnimating];[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"", @"provider_id":self.provider?:@"", @"request_generation":@(generation), @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex), @"line_count":@(self.lines.count), @"episode_count":@(episodes.count), @"episode_has_id":@([episode[@"id"] description].length>0), @"line_has_id":@([line[@"id"] description].length>0)}];
    NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaDetailViewController *owner=weakSelf;if(!owner)return;if(owner.generation!=generation){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"request_generation":@(generation), @"current_generation":@(owner.generation), @"reason":@"superseded_selection"}];return;}[owner.spinner stopAnimating];owner.status.hidden=NO;
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"line_index":@(owner.selectedLineIndex), @"episode_index":@(owner.selectedEpisodeIndex), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"result_received":@([result isKindOfClass:NSDictionary.class])}];owner.status.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];[owner updateRouteAndEpisodeViews];return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"line_index":@(owner.selectedLineIndex), @"episode_index":@(owner.selectedEpisodeIndex), @"result_has_media_url":@([result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0), @"result_parse_mode":@([result[@"parse"] respondsToSelector:@selector(integerValue)]?[result[@"parse"] integerValue]:0), @"result_alternate_count":@([result[@"alternates"] isKindOfClass:NSArray.class]?[result[@"alternates"] count]:0)}];owner.status.hidden=YES;NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"lineIndex":@(owner.selectedLineIndex),@"episodeIndex":@(owner.selectedEpisodeIndex),@"correlationID":owner.diagnosticTraceID?:@""};if(owner.onPlay)owner.onPlay(result,context);
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
             @{@"id":@"catalog",@"title":@"分类片架",@"detail":@"按来源真实分类逐个加载少量影片，并复用有界缓存"},
             @{@"id":@"continue",@"title":@"继续观看",@"detail":@"显示未看完的本机播放记录"},
             @{@"id":@"favorites",@"title":@"影视收藏",@"detail":@"显示已收藏的影片"},
             @{@"id":@"sources",@"title":@"固定来源",@"detail":@"在首页快速打开常用影视资源"}];
}
static NSSet<NSString *> *MediaHomeEnabledModules(void) {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;NSArray *saved=[defaults arrayForKey:MediaHomeModulesDefaultsKey];
    if(!saved)return [NSSet setWithArray:@[@"recommendations",@"catalog",@"continue",@"favorites",@"sources"]];
    NSMutableSet *valid=[NSMutableSet set];NSSet *allowed=[NSSet setWithArray:@[@"recommendations",@"catalog",@"continue",@"favorites",@"sources"]];for(id value in saved)if([value isKindOfClass:NSString.class]&&[allowed containsObject:value])[valid addObject:value];
    // Add the live category shelves once while preserving explicit later opt-outs.
    if([defaults integerForKey:MediaHomeModulesSchemaKey]<3){if(valid.count){[valid addObject:@"recommendations"];[valid addObject:@"catalog"];}[defaults setObject:[[valid allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:MediaHomeModulesDefaultsKey];[defaults setInteger:3 forKey:MediaHomeModulesSchemaKey];}
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
    NSArray *parts=[sender.accessibilityIdentifier componentsSeparatedByString:@":"];if(parts.count!=2)return;NSString *kind=parts[0],*identifier=parts[1];NSMutableSet *set=[kind isEqual:@"module"]?self.modules:self.pinnedSources;if(sender.isOn)[set addObject:identifier];else[set removeObject:identifier];NSString *key=[kind isEqual:@"module"]?MediaHomeModulesDefaultsKey:MediaHomePinnedSourcesDefaultsKey;[NSUserDefaults.standardUserDefaults setObject:[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:key];if([kind isEqual:@"module"])[NSUserDefaults.standardUserDefaults setInteger:3 forKey:MediaHomeModulesSchemaKey];if(self.onChange)self.onChange();
}
@end

@interface MediaBrowserViewController () <UICollectionViewDataSource,UICollectionViewDelegateFlowLayout,UISearchResultsUpdating,UIScrollViewDelegate>
@property(nonatomic, strong) UICollectionView *grid;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic,strong) UIScrollView *homeScroll;
@property(nonatomic,strong) UIStackView *homeStack;
@property(nonatomic,strong) UIScrollView *homeCarousel;
@property(nonatomic,strong) UIPageControl *homeCarouselPageControl;
@property(nonatomic,strong) NSDictionary *homeResult;
@property(nonatomic,copy) NSString *homeResultSourceID;
@property(nonatomic,copy) NSString *homeResultProvider;
@property(nonatomic,strong) UIView *homeStatusCard;
@property(nonatomic,strong) UILabel *homeStatusTitleLabel;
@property(nonatomic,strong) UILabel *homeStatusDetailLabel;
@property(nonatomic,strong) UIButton *homeStatusActionButton;
@property(nonatomic,strong) UIActivityIndicatorView *homeStatusIndicator;
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
@property(nonatomic,strong) UIButton *homeModeButton;
@property(nonatomic,strong) UIButton *homeSearchButton;
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
@property(nonatomic) BOOL homeStatusLoading;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger diagnosticGridApplySerial;
@property(nonatomic) NSUInteger diagnosticGridConfiguredSerial;
@property(nonatomic) NSUInteger diagnosticGridVisibleSerial;
@property(nonatomic) NSUInteger capabilityReadinessRetryCount;
@property(nonatomic,copy) NSString *diagnosticTraceID;
@property(nonatomic,strong) MediaAPIClient *configurationClient;
@property(nonatomic) BOOL openConfigurationWhenReady;
@property(nonatomic) BOOL sourceInvalidated;
@property(nonatomic) BOOL serviceUnavailable;
@property(nonatomic) BOOL restartInProgress;
@property(nonatomic) BOOL foregroundCheckNeeded;
@property(nonatomic) BOOL homeLoadDeferred;
@property(nonatomic) BOOL pendingProviderPickerAfterLoad;
@property(nonatomic) BOOL backgroundLoadInterrupted;
@property(nonatomic,strong) NSNumber *pendingHomeOffsetRestore;
@property(nonatomic) BOOL homeRebuildScheduled;
@property(nonatomic,strong) NSMutableDictionary *homeModuleCache;
@property(nonatomic,copy) NSSet *cachedHomeModules;
@property(nonatomic) NSUInteger pendingHomeRefreshCount;
@property(nonatomic) NSUInteger searchGeneration;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *browseStates;
@property(nonatomic,copy) NSDictionary *pendingBrowseState;
@property(nonatomic,copy) NSDictionary *pendingHistoryEntry;
@property(nonatomic,copy) NSDictionary *pendingHomeDetail;
@property(nonatomic,strong) NSNumber *pendingRestoreOffset;
@property(nonatomic) NSInteger pendingRestorePage;
@property(nonatomic, copy) NSDictionary *filters;
@property(nonatomic, strong) NSMutableDictionary *selectedFilters;
@property(nonatomic,copy) NSArray<NSDictionary *> *homeCategories;
@property(nonatomic) NSUInteger homeShelfGeneration;
@property(nonatomic) BOOL homeShelfRequestInFlight;
@property(nonatomic) BOOL resumeCancelledMediaRequestOnAppear;
@property(nonatomic) BOOL activeMediaRequestAppend;
@property(nonatomic) BOOL cancelledMediaRequestWasAppend;
@property(nonatomic,copy) NSString *activeMediaOperation;
@property(nonatomic,copy) NSString *cancelledMediaOperation;
@property(nonatomic,copy) NSString *nextHomeLoadTrigger;
@property(nonatomic,copy) NSString *activeHomeRequestSourceID;
@property(nonatomic,copy) NSString *activeHomeRequestProviderID;
@property(nonatomic, getter=isHomeMode) BOOL homeMode;
- (void)showHome:(BOOL)animated;
- (void)showBrowse:(BOOL)animated;
- (void)refreshHomeModules;
- (void)rebuildHomeModulesNow;
- (void)restartCurrentService;
- (void)openHomeConfiguration;
- (void)pushMediaDetail:(MediaDetailViewController *)detail;
- (void)openHomeFavorite:(NSDictionary *)entry;
- (void)openHomeRecommendation:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider;
- (void)openPendingHomeDetailForSource:(NSDictionary *)source provider:(NSString *)provider;
- (void)browseRecommendations;
- (void)applyHomeResult:(NSDictionary *)result;
- (void)presentPicker:(MediaSourcePicker *)picker;
- (void)openFavorites;
- (void)openHistory;
- (void)openHistoryEntry:(NSDictionary *)entry;
- (void)openHistoryDetail:(NSDictionary *)entry source:(NSDictionary *)source provider:(NSString *)provider;
- (void)saveCurrentBrowseState;
- (void)activate:(NSDictionary *)source keepingHome:(BOOL)keepingHome;
- (void)notifyDisplayModeChanged;
- (UIButton *)floatingButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action;
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action;
- (void)updateHomeStatusCard;
- (void)clearHomeResult;
- (void)performHomeStatusAction;
- (BOOL)isHomePageVisible;
- (void)updateSelectionControls;
- (void)openGlobalSearch;
- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories index:(NSUInteger)index generation:(NSUInteger)generation sourceID:(NSString *)sourceID provider:(NSString *)provider;
- (void)addHomeFeatureCarousel:(NSArray<NSDictionary *> *)items source:(NSDictionary *)source provider:(NSString *)provider;
- (void)loadHome;
@end
@implementation MediaBrowserViewController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf=self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){MediaBrowserViewController *owner=weakSelf;if(owner.homeMode)[owner refreshHomeModules];}];
}

- (void)searchHistorySettingChanged:(NSNotification *)notification {if([notification.userInfo[@"enabled"] boolValue])return;for(NSString *key in self.browseStates.allKeys.copy){NSMutableDictionary *state=[self.browseStates[key] mutableCopy];if(state){state[@"keyword"]=@"";self.browseStates[key]=state;}}if(self.pendingBrowseState){NSMutableDictionary *pending=[self.pendingBrowseState mutableCopy];pending[@"keyword"]=@"";self.pendingBrowseState=pending;}}
- (void)saveHomeScrollOffset {if(!self.homeScroll||!self.source)return;[NSUserDefaults.standardUserDefaults setDouble:self.homeScroll.contentOffset.y forKey:@"cctv.mediaHome.scrollOffset.v1"];}
- (void)restoreHomeScrollOffsetIfNeeded {if(!self.pendingHomeOffsetRestore||self.homeScroll.bounds.size.height<=0)return;CGFloat minimum=-self.homeScroll.adjustedContentInset.top;CGFloat maximum=MAX(minimum,self.homeScroll.contentSize.height-self.homeScroll.bounds.size.height+self.homeScroll.adjustedContentInset.bottom);self.homeScroll.contentOffset=CGPointMake(self.homeScroll.contentOffset.x,MIN(MAX(self.pendingHomeOffsetRestore.doubleValue,minimum),maximum));self.pendingHomeOffsetRestore=nil;}
- (void)saveSessionState {if(self.homeMode)[self saveHomeScrollOffset];else[self saveCurrentBrowseState];}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];if(self.homeMode)[self saveHomeScrollOffset];else[self saveCurrentBrowseState];
    if(self.loading||self.homeShelfRequestInFlight||self.activeMediaOperation.length){
        NSString *operation=self.activeMediaOperation.length?self.activeMediaOperation:(self.homeShelfRequestInFlight?@"home_shelf":@"readiness");self.cancelledMediaOperation=operation;self.cancelledMediaRequestWasAppend=self.activeMediaRequestAppend;self.resumeCancelledMediaRequestOnAppear=YES;self.generation++;self.homeShelfGeneration=0;self.homeShelfRequestInFlight=NO;self.activeMediaRequestAppend=NO;self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;[self.readiness cancel];[self.client cancel];
        if(self.cancelledMediaRequestWasAppend&&( [operation isEqualToString:@"category"]||[operation isEqualToString:@"search"]))self.page=MAX(1,self.page-1);
        if(!self.homeMode)[self saveCurrentBrowseState];else self.nextHomeLoadTrigger=nil;[self updateSelectionControls];
        [RuntimeDiagnostics.shared recordEvent:@"media_request_cancelled_on_page_exit" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"", @"operation":operation, @"reason":@"parent_page_disappeared", @"correlation_id":self.diagnosticTraceID?:@""}];
    }
}
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if(self.foregroundCheckNeeded){[self resumeAfterForeground];return;}
    if(self.resumeCancelledMediaRequestOnAppear){self.resumeCancelledMediaRequestOnAppear=NO;NSString *operation=self.cancelledMediaOperation?:@"";BOOL wasAppend=self.cancelledMediaRequestWasAppend;self.cancelledMediaOperation=nil;
        if(self.homeMode) {self.cancelledMediaRequestWasAppend=NO;self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeLoadDeferred=YES;[RuntimeDiagnostics.shared recordEvent:@"media_request_resume_skipped" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"",@"operation":operation,@"reason":@"home_content_requires_explicit_resource_refresh",@"correlation_id":self.diagnosticTraceID?:@""}];[self showMessage:self.homeResult?@"已保留首页内容；需要更新请到资源页手动刷新":@"首页加载已暂停；请到资源页手动加载" loading:NO];return;}
        [RuntimeDiagnostics.shared recordEvent:@"media_request_resumed_after_page_return" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"", @"operation":operation, @"append":@(wasAppend), @"correlation_id":self.diagnosticTraceID?:@""}];
        if([operation isEqualToString:@"capabilities"]||[operation isEqualToString:@"providers"]){[self loadCapabilities];return;}
        if([operation isEqualToString:@"home"]){self.nextHomeLoadTrigger=@"page_return";[self loadHome];return;}
        if([operation isEqualToString:@"home_shelf"]){if(self.homeResult&&self.homeCategories.count){self.homeShelfGeneration=self.generation;[self loadHomeShelves:self.homeCategories index:0 generation:self.generation sourceID:[self.source[@"id"] description]?:@"" provider:self.provider?:@""];}else[self loadHome];return;}
        if([operation isEqualToString:@"category"]||[operation isEqualToString:@"search"]){self.cancelledMediaRequestWasAppend=NO;if(wasAppend){self.page++;[self loadListing:YES];}else[self loadListing:NO];return;}
        self.cancelledMediaRequestWasAppend=NO;
        if(self.source)[self activate:self.source keepingHome:YES];return;
    }
    if(self.homeMode)[self refreshHomeModules];
}
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
    [super viewDidLoad];self.title=@"";self.view.backgroundColor=HostBackground();self.items=@[];self.keyword=@"";self.homeMode=YES;NSDictionary *savedBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];self.browseStates=[savedBrowse isKindOfClass:NSDictionary.class]?[savedBrowse mutableCopy]:[NSMutableDictionary dictionary];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(searchHistorySettingChanged:) name:@"MediaGlobalSearchHistoryDidChange" object:nil];self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
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
            ,[UIAction actionWithTitle:@"检查当前服务连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *action){[weakSelf checkCurrentService];}]
            ,[UIAction actionWithTitle:@"重启当前资源服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *action){[weakSelf restartCurrentService];}]
        ]]}
    ])];
    self.homeScroll=[UIScrollView new];self.homeScroll.translatesAutoresizingMaskIntoConstraints=NO;self.homeScroll.alwaysBounceVertical=YES;self.homeScroll.delegate=self;self.homeScroll.accessibilityIdentifier=@"media-home-scroll";[self.view addSubview:self.homeScroll];
    self.homeStack=[UIStackView new];self.homeStack.translatesAutoresizingMaskIntoConstraints=NO;self.homeStack.axis=UILayoutConstraintAxisVertical;self.homeStack.spacing=18;self.homeStack.layoutMargins=UIEdgeInsetsMake(10,16,28,16);self.homeStack.layoutMarginsRelativeArrangement=YES;[self.homeScroll addSubview:self.homeStack];
    self.selectionRow=[UIStackView new];self.selectionRow.translatesAutoresizingMaskIntoConstraints=NO;self.selectionRow.axis=UILayoutConstraintAxisHorizontal;self.selectionRow.distribution=UIStackViewDistributionFillEqually;self.selectionRow.spacing=10;[self.view addSubview:self.selectionRow];
    self.sourceSelectButton=[self selectionButtonWithSymbol:@"square.stack.3d.up" identifier:@"media-source-selector" action:@selector(chooseResource)];
    self.providerSelectButton=[self selectionButtonWithSymbol:@"globe" identifier:@"media-provider-selector" action:@selector(chooseProvider)];
    [self.selectionRow addArrangedSubview:self.sourceSelectButton];[self.selectionRow addArrangedSubview:self.providerSelectButton];
    self.homeModeButton=[self floatingButtonWithSymbol:@"square.grid.2x2.fill" identifier:@"media-home-browse-button" action:@selector(toggleHomeBrowse)];self.homeModeButton.accessibilityLabel=@"打开影视库";[self.view addSubview:self.homeModeButton];
    self.homeSearchButton=[self floatingButtonWithSymbol:@"magnifyingglass" identifier:@"media-home-search-button" action:@selector(openGlobalSearchFromHome)];self.homeSearchButton.accessibilityLabel=@"全站搜索影视";[self.view addSubview:self.homeSearchButton];
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
        [self.homeScroll.topAnchor constraintEqualToAnchor:self.selectionRow.bottomAnchor constant:8],[self.homeScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.homeScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.homeScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.homeStack.leadingAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.leadingAnchor],[self.homeStack.trailingAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.trailingAnchor],[self.homeStack.topAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.topAnchor],[self.homeStack.bottomAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.bottomAnchor],[self.homeStack.widthAnchor constraintEqualToAnchor:self.homeScroll.frameLayoutGuide.widthAnchor],
        [self.selectionRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],[self.selectionRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],[self.selectionRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],[self.selectionRow.heightAnchor constraintGreaterThanOrEqualToConstant:50],
        [self.homeSearchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18],[self.homeSearchButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],[self.homeSearchButton.widthAnchor constraintEqualToConstant:56],[self.homeSearchButton.heightAnchor constraintEqualToConstant:56],
        [self.homeModeButton.trailingAnchor constraintEqualToAnchor:self.homeSearchButton.trailingAnchor],[self.homeModeButton.bottomAnchor constraintEqualToAnchor:self.homeSearchButton.topAnchor constant:-12],[self.homeModeButton.widthAnchor constraintEqualToConstant:52],[self.homeModeButton.heightAnchor constraintEqualToConstant:52],
        [self.categoryScroll.topAnchor constraintEqualToAnchor:self.selectionRow.bottomAnchor constant:8],[self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.categoryScroll.heightAnchor constraintEqualToConstant:44],
        [self.categories.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor constant:14],[self.categories.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor constant:-14],[self.categories.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor constant:4],[self.categories.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor constant:-4],[self.categories.heightAnchor constraintEqualToConstant:36],
        [self.readinessStageLabel.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor constant:2],[self.readinessStageLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[self.readinessStageLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[self.readinessStageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:16],
        [self.grid.topAnchor constraintEqualToAnchor:self.readinessStageLabel.bottomAnchor constant:2],[self.grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.grid.bottomAnchor constraintEqualToAnchor:self.moreButton.topAnchor],
        [self.moreButton.heightAnchor constraintEqualToConstant:40],[self.moreButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.moreButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],[self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.resourceButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:16],[self.resourceButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-16]]];
    [self setBrowseControlsHidden:YES];
    self.homeScroll.contentInset=UIEdgeInsetsMake(0,0,82,0);self.homeScroll.scrollIndicatorInsets=self.homeScroll.contentInset;
    [self loadSources];
    if(self.onDisplayModeChanged)self.onDisplayModeChanged(YES);
}
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);button.layer.cornerRadius=23;button.contentEdgeInsets=UIEdgeInsetsMake(8,12,8,12);button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.82;button.accessibilityIdentifier=identifier;button.accessibilityTraits|=UIAccessibilityTraitButton;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostAccent();button.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,7);[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (UIButton *)floatingButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);button.layer.cornerRadius=28;button.layer.cornerCurve=kCACornerCurveContinuous;button.clipsToBounds=YES;button.backgroundColor=HostGlassTint();HostSetLayerBorderColor(button,HostBorder());button.layer.borderWidth=0.7;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostText();button.accessibilityIdentifier=identifier;button.accessibilityTraits|=UIAccessibilityTraitButton;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)updateSelectionControls {
    NSString *sourceName=[self.source[@"name"] isKindOfClass:NSString.class]?self.source[@"name"]:@"";
    NSString *sourceTitle=sourceName.length?sourceName:@"选择影视资源";
    [self.sourceSelectButton setTitle:[NSString stringWithFormat:@"%@  ▾",sourceTitle] forState:UIControlStateNormal];
    self.sourceSelectButton.accessibilityLabel=sourceName.length?[NSString stringWithFormat:@"影视资源：%@，点按切换",sourceName]:@"选择影视资源";
    self.sourceSelectButton.accessibilityHint=@"打开已导入影视资源列表；选择后可切换其站点";
    NSString *providerTitle=nil;
    NSString *providerID=self.provider;
    NSString *savedProviderKey=[NSString stringWithFormat:@"mediaProvider.%@",self.source[@"id"]?:@""];
    NSString *savedProviderID=[NSUserDefaults.standardUserDefaults stringForKey:savedProviderKey];
    if(!providerID.length)providerID=savedProviderID;
    for(NSDictionary *candidate in self.providers){if([candidate[@"id"] isEqual:providerID]){providerTitle=[candidate[@"name"] isKindOfClass:NSString.class]?candidate[@"name"]:candidate[@"id"];break;}}
    if(!providerTitle.length&&providerID.length){
        NSString *savedName=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProviderName.%@",self.source[@"id"]?:@""]];
        providerTitle=[savedProviderID isEqualToString:providerID]&&savedName.length?savedName:providerID;
    }
    BOOL directAPI=MediaSourceUsesNativeCatalogAPI(self.source);
    NSArray *capabilities=[self.source[@"capabilities"] isKindOfClass:NSArray.class]?self.source[@"capabilities"]:@[];
    NSString *emptySiteTitle=!self.source?@"选择站点":(self.pendingProviderPickerAfterLoad?@"正在读取站点…":(self.loading?@"加载站点…":(!capabilities.count||[capabilities containsObject:@"providers"]||!self.client||self.sourceInvalidated?@"选择站点":@"无站点")));
    NSString *siteTitle=directAPI?@"单站点资源":(providerTitle.length?providerTitle:emptySiteTitle);
    self.providerSelectButton.hidden=directAPI&&!self.homeMode;
    [self.providerSelectButton setTitle:[NSString stringWithFormat:@"%@%@",siteTitle,directAPI?@"":@"  ▾"] forState:UIControlStateNormal];
    self.providerSelectButton.enabled=!directAPI&&self.source!=nil&&!(self.pendingProviderPickerAfterLoad&&self.loading);
    self.providerSelectButton.alpha=self.providerSelectButton.enabled?1.0:0.62;
    self.providerSelectButton.accessibilityLabel=directAPI?@"此资源为单站点接口":(providerTitle.length?[NSString stringWithFormat:@"影视站点：%@，点按切换",providerTitle]:@"选择影视站点");
    self.providerSelectButton.accessibilityHint=self.pendingProviderPickerAfterLoad?@"正在准备并读取站点列表":(self.providers.count?@"打开当前影视资源的站点列表":@"点按后按需准备资源并读取站点列表");
}
- (void)setBrowseControlsHidden:(BOOL)hidden {
    self.selectionRow.hidden=NO;self.categoryScroll.hidden=hidden;self.readinessStageLabel.hidden=hidden;self.grid.hidden=hidden;self.moreButton.hidden=hidden||!self.hasMore;self.homeScroll.hidden=!hidden;
    self.homeSearchButton.hidden=!hidden;self.homeModeButton.hidden=NO;[self.homeModeButton setImage:[UIImage systemImageNamed:hidden?@"square.grid.2x2.fill":@"house.fill"] forState:UIControlStateNormal];self.homeModeButton.accessibilityIdentifier=hidden?@"media-home-browse-button":@"media-browser-home-button";self.homeModeButton.accessibilityLabel=hidden?@"打开影视库":@"返回首页";
    if(hidden){self.navigationItem.searchController=nil;self.search.active=NO;self.status.hidden=YES;self.resourceButton.hidden=YES;[self.spinner stopAnimating];}
    else{self.status.hidden=!self.status.text.length||self.items.count>0;self.resourceButton.hidden=self.loading||self.items.count>0;self.readinessStageLabel.hidden=!self.readinessStageLabel.text.length;}
}
- (void)toggleHomeBrowse {if(self.homeMode)[self showBrowse:YES];else[self showHome:YES];}
- (void)notifyDisplayModeChanged {if(self.onDisplayModeChanged)self.onDisplayModeChanged(self.homeMode);}
- (void)showHome:(BOOL)animated {
    if(!self.homeMode)[self saveCurrentBrowseState];self.homeMode=YES;self.title=@"";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.navigationItem.searchController=nil;self.search.active=NO;self.navigationItem.prompt=nil;[self setBrowseControlsHidden:YES];[self refreshHomeModules];[self notifyDisplayModeChanged];if(animated)[UIView transitionWithView:self.homeScroll duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
}
- (void)showBrowse:(BOOL)animated {
    self.homeMode=NO;self.title=@"影视库";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;[self setBrowseControlsHidden:NO];[self notifyDisplayModeChanged];
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
    UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom];card.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(card,14);HostInstallPressFeedback(card);card.accessibilityLabel=[NSString stringWithFormat:@"%@，%@",title,subtitle?:@""];
    UIImageView *image=[UIImageView new];image.translatesAutoresizingMaskIntoConstraints=NO;image.contentMode=UIViewContentModeScaleAspectFill;image.clipsToBounds=YES;image.layer.cornerRadius=11;image.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner;image.backgroundColor=HostNeutralSurface();[card addSubview:image];
    if(imageURL.length)[HostImageLoader.shared loadPosterURL:imageURL intoImageView:image];else if(symbol.length){UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIImageSymbolWeightMedium];image.image=[UIImage systemImageNamed:symbol withConfiguration:config];image.contentMode=UIViewContentModeCenter;image.tintColor=HostAccent();}
    UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.text=title;name.textColor=HostText();name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];name.adjustsFontForContentSizeCategory=YES;name.numberOfLines=1;name.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:name];
    UILabel *detail=[UILabel new];detail.translatesAutoresizingMaskIntoConstraints=NO;detail.text=subtitle;detail.textColor=HostSecondaryText();detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];detail.adjustsFontForContentSizeCategory=YES;detail.numberOfLines=1;detail.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[card.widthAnchor constraintEqualToConstant:MAX(88,self.view.bounds.size.width/3.0-18)],[card.heightAnchor constraintEqualToAnchor:card.widthAnchor multiplier:1.5 constant:54],[image.topAnchor constraintEqualToAnchor:card.topAnchor],[image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[image.heightAnchor constraintEqualToAnchor:card.widthAnchor multiplier:1.5],[name.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:7],[name.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],[name.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],[detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:3],[detail.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],[detail.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],[detail.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-6]]];
    [card addAction:[UIAction actionWithHandler:^(UIAction *event){if(action)action();}] forControlEvents:UIControlEventTouchUpInside];return card;
}
- (UIButton *)homeFeatureCardForItem:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    NSString *title=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"精选推荐";
    NSString *imageURL=[item[@"banner"] isKindOfClass:NSString.class]?item[@"banner"]:([item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"");
    NSString *remarks=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"";
    UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom];card.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(card,22);HostInstallPressFeedback(card);card.accessibilityIdentifier=@"media-home-feature";card.accessibilityLabel=[NSString stringWithFormat:@"精选影片 %@，%@",title,remarks];
    UIImageView *image=[UIImageView new];image.translatesAutoresizingMaskIntoConstraints=NO;image.contentMode=UIViewContentModeScaleAspectFill;image.clipsToBounds=YES;image.backgroundColor=HostNeutralSurface();[card addSubview:image];if(imageURL.length)[HostImageLoader.shared loadPosterURL:imageURL intoImageView:image];
    UIView *scrim=[MediaHomePosterFade new];scrim.translatesAutoresizingMaskIntoConstraints=NO;[card addSubview:scrim];
    UILabel *eyebrow=[UILabel new];eyebrow.translatesAutoresizingMaskIntoConstraints=NO;NSMutableArray *metadata=[NSMutableArray array];for(NSString *key in @[@"year",@"area",@"type"]){id value=item[key];if([value isKindOfClass:NSString.class]&&[value length])[metadata addObject:value];}eyebrow.text=[metadata componentsJoinedByString:@" · "];eyebrow.textColor=HostSecondaryText();eyebrow.textAlignment=NSTextAlignmentCenter;eyebrow.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];eyebrow.adjustsFontForContentSizeCategory=YES;eyebrow.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:eyebrow];
    UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.text=title;name.textColor=HostText();name.textAlignment=NSTextAlignmentCenter;name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];name.adjustsFontForContentSizeCategory=YES;name.numberOfLines=2;name.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:name];
    UILabel *detail=[UILabel new];detail.translatesAutoresizingMaskIntoConstraints=NO;detail.text=remarks.length?remarks:@"点按查看影片详情";detail.textColor=HostSecondaryText();detail.textAlignment=NSTextAlignmentCenter;detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];detail.adjustsFontForContentSizeCategory=YES;detail.numberOfLines=1;detail.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[image.topAnchor constraintEqualToAnchor:card.topAnchor],[image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[image.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],[scrim.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[scrim.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[scrim.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],[scrim.heightAnchor constraintGreaterThanOrEqualToConstant:112],[eyebrow.leadingAnchor constraintEqualToAnchor:scrim.leadingAnchor constant:16],[eyebrow.trailingAnchor constraintEqualToAnchor:scrim.trailingAnchor constant:-16],[eyebrow.topAnchor constraintEqualToAnchor:scrim.topAnchor constant:10],[name.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],[name.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],[name.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:2],[detail.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],[detail.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],[detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],[detail.bottomAnchor constraintLessThanOrEqualToAnchor:scrim.bottomAnchor constant:-8]]];
    __weak typeof(self) weakSelf=self;[card addAction:[UIAction actionWithHandler:^(UIAction *event){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHomeRecommendation:item source:source provider:provider];}] forControlEvents:UIControlEventTouchUpInside];return card;
}
- (void)addHomeFeatureCarousel:(NSArray<NSDictionary *> *)items source:(NSDictionary *)source provider:(NSString *)provider {
    if(!items.count)return;
    UIView *container=[UIView new];container.translatesAutoresizingMaskIntoConstraints=NO;container.accessibilityIdentifier=@"media-home-feature-carousel";
    UIScrollView *paging=[UIScrollView new];paging.translatesAutoresizingMaskIntoConstraints=NO;paging.pagingEnabled=YES;paging.delegate=self;paging.showsHorizontalScrollIndicator=NO;paging.alwaysBounceHorizontal=NO;paging.decelerationRate=UIScrollViewDecelerationRateFast;paging.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;paging.accessibilityIdentifier=@"media-home-feature-paging";[container addSubview:paging];
    UIStackView *row=[UIStackView new];row.translatesAutoresizingMaskIntoConstraints=NO;row.axis=UILayoutConstraintAxisHorizontal;row.alignment=UIStackViewAlignmentFill;row.distribution=UIStackViewDistributionFillEqually;row.spacing=0;[paging addSubview:row];
    NSUInteger count=MIN((NSUInteger)5,items.count);
    for(NSUInteger index=0;index<count;index++){
        NSDictionary *item=items[index];UIButton *card=[self homeFeatureCardForItem:item source:source provider:provider];card.accessibilityIdentifier=index==0?@"media-home-feature":[NSString stringWithFormat:@"media-home-feature-%lu",(unsigned long)index];[row addArrangedSubview:card];[card.widthAnchor constraintEqualToAnchor:paging.frameLayoutGuide.widthAnchor].active=YES;
    }
    UIPageControl *pages=[UIPageControl new];pages.translatesAutoresizingMaskIntoConstraints=NO;pages.numberOfPages=count;pages.currentPage=0;pages.hidesForSinglePage=YES;pages.currentPageIndicatorTintColor=HostAccent();pages.pageIndicatorTintColor=HostSecondaryText();pages.accessibilityLabel=@"首页精选影片分页";pages.accessibilityIdentifier=@"media-home-feature-pages";[container addSubview:pages];
    [NSLayoutConstraint activateConstraints:@[[container.heightAnchor constraintEqualToConstant:MIN(540,MAX(240,self.view.bounds.size.width*1.05))],[paging.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],[paging.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],[paging.topAnchor constraintEqualToAnchor:container.topAnchor],[paging.bottomAnchor constraintEqualToAnchor:pages.topAnchor constant:-2],[row.leadingAnchor constraintEqualToAnchor:paging.contentLayoutGuide.leadingAnchor],[row.trailingAnchor constraintEqualToAnchor:paging.contentLayoutGuide.trailingAnchor],[row.topAnchor constraintEqualToAnchor:paging.contentLayoutGuide.topAnchor],[row.bottomAnchor constraintEqualToAnchor:paging.contentLayoutGuide.bottomAnchor],[row.heightAnchor constraintEqualToAnchor:paging.frameLayoutGuide.heightAnchor],[pages.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],[pages.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],[pages.heightAnchor constraintEqualToConstant:16]]];
    self.homeCarousel=paging;self.homeCarouselPageControl=pages;[self.homeStack addArrangedSubview:container];
}
- (BOOL)isHomePageVisible {
    if(!self.homeMode||!self.view.window||self.view.hidden||self.homeScroll.hidden)return NO;
    UIViewController *top=self.navigationController.topViewController;
    return top==self||top==self.parentViewController;
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView!=self.homeCarousel||scrollView.bounds.size.width<=0)return;
    NSInteger page=(NSInteger)llround(scrollView.contentOffset.x/scrollView.bounds.size.width);self.homeCarouselPageControl.currentPage=MAX(0,MIN(self.homeCarouselPageControl.numberOfPages-1,page));
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {if(scrollView==self.homeScroll)[self saveHomeScrollOffset];}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {if(scrollView==self.homeScroll&&!decelerate)[self saveHomeScrollOffset];}
- (NSDictionary *)cachedHomeResultForSelectedProvider:(NSString **)providerOut {
    if(!self.source)return nil;
    NSString *provider=self.provider.length?self.provider:[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",self.source[@"id"]?:@""]];
    if(providerOut)*providerOut=provider?:@"";
    NSString *sourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:@"";
    if(self.homeResult&&[self.homeResultSourceID isEqualToString:sourceID]&&[(self.homeResultProvider?:@"") isEqualToString:(provider?:@"")])return self.homeResult;
    NSMutableDictionary *arguments=[NSMutableDictionary dictionary];if(provider.length)arguments[@"provider"]=provider;
    id result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:arguments maximumAge:DBL_MAX isStale:NULL];
    return [result isKindOfClass:NSDictionary.class]?result:nil;
}
- (void)clearHomeResult {self.homeResult=nil;self.homeResultSourceID=nil;self.homeResultProvider=nil;}
- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories index:(NSUInteger)index generation:(NSUInteger)generation sourceID:(NSString *)sourceID provider:(NSString *)provider {
    NSUInteger limit=MIN((NSUInteger)8,categories.count);
    if(index>=limit||!self.client||self.homeShelfRequestInFlight||self.generation!=generation||self.homeShelfGeneration!=generation||
       ![[self.source[@"id"] description] isEqual:sourceID]||![(self.provider?:@"") isEqual:provider]||!self.isHomePageVisible)return;
    NSDictionary *category=categories[index];NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?[category[@"id"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    NSString *name=[category[@"name"] isKindOfClass:NSString.class]?[category[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(!identifier.length||!name.length){[self loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];return;}
    NSDictionary *arguments=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];BOOL stale=NO;
    id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:arguments maximumAge:6*3600 isStale:&stale];
    NSUInteger cachedCount=[cached isKindOfClass:NSDictionary.class]&&[cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0;
    [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_cache_decision" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":sourceID,@"provider_id":provider?:@"",@"category_index":@(index),@"cache_hit":@([cached isKindOfClass:NSDictionary.class]),@"cache_stale":@(stale),@"cached_item_count":@(cachedCount),@"refresh_skipped":@([cached isKindOfClass:NSDictionary.class]&&!stale)}];
    if(cached&&!stale){[self loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];return;}
    CFTimeInterval started=CACurrentMediaTime();__weak typeof(self) weakSelf=self;self.homeShelfRequestInFlight=YES;self.activeMediaOperation=@"home_shelf";
    [self.client call:@"category" arguments:arguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;if(owner.homeShelfGeneration==generation){owner.homeShelfRequestInFlight=NO;if([owner.activeMediaOperation isEqualToString:@"home_shelf"])owner.activeMediaOperation=nil;}if(owner.generation!=generation||!owner.homeMode||![[owner.source[@"id"] description] isEqual:sourceID]||![(owner.provider?:@"") isEqual:provider]){NSString *reason=owner.generation!=generation?@"superseded_generation":(!owner.homeMode?@"home_mode_changed":(![[owner.source[@"id"] description] isEqual:sourceID]?@"source_changed":@"provider_changed"));[RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":reason}];return;}
        NSTimeInterval elapsed=MAX(0,CACurrentMediaTime()-started);
        if(!error&&[result isKindOfClass:NSDictionary.class]){
            [[MediaMetadataCache shared] storeResult:result forSource:owner.source operation:@"category" arguments:arguments];
            [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"item_count":@([result[@"items"] isKindOfClass:NSArray.class]?[result[@"items"] count]:0),@"elapsed_ms":@((NSInteger)(elapsed*1000))}];
            if(owner.isHomePageVisible)[owner refreshHomeModules];
        }else{
            [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"elapsed_ms":@((NSInteger)(elapsed*1000)),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(150*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{MediaBrowserViewController *page=weakSelf;if(page)[page loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];});
    }];
}
- (void)addHomeCards:(NSArray<UIButton *> *)cards emptyText:(NSString *)emptyText {
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.showsHorizontalScrollIndicator=NO;scroll.alwaysBounceHorizontal=YES;UIStackView *row=[UIStackView new];row.translatesAutoresizingMaskIntoConstraints=NO;row.axis=UILayoutConstraintAxisHorizontal;row.spacing=10;[scroll addSubview:row];
    if(cards.count){for(UIButton *card in cards)[row addArrangedSubview:card];}else{UILabel *empty=[UILabel new];empty.text=emptyText;empty.textColor=HostSecondaryText();empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];empty.numberOfLines=0;empty.backgroundColor=HostCard();empty.layer.cornerRadius=14;empty.clipsToBounds=YES;empty.textAlignment=NSTextAlignmentCenter;[row addArrangedSubview:empty];[empty.widthAnchor constraintGreaterThanOrEqualToConstant:240].active=YES;[empty.heightAnchor constraintEqualToConstant:78].active=YES;}
    [NSLayoutConstraint activateConstraints:@[[scroll.heightAnchor constraintEqualToConstant:MAX(88,self.view.bounds.size.width/3.0-18)*1.5+54],[row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],[row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],[row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor]]];[self.homeStack addArrangedSubview:scroll];
}
- (void)updateHomeStatusCard {
    if(!self.homeStack)return;
    BOOL sourceActive=self.source&&(MediaSourceUsesNativeCatalogAPI(self.source)||[PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""]);
    NSString *statusMessage=[self.status.text isKindOfClass:NSString.class]?self.status.text:@"";NSString *stage=[self.readinessStageLabel.text isKindOfClass:NSString.class]?self.readinessStageLabel.text:@"";
    BOOL visible=self.homeStatusLoading||statusMessage.length||self.homeLoadDeferred||(self.source&&!sourceActive);
    if(!visible){if(self.homeStatusCard){[self.homeStack removeArrangedSubview:self.homeStatusCard];[self.homeStatusCard removeFromSuperview];self.homeStatusCard=nil;self.homeStatusTitleLabel=nil;self.homeStatusDetailLabel=nil;self.homeStatusActionButton=nil;self.homeStatusIndicator=nil;}return;}
    if(!self.homeStatusCard){
        UIView *card=[UIView new];card.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(card,16);card.accessibilityIdentifier=@"media-home-status-card";
        UIStackView *content=[UIStackView new];content.translatesAutoresizingMaskIntoConstraints=NO;content.axis=UILayoutConstraintAxisVertical;content.spacing=8;content.layoutMargins=UIEdgeInsetsMake(12,14,12,14);content.layoutMarginsRelativeArrangement=YES;[card addSubview:content];
        UIStackView *heading=[UIStackView new];heading.axis=UILayoutConstraintAxisHorizontal;heading.alignment=UIStackViewAlignmentCenter;heading.spacing=9;
        self.homeStatusIndicator=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];[heading addArrangedSubview:self.homeStatusIndicator];
        self.homeStatusTitleLabel=[UILabel new];self.homeStatusTitleLabel.textColor=HostText();self.homeStatusTitleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.homeStatusTitleLabel.adjustsFontForContentSizeCategory=YES;self.homeStatusTitleLabel.numberOfLines=0;self.homeStatusTitleLabel.accessibilityIdentifier=@"media-home-status-title";[heading addArrangedSubview:self.homeStatusTitleLabel];[content addArrangedSubview:heading];
        self.homeStatusDetailLabel=[UILabel new];self.homeStatusDetailLabel.textColor=HostSecondaryText();self.homeStatusDetailLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.homeStatusDetailLabel.adjustsFontForContentSizeCategory=YES;self.homeStatusDetailLabel.numberOfLines=0;[content addArrangedSubview:self.homeStatusDetailLabel];
        self.homeStatusActionButton=[self homeActionButton:@"" symbol:@"arrow.right" action:@selector(performHomeStatusAction) primary:NO];self.homeStatusActionButton.accessibilityIdentifier=@"media-home-status-action";self.homeStatusActionButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;self.homeStatusActionButton.accessibilityHint=@"按当前影视来源状态执行启动、重试或进入影视库";[content addArrangedSubview:self.homeStatusActionButton];
        [NSLayoutConstraint activateConstraints:@[[content.topAnchor constraintEqualToAnchor:card.topAnchor],[content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]]];self.homeStatusCard=card;[self.homeStack insertArrangedSubview:card atIndex:0];
    }
    NSString *diagnostics=[NSString stringWithFormat:@"%@ %@",statusMessage,stage];BOOL failed=NO;for(NSString *marker in @[@"失败",@"超时",@"错误",@"无法",@"无效",@"不可用",@"移除",@"failed",@"timeout",@"error",@"refused",@"not found"]){if([diagnostics localizedCaseInsensitiveContainsString:marker]){failed=YES;break;}}
    NSString *title=statusMessage.length?statusMessage:(self.homeStatusLoading?@"正在准备影视来源…":@"所选影视来源尚未启动");NSString *detail=@"";
    if(self.homeLoadDeferred){title=statusMessage.length?statusMessage:@"已恢复上次首页";detail=self.source?@"已保留本机首页内容。需要加载或更新时，请到资源页手动操作。":@"导入影视资源后，请到资源页手动加载首页内容。";}
    else if(self.homeStatusLoading&&stage.length&&![stage isEqualToString:title])detail=stage;
    else if(!sourceActive&&self.source){NSString *engine=[self.source[@"engine"] isKindOfClass:NSString.class]?self.source[@"engine"]:@"影视服务";detail=[NSString stringWithFormat:@"%@ · 点按后启动并检查本机接口",engine];}
    self.homeStatusTitleLabel.text=title;self.homeStatusDetailLabel.text=detail;self.homeStatusDetailLabel.hidden=!detail.length;self.homeStatusIndicator.hidden=!self.homeStatusLoading;if(self.homeStatusLoading)[self.homeStatusIndicator startAnimating];else[self.homeStatusIndicator stopAnimating];
    NSString *actionTitle=self.homeStatusLoading?@"":(!self.source?@"导入影视资源":(self.homeLoadDeferred?(self.homeResult?@"到资源页更新首页":@"到资源页加载首页"):(sourceActive?(failed?@"重试":@"打开影视库"):(failed||self.sourceInvalidated?@"重试启动":@"启动并加载"))));[self.homeStatusActionButton setTitle:actionTitle forState:UIControlStateNormal];self.homeStatusActionButton.hidden=!actionTitle.length;
    if(self.serviceUnavailable&&!self.homeStatusLoading&&!self.homeLoadDeferred){[self.homeStatusActionButton setTitle:@"重启此服务并重新检查" forState:UIControlStateNormal];self.homeStatusActionButton.hidden=NO;}
}
- (void)performHomeStatusAction {
    if(self.homeLoadDeferred){[self openResources];return;}
    if(!self.source){[self openResources];return;}
    if(self.serviceUnavailable){[self restartCurrentService];return;}
    NSString *diagnostics=[NSString stringWithFormat:@"%@ %@",self.status.text?:@"",self.readinessStageLabel.text?:@""];BOOL failed=NO;for(NSString *marker in @[@"失败",@"超时",@"错误",@"无法",@"无效",@"不可用",@"移除",@"failed",@"timeout",@"error",@"refused",@"not found"]){if([diagnostics localizedCaseInsensitiveContainsString:marker]){failed=YES;break;}}
    BOOL active=MediaSourceUsesNativeCatalogAPI(self.source)||[PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""];
    if(!active||self.sourceInvalidated||failed){self.nextHomeLoadTrigger=@"home_status_action";[self activate:self.source keepingHome:YES];return;}
    [self showBrowse:YES];
}
- (void)addHomeCategoryShelves:(NSSet<NSString *> *)enabled {
    if(![enabled containsObject:@"catalog"])return;__weak typeof(self) weakSelf=self;NSString *provider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&provider];NSArray *categories=self.homeCategories.count?self.homeCategories:([home[@"categories"] isKindOfClass:NSArray.class]?home[@"categories"]:@[]);NSUInteger shown=0;
    for(NSDictionary *category in categories){if(shown>=8)break;NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";NSString *name=[category[@"name"] isKindOfClass:NSString.class]?category[@"name"]:@"";if(!identifier.length||!name.length)continue;NSDictionary *arguments=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];id result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:arguments maximumAge:DBL_MAX isStale:NULL];NSArray *items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];if(!items.count)continue;NSMutableArray *cards=[NSMutableArray array];for(NSUInteger itemIndex=0;itemIndex<items.count&&cards.count<8;itemIndex++){NSDictionary *item=items[itemIndex];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"影视内容" subtitle:item[@"remarks"]?:name imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHomeRecommendation:item source:weakSelf.source provider:provider];}]];}UIStackView *heading=(UIStackView *)[self homeSectionHeader:name actionTitle:@"" selector:nil];UIButton *all=[UIButton buttonWithType:UIButtonTypeSystem];[all setTitle:@"全部 ›" forState:UIControlStateNormal];[all addAction:[UIAction actionWithHandler:^(UIAction *action){MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner showBrowse:YES];owner.category=identifier;owner.keyword=@"";owner.page=1;[owner loadListing:NO];}] forControlEvents:UIControlEventTouchUpInside];[heading addArrangedSubview:all];[self.homeStack addArrangedSubview:heading];[self addHomeCards:cards emptyText:@""];shown++;}
}
- (void)refreshHomeModules {
    self.pendingHomeRefreshCount=MIN((NSUInteger)1000000,self.pendingHomeRefreshCount+1);
    if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground)return;
    if(!self.homeStack.arrangedSubviews.count){[self rebuildHomeModulesNow];return;}
    if(self.homeRebuildScheduled)return;self.homeRebuildScheduled=YES;
    __weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.homeRebuildScheduled=NO;if(UIApplication.sharedApplication.applicationState!=UIApplicationStateBackground)[owner rebuildHomeModulesNow];});
}
- (NSArray *)homeCategoryModuleSignature {
    NSString *provider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&provider];
    NSArray *categories=self.homeCategories.count?self.homeCategories:([home[@"categories"] isKindOfClass:NSArray.class]?home[@"categories"]:@[]);
    NSMutableArray *signature=[NSMutableArray arrayWithObject:provider?:@""];NSUInteger count=0;
    for(NSDictionary *category in categories){if(count>=8)break;NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";NSString *name=[category[@"name"] isKindOfClass:NSString.class]?category[@"name"]:@"";if(!identifier.length||!name.length)continue;
        NSDictionary *args=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];
        NSDictionary *result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:args maximumAge:24*3600 isStale:NULL];NSArray *items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];
        if(!items.count)continue;[signature addObject:@[identifier,name,[items subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)8,items.count))]]];count++;
    }
    return signature;
}
- (void)appendHomeModule:(NSString *)key signature:(id)signature build:(dispatch_block_t)build {
    if(!self.homeModuleCache)self.homeModuleCache=[NSMutableDictionary dictionary];
    NSArray *context=@[signature?:@[],self.source[@"id"]?:@"",self.provider?:@"",@(self.view.bounds.size.width),@(self.traitCollection.userInterfaceStyle),self.traitCollection.preferredContentSizeCategory?:@""];
    NSData *identity=[NSJSONSerialization isValidJSONObject:context]?[NSJSONSerialization dataWithJSONObject:context options:NSJSONWritingSortedKeys error:NULL]:nil;
    NSDictionary *cached=self.homeModuleCache[key];
    if(identity&&[cached[@"identity"] isEqual:identity]){
        for(UIView *view in cached[@"views"])[self.homeStack addArrangedSubview:view];
        if([key isEqual:@"feature"]){self.homeCarousel=cached[@"carousel"];self.homeCarouselPageControl=cached[@"pages"];self.homeCarousel.delegate=self;}
        return;
    }
    NSUInteger start=self.homeStack.arrangedSubviews.count;build();
    if(identity){NSMutableDictionary *record=[@{@"identity":identity,@"views":[self.homeStack.arrangedSubviews subarrayWithRange:NSMakeRange(start,self.homeStack.arrangedSubviews.count-start)]} mutableCopy];if([key isEqual:@"feature"]&&self.homeCarousel){record[@"carousel"]=self.homeCarousel;if(self.homeCarouselPageControl)record[@"pages"]=self.homeCarouselPageControl;}self.homeModuleCache[key]=record;}
    else[self.homeModuleCache removeObjectForKey:key];
}
- (void)rebuildHomeModulesNow {
    CFTimeInterval rebuildStarted=CACurrentMediaTime();NSUInteger coalesced=self.pendingHomeRefreshCount;self.pendingHomeRefreshCount=0;
    if(!self.homeStack)return;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_modules_rebuild_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"home_mode":@(self.homeMode),@"source_item_count":@(self.items.count),@"category_count":@(self.homeCategories.count)}];CGPoint previousOffset=self.homeScroll.contentOffset;BOOL preserveOffset=self.homeScroll.bounds.size.height>0;__weak typeof(self) weakSelf=self;self.homeCarousel.delegate=nil;self.homeCarousel=nil;self.homeCarouselPageControl=nil;for(UIView *view in self.homeStack.arrangedSubviews.copy){if(view==self.homeStatusCard)continue;[self.homeStack removeArrangedSubview:view];[view removeFromSuperview];}[self updateHomeStatusCard];
    NSSet *enabled=MediaHomeEnabledModules();
    if(![enabled isEqual:self.cachedHomeModules]){[self.homeModuleCache removeAllObjects];self.cachedHomeModules=enabled;}
    if([enabled containsObject:@"recommendations"]){NSString *featuredProvider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&featuredProvider];NSArray *featured=[home[@"items"] isKindOfClass:NSArray.class]?home[@"items"]:@[];[self appendHomeModule:@"feature" signature:@[featured,featuredProvider?:@"",self.source?:@{}] build:^{if(featured.count)[self addHomeFeatureCarousel:featured source:self.source provider:featuredProvider];}];}
    if([enabled containsObject:@"catalog"])[self appendHomeModule:@"catalog" signature:[self homeCategoryModuleSignature] build:^{[self addHomeCategoryShelves:enabled];}];
    if([enabled containsObject:@"recommendations"]){NSString *cachedProvider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&cachedProvider];NSArray *recommendations=[home[@"items"] isKindOfClass:NSArray.class]?home[@"items"]:@[];NSString *sourceName=[self.source[@"name"] isKindOfClass:NSString.class]?self.source[@"name"]:@"影视来源";
        if(!recommendations.count){[self.homeStack addArrangedSubview:[self homeSectionHeader:@"影视推荐" actionTitle:self.source?@"打开影视库":@"导入资源" selector:self.source?@selector(browseRecommendations):@selector(openResources)]];UIButton *empty=[self homeActionButton:self.source?([NSString stringWithFormat:@"%@ · 进入影视库加载推荐",sourceName]):@"添加影视资源后浏览推荐" symbol:self.source?@"sparkles.tv":@"plus" action:self.source?@selector(browseRecommendations):@selector(openResources) primary:NO];empty.accessibilityIdentifier=@"media-home-recommendations-empty";[self.homeStack addArrangedSubview:empty];}}
    if([enabled containsObject:@"continue"]){[self appendHomeModule:@"continue" signature:MediaPlaybackStateStore.watchHistory build:^{NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *entry in MediaPlaybackStateStore.watchHistory){if([entry[@"completed"] boolValue]||[entry[@"position"] doubleValue]<=0)continue;NSDictionary *item=entry[@"item"]?:@{};NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",entry[@"episodeName"]?:@"继续观看",entry[@"sourceName"]?:@"本机记录"];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"继续观看" subtitle:subtitle imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHistoryEntry:entry];}]];if(cards.count>=10)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"继续观看" actionTitle:@"全部" selector:@selector(openHistory)]];[self addHomeCards:cards emptyText:@"还没有未看完的影片，开始播放后会显示在这里"];
    }];}
    if([enabled containsObject:@"favorites"]){[self appendHomeModule:@"favorites" signature:[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{} build:^{NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};NSArray *entries=[saved.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[a[@"item"][@"name"] description] localizedStandardCompare:[b[@"item"][@"name"] description]];}];NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *entry in entries){NSDictionary *item=entry[@"item"]?:@{};NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",entry[@"sourceName"]?:@"影视资源",entry[@"provider"]?:@"站点"];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"已收藏影片" subtitle:subtitle imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHomeFavorite:entry];}]];if(cards.count>=10)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"影视收藏" actionTitle:@"全部" selector:@selector(openFavorites)]];[self addHomeCards:cards emptyText:@"还没有收藏影片，打开影片详情后点按收藏"];
    }];}
    if([enabled containsObject:@"sources"]){NSMutableSet *pins=[MediaHomePinnedSources() mutableCopy];if(![NSUserDefaults.standardUserDefaults objectForKey:MediaHomePinnedSourcesDefaultsKey]&&self.sources.count){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];if(saved.length)[pins addObject:saved];else for(NSDictionary *source in [self.sources subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)3,self.sources.count))])[pins addObject:source[@"id"]?:@""];[NSUserDefaults.standardUserDefaults setObject:pins.allObjects forKey:MediaHomePinnedSourcesDefaultsKey];}
        NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *source in self.sources){NSString *sourceID=source[@"id"]?:@"";if(![pins containsObject:sourceID])continue;BOOL running=MediaSourceUsesNativeCatalogAPI(source)||[PyHost isRunningServiceIdentifier:sourceID];NSString *engine=source[@"engine"]?:@"影视资源";NSString *subtitle=running?([source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"可直接访问"):engine;[cards addObject:[self homeCardWithTitle:source[@"name"]?:@"影视来源" subtitle:subtitle imageURL:nil symbol:@"square.stack.3d.up" action:^{[weakSelf browsePinnedSource:source];}]];if(cards.count>=12)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"固定来源" actionTitle:@"管理" selector:@selector(openHomeConfiguration)]];[self addHomeCards:cards emptyText:self.sources.count?@"还没有固定来源，点按右上角配置首页添加":@"尚未导入影视资源。可先到资源页导入 Python、JavaScript 或 ZIP 影视包"];
    }
    if(!enabled.count){UILabel *empty=[UILabel new];empty.text=@"首页模块已全部隐藏。使用“配置首页”选择要显示的内容。";empty.textColor=HostSecondaryText();empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];[self.homeStack addArrangedSubview:empty];}
    if(!self.sources.count){UIButton *import=[self homeActionButton:@"导入影视资源" symbol:@"plus" action:@selector(openResources) primary:NO];[self.homeStack addArrangedSubview:import];}
    if(preserveOffset){[self.homeScroll layoutIfNeeded];CGFloat minimum=-self.homeScroll.adjustedContentInset.top;CGFloat maximum=MAX(minimum,self.homeScroll.contentSize.height-self.homeScroll.bounds.size.height+self.homeScroll.adjustedContentInset.bottom);self.homeScroll.contentOffset=CGPointMake(previousOffset.x,MIN(MAX(previousOffset.y,minimum),maximum));}[self restoreHomeScrollOffsetIfNeeded];[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_modules_rebuild_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"home_mode":@(self.homeMode),@"module_view_count":@(self.homeStack.arrangedSubviews.count),@"source_item_count":@(self.items.count),@"elapsed_us":@((NSInteger)(MAX(0,CACurrentMediaTime()-rebuildStarted)*1000000)),@"coalesced_requests":@(coalesced)}];
}
- (void)openGlobalSearchFromHome {[self openGlobalSearch];}
- (void)browseRecommendations {[self showBrowse:YES];}
- (void)pushMediaDetail:(MediaDetailViewController *)detail {
    if(!detail)return;
    __weak typeof(self) weakSelf=self;
    detail.onReturnHome=^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner returnToHomeFromNavigation];[owner.navigationController popToViewController:owner animated:YES];};
    [self.navigationController pushViewController:detail animated:YES];
}
- (void)openHomeRecommendation:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    if(![item isKindOfClass:NSDictionary.class]||![source isKindOfClass:NSDictionary.class])return;
    if(MediaSourceUsesNativeCatalogAPI(source)){MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=self.onPlay;[self pushMediaDetail:detail];return;}
    self.pendingHomeDetail=@{@"item":item,@"source":source,@"provider":provider?:@""};self.pendingBrowseState=nil;[self activate:source keepingHome:YES];
}
- (void)browsePinnedSource:(NSDictionary *)source {self.pendingBrowseState=nil;self.provider=nil;self.nextHomeLoadTrigger=@"home_pinned_source";[self activate:source];}
- (void)openHomeConfiguration {
    MediaHomeConfigurationViewController *page=[MediaHomeConfigurationViewController new];page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];__weak typeof(self) weakSelf=self;page.onChange=^{[weakSelf refreshHomeModules];};UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];HostStyleNavigation(navigation);navigation.modalPresentationStyle=UIModalPresentationPageSheet;UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;}[self presentViewController:navigation animated:YES completion:nil];
}
- (void)openHomeFavorite:(NSDictionary *)entry {
    NSString *sourceID=entry[@"sourceID"]?:@"";NSDictionary *source=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:sourceID]){source=candidate;break;}
    if(!source){[self showMessage:@"该收藏对应的影视资源已移除，请重新导入后打开" loading:NO];return;}NSDictionary *item=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};NSString *provider=[entry[@"provider"] isKindOfClass:NSString.class]?entry[@"provider"]:@"";
    if(MediaSourceUsesNativeCatalogAPI(source)){MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider;detail.onPlay=self.onPlay;[self pushMediaDetail:detail];return;}
    self.pendingHomeDetail=@{@"item":item,@"source":source,@"provider":provider};self.pendingBrowseState=nil;[self activate:source keepingHome:YES];
}
- (void)openPendingHomeDetailForSource:(NSDictionary *)source provider:(NSString *)provider {
    NSDictionary *pending=self.pendingHomeDetail;if(![pending isKindOfClass:NSDictionary.class]||![[pending[@"source"][@"id"] description] isEqual:[source[@"id"] description]])return;
    NSDictionary *item=[pending[@"item"] isKindOfClass:NSDictionary.class]?pending[@"item"]:@{};MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=self.onPlay;self.pendingHomeDetail=nil;[self pushMediaDetail:detail];
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
        MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=entry[@"item"]?:@{};detail.source=source;detail.provider=entry[@"provider"]?:@"";detail.onPlay=owner.onPlay;[owner pushMediaDetail:detail];
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
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.resumeEntry=entry;detail.onPlay=self.onPlay;[self pushMediaDetail:detail];
}
- (void)openResources {if(self.onResources)self.onResources();}
- (void)openGlobalSearch {
    MediaGlobalSearchViewController *page=[MediaGlobalSearchViewController new];page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];page.onActivateService=self.onActivateService;__weak typeof(self) weakSelf=self;
    page.onSelectResult=^(NSDictionary *item,NSDictionary *source,NSString *provider){MediaBrowserViewController *owner=weakSelf;if(!owner)return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=owner.onPlay;[owner pushMediaDetail:detail];};
    [self.navigationController pushViewController:page animated:YES];
}
- (void)presentPicker:(MediaSourcePicker *)picker {
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker];HostStyleNavigation(navigation);navigation.navigationBar.prefersLargeTitles=NO;navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;}
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)loadSources {
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    if(!self.sources.count){self.source=nil;self.providers=@[];[self updateSelectionControls];[self refreshHomeModules];if(self.deferAutomaticLoading){self.homeLoadDeferred=YES;[self showMessage:@"尚未导入影视资源" loading:NO];}return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=self.sources.firstObject;for(NSDictionary *source in self.sources)if([source[@"id"] isEqual:saved])selected=source;
    self.source=selected;id savedHomeOffset=[NSUserDefaults.standardUserDefaults objectForKey:@"cctv.mediaHome.scrollOffset.v1"];self.pendingHomeOffsetRestore=[savedHomeOffset respondsToSelector:@selector(doubleValue)]?savedHomeOffset:nil;[self updateSelectionControls];
    if(self.deferAutomaticLoading){
        self.homeLoadDeferred=YES;NSString *cachedProvider=@"";NSDictionary *cached=[self cachedHomeResultForSelectedProvider:&cachedProvider];
        if(cached){self.provider=cachedProvider;[self applyHomeResult:cached];self.readinessStageLabel.text=@"已恢复本机缓存 · 尚未检查最新内容";[self showMessage:@"已恢复上次首页内容" loading:NO];[self updateSelectionControls];[RuntimeDiagnostics.shared recordEvent:@"media_home_cache_restored" category:@"media_api" fields:@{@"service_id":selected[@"id"]?:@"",@"provider_id":cachedProvider?:@"",@"item_count":@([cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0),@"category_count":@([cached[@"categories"] isKindOfClass:NSArray.class]?[cached[@"categories"] count]:0),@"network_load_deferred":@YES}];}
        else{self.readinessStageLabel.text=@"未发起网络请求";[self showMessage:@"首页内容尚未加载" loading:NO];}
        [self updateSelectionControls];
        [RuntimeDiagnostics.shared recordEvent:@"media_home_startup_load_deferred" category:@"media_api" fields:@{@"service_id":selected[@"id"]?:@"",@"provider_id":cachedProvider?:@"",@"cache_available":@(cached!=nil),@"cached_item_count":@([cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0),@"network_load_deferred":@YES}];
        [self refreshHomeModules];return;
    }
    self.homeLoadDeferred=NO;[self refreshHomeModules];if(MediaSourceUsesNativeCatalogAPI(selected)||[PyHost isRunningServiceIdentifier:selected[@"id"]])[self activate:selected keepingHome:YES];
}
- (void)loadHomeOnDemand {
    if(!self.homeLoadDeferred)return;
    if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"explicit_home_action";
    [RuntimeDiagnostics.shared recordEvent:@"media_home_user_load_requested" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"",@"cache_available":@(self.homeResult!=nil)}];
    self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;
    if(!self.source){[self loadSources];if(!self.source){self.nextHomeLoadTrigger=nil;[self openResources];return;}}
    BOOL native=MediaSourceUsesNativeCatalogAPI(self.source);BOOL runtimeActive=!native&&[PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""];
    if(!self.client&&runtimeActive)self.client=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];
    BOOL needsActivation=!self.client||!self.source[@"capabilities"]||self.sourceInvalidated||(!native&&!runtimeActive);
    if(needsActivation&&runtimeActive)[self checkCurrentService];else if(needsActivation)[self activate:self.source keepingHome:YES];else[self loadHome];
    [self updateHomeStatusCard];
}
- (void)invalidateServiceIdentifier:(NSString *)identifier {
    if(![self.source[@"id"] isEqual:identifier])return;
    [self saveCurrentBrowseState];self.sourceInvalidated=YES;self.generation++;[self.client cancel];[self.configurationClient cancel];[self.readiness cancel];self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.items=@[];self.providers=@[];self.provider=nil;[self.grid reloadData];[self updateSelectionControls];[self showMessage:@"此资源服务已停止。点按顶部资源重新选择，或在菜单中刷新后启动。" loading:NO];
}
- (void)refreshSources {
    NSArray<NSDictionary *> *updated=self.sourcesProvider?self.sourcesProvider():@[];
    self.sources=updated;
    if(!updated.count){
        self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.source=nil;[self clearHomeResult];self.provider=nil;self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.moreButton.hidden=YES;[self.grid reloadData];[self updateSelectionControls];[self refreshHomeModules];
        for(UIView *view in self.categories.arrangedSubviews.copy){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
        return;
    }
    if(self.homeMode){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];for(NSDictionary *candidate in updated)if(saved.length&&[candidate[@"id"] isEqual:saved]&&![candidate[@"id"] isEqual:self.source[@"id"]]){self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.loading=NO;self.homeShelfRequestInFlight=NO;self.source=candidate;[self clearHomeResult];self.provider=nil;self.providers=@[];self.items=@[];self.sourceInvalidated=NO;self.homeLoadDeferred=YES;[self.grid reloadData];[self updateSelectionControls];[self showMessage:@"影视来源已更新 · 点按加载首页" loading:NO];[self refreshHomeModules];return;}}
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:self.source[@"id"]]){BOOL changed=![(candidate[@"packageRoot"]?:@"") isEqual:(self.source[@"packageRoot"]?:@"")]||![(candidate[@"api"]?:@"") isEqual:(self.source[@"api"]?:@"")];self.source=candidate;if(self.homeMode){if(changed){self.generation++;[self.readiness cancel];[self.client cancel];self.client=nil;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.loading=NO;self.homeShelfRequestInFlight=NO;self.providers=@[];self.items=@[];self.homeCategories=@[];self.homeShelfGeneration=0;[self clearHomeResult];self.sourceInvalidated=NO;self.homeLoadDeferred=YES;[self showMessage:@"影视来源已更新 · 点按加载首页" loading:NO];} [self updateSelectionControls];[self refreshHomeModules];return;}if((self.sourceInvalidated||changed)&&MediaSourceUsesNativeCatalogAPI(candidate)){[self activate:candidate];return;}if((self.sourceInvalidated||changed)&&[PyHost isRunningServiceIdentifier:candidate[@"id"]]){[self activate:candidate];return;}if(changed)[self invalidateServiceIdentifier:candidate[@"id"]];[self updateSelectionControls];[self refreshHomeModules];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=updated.firstObject;
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:saved]){selected=candidate;break;}
    if(self.homeMode){self.generation++;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.readiness=nil;self.client=nil;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.loading=NO;self.homeShelfRequestInFlight=NO;self.source=selected;[self clearHomeResult];self.provider=nil;self.providers=@[];self.homeLoadDeferred=YES;[self updateSelectionControls];[self showMessage:@"影视来源已更新 · 请到资源页手动加载首页" loading:NO];[self refreshHomeModules];}
    else [self activate:selected];
}
- (void)returnToHomeFromNavigation { [self showHome:NO]; }
- (BOOL)refreshHomeContentFromResourcePage {
    self.nextHomeLoadTrigger=@"resource_page_refresh";
    [self showHome:NO];self.deferAutomaticLoading=YES;
    self.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];
    if(!self.sources.count){self.nextHomeLoadTrigger=nil;self.homeLoadDeferred=YES;[self showMessage:@"尚未导入影视资源，请先在资源页添加可用来源" loading:NO];return NO;}
    [self refreshSources];
    self.homeLoadDeferred=YES;
    [RuntimeDiagnostics.shared recordEvent:@"media_home_refresh_requested_from_resources" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_count":@(self.sources.count),@"cache_available":@(self.homeResult!=nil)}];
    [self loadHomeOnDemand];
    return YES;
}
- (void)openSourceIdentifier:(NSString *)identifier {
    NSString *targetID=[identifier isKindOfClass:NSString.class]?[identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(!targetID.length){[self showMessage:@"没有指定影视来源" loading:NO];return;}
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    NSDictionary *target=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:targetID]){target=candidate;break;}
    if(!target){[self updateSelectionControls];[self showMessage:@"此来源已从资源合集移除，请回到资源页重新选择" loading:NO];return;}
    [NSUserDefaults.standardUserDefaults setObject:targetID forKey:@"selectedMediaSource"];
    self.nextHomeLoadTrigger=@"resource_list_open";
    [self activate:target];
}
- (void)showMessage:(NSString *)message loading:(BOOL)loading {
    self.status.text=message?:@"";self.homeStatusLoading=loading;
    if(self.homeMode){self.status.hidden=YES;self.resourceButton.hidden=YES;[self.spinner stopAnimating];[self updateHomeStatusCard];return;}
    self.status.hidden=!message.length;self.resourceButton.hidden=loading || self.items.count>0;
    if(loading)[self.spinner startAnimating];else[self.spinner stopAnimating];
}
- (void)chooseResource {
    if(!self.sources.count){[self openResources];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *source in self.sources){BOOL current=[source[@"id"] isEqual:self.source[@"id"]];NSString *engineValue=[source[@"engine"] isKindOfClass:NSString.class]?source[@"engine"]:@"";NSString *engine=engineValue.lowercaseString;NSString *scope=([engine containsString:@"python"]||[engine containsString:@"py"])?@"python":([engine containsString:@"node"])?@"node":([engine containsString:@"javascript"]||[engine isEqual:@"js"])?@"javascriptcore":@"other";NSString *scopeName=[scope isEqual:@"python"]?@"Python":([scope isEqual:@"node"]?@"Node.js":([scope isEqual:@"javascriptcore"]?@"JavaScriptCore":@"其他"));NSString *status=[source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"已导入";NSString *name=[source[@"name"] isKindOfClass:NSString.class]?source[@"name"]:@"影视资源";NSString *url=[source[@"url"] isKindOfClass:NSString.class]?source[@"url"]:@"";NSString *subtitle=[NSString stringWithFormat:@"%@ · %@%@",scopeName,current?@"当前资源 · ":@"",status];[choices addObject:@{@"name":name,@"subtitle":subtitle,@"url":url,@"source":source,@"scope":scope,@"scopeName":scopeName,@"selected":@(current)}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"切换影视资源";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;NSDictionary *source=choice[@"source"];if(owner&&source){owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=@"resource_selector";if(owner.homeMode)[owner activate:source keepingHome:YES];else[owner activate:source];}};[self presentPicker:picker];
}
- (void)refreshCurrentSource {
    self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;
    [self.homeModuleCache removeAllObjects];
    if(!self.source){self.nextHomeLoadTrigger=nil;[self loadSources];return;}
    self.nextHomeLoadTrigger=@"toolbar_refresh";
    if(self.serviceUnavailable){[self checkCurrentService];return;}
    if(self.sourceInvalidated||(!MediaSourceUsesNativeCatalogAPI(self.source)&&![PyHost isRunningServiceIdentifier:self.source[@"id"]])){[self activate:self.source keepingHome:self.homeMode];return;}
    [self.client cancel];[self.configurationClient cancel];self.configurationClient=[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];
    NSString *sourceID=[self.source[@"id"] copy];self.loading=YES;[self showMessage:@"正在刷新资源配置与缓存…" loading:YES];__weak typeof(self) weakSelf=self;
    [self.configurationClient call:@"invalidate" arguments:@{} correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner||![owner.source[@"id"] isEqual:sourceID])return;if(error){owner.loading=NO;[owner showMessage:error.localizedDescription loading:NO];[owner updateSelectionControls];return;}[owner activate:owner.source keepingHome:owner.homeMode];}];
}
- (void)showConfigurationForSource:(NSDictionary *)source {self.openConfigurationWhenReady=YES;[self activate:source];}
- (void)pauseForBackground {
    if(!self.source)return;self.foregroundCheckNeeded=YES;self.generation++;
    if(self.homeMode)[self saveHomeScrollOffset];
    self.backgroundLoadInterrupted=self.loading||self.homeShelfRequestInFlight;
    [self.readiness cancelWithReason:@"app_backgrounded"];[self.client cancel];[self.configurationClient cancel];
    self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;
    self.resumeCancelledMediaRequestOnAppear=NO;
}
- (void)resumeAfterForeground {
    if(!self.foregroundCheckNeeded)return;
    self.foregroundCheckNeeded=NO;
    BOOL interrupted=self.backgroundLoadInterrupted;self.backgroundLoadInterrupted=NO;
    self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;
    if(interrupted){if(self.homeMode)self.homeLoadDeferred=YES;[self showMessage:self.homeMode?(self.homeResult?@"已保留首页内容；需要更新请到资源页手动刷新":@"上次加载已暂停；请到资源页手动加载"):@"已保留当前内容；需要时手动刷新" loading:NO];}
    else [self updateHomeStatusCard];
}
- (void)checkCurrentService {
    if(self.restartInProgress||self.loading||!self.source)return;
    if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground){self.foregroundCheckNeeded=YES;return;}
    self.foregroundCheckNeeded=NO;if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"service_check";
    if(MediaSourceUsesNativeCatalogAPI(self.source)){if(self.client)[self loadHome];return;}
    if(![PyHost isRunningServiceIdentifier:self.source[@"id"]]){[self activate:self.source keepingHome:self.homeMode];return;}
    [self.readiness cancelWithReason:@"new_connection_check"];[self.client cancel];self.homeShelfRequestInFlight=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;NSUInteger generation=++self.generation;
    self.loading=YES;self.readinessStageLabel.text=@"运行会话活跃 · 正在重新检查 HTTP";
    [self showMessage:@"正在检查本机服务连接 · 保留当前内容" loading:YES];
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",self.source[@"port"]]];
    self.readiness=[[LocalServiceReadiness alloc] initWithURL:url timeout:4 requiresHealthJSON:YES];
    self.readiness.diagnosticContext=@{@"service_id":self.source[@"id"]?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"trigger":@"recheck"};
    __weak typeof(self) weakSelf=self;
    [self.readiness start:^(NSError *error,NSTimeInterval elapsed){MediaBrowserViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;
        owner.loading=NO;NSDictionary *probe=owner.readiness.diagnosticSummary;
        if(error&&[probe[@"last_observed_failure_kind"] isEqual:@"runtime_preparing"]){[owner activate:owner.source keepingHome:owner.homeMode];return;}
        owner.serviceUnavailable=error!=nil;
        owner.readinessStageLabel.text=error?@"运行会话活跃 · HTTP 健康检查未通过":@"HTTP 健康检查通过";
        NSString *reason=[probe[@"last_error_code"] integerValue]==NSURLErrorCannotConnectToHost?@"本机端口拒绝连接":([probe[@"last_http_status"] integerValue]>0?[NSString stringWithFormat:@"服务返回 HTTP %@，健康检查未通过",probe[@"last_http_status"]]:@"本机服务连接超时或响应无效");
        [owner showMessage:error?[reason stringByAppendingString:@"。当前内容已保留，可重新检查或重启此服务。"]:@"" loading:NO];
        if(!error){
            if(![owner.source[@"capabilities"] count])[owner loadCapabilities];
            else if(owner.homeMode)[owner loadHome];
            else{[owner saveCurrentBrowseState];owner.pendingBrowseState=owner.browseStates[[owner stateKeyForSource:owner.source provider:owner.provider]];[owner restorePendingBrowseState];}
        }
    }];
}
- (void)restartCurrentService {
    if(!self.source||self.restartInProgress)return;
    if(MediaSourceUsesNativeCatalogAPI(self.source)||!self.onRestartService){[self showMessage:@"此来源无需本机服务重启，请刷新内容或查看资源配置。" loading:NO];return;}
    [self saveCurrentBrowseState];[self.readiness cancelWithReason:@"user_restart"];[self.client cancel];[self.configurationClient cancel];
    NSUInteger generation=++self.generation;NSDictionary *source=self.source;BOOL home=self.homeMode;self.restartInProgress=YES;self.loading=YES;
    [self showMessage:@"正在停止此服务并验证端口释放…" loading:YES];__weak typeof(self) weakSelf=self;
    self.onRestartService(source,^(NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.restartInProgress=NO;if(owner.generation!=generation)return;
        owner.loading=NO;if(error){owner.serviceUnavailable=YES;[owner showMessage:error.localizedDescription loading:NO];return;}
        owner.serviceUnavailable=NO;[owner activate:source keepingHome:home];
    });
}
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
    if(!self.source){[self openResources];return;}
    if(MediaSourceUsesNativeCatalogAPI(self.source)){[self showMessage:@"此资源使用单站点接口，没有可切换的站点列表" loading:NO];return;}
    if(self.pendingProviderPickerAfterLoad&&self.loading){[self showMessage:@"正在准备当前资源并读取站点列表，请稍候" loading:YES];return;}
    if(!self.providers.count){
        NSArray *capabilities=[self.source[@"capabilities"] isKindOfClass:NSArray.class]?self.source[@"capabilities"]:@[];
        if(!capabilities.count||[capabilities containsObject:@"providers"]||!self.client||self.sourceInvalidated){
            self.pendingProviderPickerAfterLoad=YES;
            self.nextHomeLoadTrigger=@"site_selector_prepare";
            [RuntimeDiagnostics.shared recordEvent:@"media_provider_selection_prepare_requested" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"",@"home_mode":@(self.homeMode)}];
            [self activate:self.source keepingHome:self.homeMode];
            return;
        }
        [self showMessage:@"此影视资源未提供可切换的站点列表" loading:NO];return;
    }
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *provider in self.providers){BOOL current=[provider[@"id"] isEqual:self.provider];[choices addObject:@{@"name":provider[@"name"]?:provider[@"id"]?:@"影视站点",@"subtitle":current?@"当前平台":(self.source[@"name"]?:@"当前影视资源"),@"provider":provider[@"id"]?:@"",@"selected":@(current)}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"切换影视平台";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner||![choice[@"provider"] length]||[owner.provider isEqual:choice[@"provider"]])return;[owner saveCurrentBrowseState];owner.provider=choice[@"provider"];NSString *sourceID=owner.source[@"id"]?:@"";[NSUserDefaults.standardUserDefaults setObject:owner.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",sourceID]];NSString *providerName=[choice[@"name"] isKindOfClass:NSString.class]?choice[@"name"]:@"";if(providerName.length)[NSUserDefaults.standardUserDefaults setObject:providerName forKey:[NSString stringWithFormat:@"mediaProviderName.%@",sourceID]];owner.pendingBrowseState=owner.browseStates[[owner stateKeyForSource:owner.source provider:owner.provider]];owner.nextHomeLoadTrigger=@"site_selection";[owner updateSelectionControls];[owner loadHome];};[self presentPicker:picker];
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
    [self activate:source keepingHome:NO];
}
- (void)activate:(NSDictionary *)source keepingHome:(BOOL)keepingHome {
    if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"source_activation";
    self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;self.homeMode=keepingHome;self.title=keepingHome?@"":@"影视库";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.navigationItem.searchController=keepingHome?nil:self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;[self setBrowseControlsHidden:keepingHome];[self notifyDisplayModeChanged];
    if(self.pendingHomeDetail&&![self.pendingHomeDetail[@"source"][@"id"] isEqual:source[@"id"]])self.pendingHomeDetail=nil;
    self.sourceInvalidated=NO;self.serviceUnavailable=NO;self.capabilityReadinessRetryCount=0;[self saveCurrentBrowseState];self.generation++;NSUInteger generation=self.generation;self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeShelfRequestInFlight=NO;self.activeMediaRequestAppend=NO;self.resumeCancelledMediaRequestOnAppear=NO;self.cancelledMediaOperation=nil;self.cancelledMediaRequestWasAppend=NO;self.source=source;[self clearHomeResult];self.homeCategories=@[];self.homeShelfGeneration=0;NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",source[@"id"]]];self.provider=nil;self.pendingBrowseState=self.browseStates[[self stateKeyForSource:source provider:preferredProvider]]?:self.browseStates[[self stateKeyForSource:source provider:nil]];self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.page=1;self.loading=YES;self.moreButton.hidden=YES;[self.grid reloadData];
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
        if(error){owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=nil;owner.readinessStageLabel.text=@"启动失败 · HTTP 健康状态未知";[RuntimeDiagnostics.shared recordEvent:@"media_source_activation_failed" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"port":owner.source[@"port"]?:@0, @"engine":owner.source[@"engine"]?:@"unknown", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.loading=NO;[owner updateSelectionControls];[owner showMessage:error.localizedDescription loading:NO];return;}
        owner.readinessStageLabel.text=@"启动请求已接受 · 等待 HTTP 健康检查";[owner showMessage:@"启动请求已接受 · 等待本机服务响应" loading:YES];[RuntimeDiagnostics.shared recordEvent:@"media_runtime_start_request_accepted" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown"}];
        NSURL *health=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",source[@"port"]]];
        owner.readiness=[[LocalServiceReadiness alloc] initWithURL:health timeout:45 requiresHealthJSON:YES];
        owner.readiness.diagnosticContext=@{@"service_id":source[@"id"]?:@"",@"correlation_id":owner.diagnosticTraceID?:@"",@"trigger":@"activate"};
        NSError *(^startupProvider)(NSDictionary *)=[owner.startupErrorForService copy];
        owner.readiness.failureProvider=startupProvider?^NSError *{return startupProvider(source);}:owner.startupErrorProvider;
        [owner.readiness start:^(NSError *failure,NSTimeInterval elapsed){
            MediaBrowserViewController *page=weakSelf;if(!page || page.generation!=generation)return;
            NSMutableDictionary *probeFields=[@{@"correlation_id":page.diagnosticTraceID?:@"", @"port":page.source[@"port"]?:@0, @"engine":page.source[@"engine"]?:@"unknown", @"elapsed_ms":@((NSInteger)(elapsed*1000))} mutableCopy];[probeFields addEntriesFromDictionary:page.readiness.diagnosticSummary];
            if(failure){page.pendingProviderPickerAfterLoad=NO;page.nextHomeLoadTrigger=nil;page.serviceUnavailable=YES;page.readinessStageLabel.text=@"HTTP 健康检查失败 · 内容接口未读取";probeFields[@"error_domain"]=failure.domain?:@"";probeFields[@"error_code"]=@(failure.code);probeFields[@"error_message"]=failure.localizedDescription?:@"";[RuntimeDiagnostics.shared recordEvent:@"media_service_health_failed" category:@"service" fields:probeFields];page.loading=NO;[page updateSelectionControls];[page showMessage:failure.localizedDescription loading:NO];return;}
            [RuntimeDiagnostics.shared recordEvent:@"media_service_health_ready" category:@"service" fields:probeFields];
            page.readinessStageLabel.text=@"HTTP 健康检查通过 · 正在读取资源能力";[page showMessage:@"本机服务已响应 · 正在读取资源能力" loading:YES];
            [page loadCapabilities];
        }];
    };
    if(self.onActivateService)self.onActivateService(source,started);else started(nil);
}
- (NSDictionary *)arguments:(NSDictionary *)args {NSMutableDictionary *value=[args mutableCopy];if(self.provider.length)value[@"provider"]=self.provider;return value;}
- (void)loadCapabilities {
    NSUInteger generation=self.generation;NSString *sourceID=[self.source[@"id"] description]?:@"";self.activeMediaOperation=@"capabilities";self.readinessStageLabel.text=@"HTTP 健康通过 · 查询资源声明的接口能力";[self showMessage:@"HTTP 健康检查通过 · 正在查询资源能力" loading:YES];
    __weak typeof(self) weakSelf=self;
    [self.client call:@"capabilities" arguments:@{} correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner||owner.generation!=generation||![[owner.source[@"id"] description] isEqual:sourceID])return;if([owner.activeMediaOperation isEqualToString:@"capabilities"])owner.activeMediaOperation=nil;
        if(error){
            BOOL retryable=[error.userInfo[@"plugin_retryable"] boolValue];
            if(retryable&&owner.capabilityReadinessRetryCount<45){
                owner.capabilityReadinessRetryCount++;
                NSUInteger retry=owner.capabilityReadinessRetryCount;
                NSString *retryMessage=[NSString stringWithFormat:@"本机接口已监听 · 资源脚本正在准备（%lu/45）",(unsigned long)retry];owner.readinessStageLabel.text=retryMessage;[owner showMessage:retryMessage loading:YES];
                if(retry==1||retry%10==0)[RuntimeDiagnostics.shared recordEvent:@"media_runtime_preparing" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown",@"port":owner.source[@"port"]?:@0,@"retry_count":@(retry),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
                NSTimeInterval delay=retry<2?0.5:(retry<5?1.0:2.0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{MediaBrowserViewController *page=weakSelf;if(!page||page.generation!=generation||page.sourceInvalidated)return;[page loadCapabilities];});
                return;
            }
            if(retryable)[RuntimeDiagnostics.shared recordEvent:@"media_runtime_prepare_timeout" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown",@"port":owner.source[@"port"]?:@0,@"retry_count":@(owner.capabilityReadinessRetryCount),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];
            owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=nil;owner.readinessStageLabel.text=retryable?@"资源脚本准备超时 · 重新选择来源可重试":@"资源能力接口读取失败";owner.loading=NO;[owner updateSelectionControls];[owner showMessage:error.localizedDescription loading:NO];return;
        }
        owner.capabilityReadinessRetryCount=0;
        NSArray *caps=[result isKindOfClass:NSDictionary.class] && [result[@"capabilities"] isKindOfClass:NSArray.class]?result[@"capabilities"]:@[];
        [RuntimeDiagnostics.shared recordEvent:@"media_capabilities_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"capability_count":@(caps.count)}];
        NSMutableDictionary *saved=[owner.source mutableCopy];saved[@"capabilities"]=caps;[ServiceStore save:saved];owner.source=saved;
        if(owner.openConfigurationWhenReady){owner.openConfigurationWhenReady=NO;[owner openSourceConfiguration];}
        if([caps containsObject:@"live"] && ![caps containsObject:@"detail"] && ![caps containsObject:@"play"]){owner.loading=NO;owner.pendingHomeDetail=nil;owner.nextHomeLoadTrigger=nil;if(owner.pendingProviderPickerAfterLoad){owner.pendingProviderPickerAfterLoad=NO;[owner updateSelectionControls];[owner showMessage:@"这是直播资源，不提供影视站点列表" loading:NO];}else if(owner.onSubscribeLive)owner.onSubscribeLive(owner.source);else[owner showMessage:@"此资源提供直播频道，可添加到频道订阅" loading:NO];return;}
        if(owner.pendingProviderPickerAfterLoad && ![caps containsObject:@"providers"]){owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=nil;owner.loading=NO;[owner updateSelectionControls];[owner showMessage:@"此影视资源未提供可切换的站点列表" loading:NO];return;}
        if([caps containsObject:@"providers"]){owner.activeMediaOperation=@"providers";[owner.client call:@"providers" arguments:@{} correlationID:owner.diagnosticTraceID completion:^(id providers,NSError *failure){MediaBrowserViewController *page=weakSelf;if(!page||page.generation!=generation||![[page.source[@"id"] description] isEqual:sourceID])return;if([page.activeMediaOperation isEqualToString:@"providers"])page.activeMediaOperation=nil;if(failure){page.pendingProviderPickerAfterLoad=NO;page.nextHomeLoadTrigger=nil;page.loading=NO;[page showMessage:[NSString stringWithFormat:@"站点列表加载失败：%@",failure.localizedDescription] loading:NO];[page updateSelectionControls];return;}page.providers=[providers isKindOfClass:NSArray.class]?providers:@[];if(!page.providers.count){page.pendingProviderPickerAfterLoad=NO;page.nextHomeLoadTrigger=nil;page.loading=NO;[page showMessage:@"资源已启动，但没有可用影视站点。请打开“源配置与账号”检查配置，再刷新。" loading:NO];[page updateSelectionControls];return;}NSDictionary *resume=page.pendingHistoryEntry;BOOL openingHistory=resume&&[resume[@"sourceID"] isEqual:page.source[@"id"]];NSString *requestedDetailProvider=[page.pendingHomeDetail[@"provider"] isKindOfClass:NSString.class]?page.pendingHomeDetail[@"provider"]:@"";NSString *savedProvider=page.pendingBrowseState[@"provider"];NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",page.source[@"id"]]];NSString *chosen=page.pendingProviderPickerAfterLoad?@"":(openingHistory?resume[@"provider"]:(requestedDetailProvider.length?requestedDetailProvider:(savedProvider.length?savedProvider:preferredProvider)));BOOL found=NO;for(NSDictionary *candidate in page.providers)if([candidate[@"id"] isEqual:chosen]){found=YES;break;}if(chosen.length&&!found){page.pendingProviderPickerAfterLoad=NO;page.nextHomeLoadTrigger=nil;page.provider=nil;page.loading=NO;[page updateSelectionControls];page.pendingHistoryEntry=nil;if(requestedDetailProvider.length)page.pendingHomeDetail=nil;[page showMessage:openingHistory?@"这条记录对应的站点已从资源中移除。请选择其他站点重新查找影片.":(requestedDetailProvider.length?@"该影片对应的站点已不可用，请重新选择来源后查找。":@"之前选择的站点已失效，请点按顶部站点按钮重新选择") loading:NO];return;}page.provider=found?chosen:page.providers.firstObject[@"id"];if(page.provider){NSString *sourceID=[page.source[@"id"] description]?:@"";[NSUserDefaults.standardUserDefaults setObject:page.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",sourceID]];for(NSDictionary *candidate in page.providers)if([candidate[@"id"] isEqual:page.provider]){NSString *providerName=[candidate[@"name"] isKindOfClass:NSString.class]?candidate[@"name"]:@"";if(providerName.length)[NSUserDefaults.standardUserDefaults setObject:providerName forKey:[NSString stringWithFormat:@"mediaProviderName.%@",sourceID]];break;}}if(page.pendingBrowseState.count){NSMutableDictionary *state=[page.pendingBrowseState mutableCopy];state[@"provider"]=page.provider?:@"";page.pendingBrowseState=state;}[page updateSelectionControls];if(page.pendingProviderPickerAfterLoad){page.pendingProviderPickerAfterLoad=NO;page.loading=NO;page.nextHomeLoadTrigger=nil;[page updateSelectionControls];[page showMessage:@"站点列表已就绪，请选择影视站点" loading:NO];[page chooseProvider];return;}[page loadHome];if(openingHistory){page.pendingHistoryEntry=nil;[page openHistoryDetail:resume source:page.source provider:page.provider?:@""];}[page openPendingHomeDetailForSource:page.source provider:page.provider?:@""]; }];}
        else if([caps containsObject:@"home"]){owner.provider=@"";[owner loadHome];NSDictionary *resume=owner.pendingHistoryEntry;if(resume&&[resume[@"sourceID"] isEqual:owner.source[@"id"]]){owner.pendingHistoryEntry=nil;[owner openHistoryDetail:resume source:owner.source provider:@""];}[owner openPendingHomeDetailForSource:owner.source provider:@""];}
        else{owner.nextHomeLoadTrigger=nil;owner.loading=NO;if(owner.pendingBrowseState){NSDictionary *pending=owner.pendingBrowseState;[owner restorePendingBrowseState];if(![pending[@"keyword"] length])[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];}else[owner showMessage:[caps containsObject:@"search"]?@"输入关键词搜索此影视来源":@"此资源未提供影视首页，请在资源页查看能力与配置" loading:NO];if([caps containsObject:@"detail"])[owner openPendingHomeDetailForSource:owner.source provider:owner.provider?:@""];else owner.pendingHomeDetail=nil;}
    }];
}
- (void)loadHome {
    NSString *trigger=self.nextHomeLoadTrigger.length?self.nextHomeLoadTrigger:@"unspecified";
    NSDictionary *requestedSource=[self.source copy]?:@{};
    NSString *requestedSourceID=[requestedSource[@"id"] isKindOfClass:NSString.class]?requestedSource[@"id"]:@"";
    NSString *requestedProvider=[self.provider isKindOfClass:NSString.class]?self.provider:@"";
    BOOL sameRequestInFlight=self.loading&&[self.activeMediaOperation isEqualToString:@"home"]&&[self.activeHomeRequestSourceID isEqualToString:requestedSourceID]&&[self.activeHomeRequestProviderID isEqualToString:requestedProvider];
    self.nextHomeLoadTrigger=nil;
    if(sameRequestInFlight){[RuntimeDiagnostics.shared recordEvent:@"media_home_duplicate_request_suppressed" category:@"media_api" fields:@{@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"trigger":trigger,@"reason":@"same_resource_site_request_in_flight"}];return;}
    NSUInteger generation=++self.generation;self.homeShelfGeneration=generation;
    self.homeShelfRequestInFlight=NO;self.activeMediaRequestAppend=NO;self.activeMediaOperation=@"home";
    self.activeHomeRequestSourceID=requestedSourceID;self.activeHomeRequestProviderID=requestedProvider;
    self.filters=@{};self.selectedFilters=[NSMutableDictionary dictionary];
    BOOL hasProviderDirectory=[self.source[@"capabilities"] containsObject:@"providers"];
    self.readinessStageLabel.text=hasProviderDirectory?@"站点目录已读取 · 正在加载影视内容":@"资源能力已读取 · 正在加载影视内容";
    if(hasProviderDirectory)[RuntimeDiagnostics.shared recordEvent:@"media_provider_list_readable" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.source[@"id"]?:@"",@"provider_count":@(self.providers.count)}];
    self.loading=YES;[self updateSelectionControls];self.keyword=@"";self.category=nil;self.page=1;self.hasMore=NO;self.moreButton.hidden=YES;self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载推荐与分类…" loading:YES];
    NSDictionary *requestArguments=[self arguments:@{}];BOOL cacheStale=NO;id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:requestArguments maximumAge:6*3600 isStale:&cacheStale];NSUInteger cachedItemCount=[cached isKindOfClass:NSDictionary.class]&&[cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0;CFTimeInterval requestStartedAt=CACurrentMediaTime();[RuntimeDiagnostics.shared recordEvent:@"media_home_request_started" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"generation":@(generation),@"trigger":trigger,@"home_mode":@(self.homeMode),@"automatic_load_deferred":@(self.deferAutomaticLoading||self.homeLoadDeferred),@"port":self.source[@"port"]?:@0,@"cache_hit":@([cached isKindOfClass:NSDictionary.class]),@"cache_stale":@(cacheStale),@"cached_item_count":@(cachedItemCount)}];
    if([cached isKindOfClass:NSDictionary.class]){[self applyHomeResult:cached];if(self.homeMode){[self refreshHomeModules];[self showMessage:cacheStale?@"正在更新 · 暂用缓存推荐":@"正在校验 · 显示上次推荐" loading:YES];}else[self showMessage:cacheStale?@"正在更新 · 暂用缓存推荐":@"正在校验 · 显示上次推荐" loading:YES];}
    __weak typeof(self) weakSelf=self;
    [self.client call:@"home" arguments:requestArguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;BOOL sameSource=[[owner.source[@"id"] description] isEqual:requestedSourceID];BOOL sameProvider=[(owner.provider?:@"") isEqual:requestedProvider];BOOL stillCurrentOperation=[owner.activeMediaOperation isEqualToString:@"home"];if(owner.generation!=generation||!sameSource||!sameProvider||!stillCurrentOperation){NSString *reason=owner.generation!=generation?@"superseded_generation":(!sameSource?@"source_changed":(!sameProvider?@"provider_changed":@"superseded_operation"));[RuntimeDiagnostics.shared recordEvent:@"media_home_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider":requestedProvider,@"generation":@(generation),@"current_generation":@(owner.generation),@"current_service_id":[owner.source[@"id"] description]?:@"",@"current_provider":owner.provider?:@"",@"current_operation":owner.activeMediaOperation?:@"",@"reason":reason}];return;}owner.activeMediaOperation=nil;owner.activeHomeRequestSourceID=nil;owner.activeHomeRequestProviderID=nil;owner.loading=NO;[owner updateSelectionControls];NSTimeInterval responseElapsed=MAX(0,CACurrentMediaTime()-requestStartedAt);[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil elapsed:responseElapsed];[RuntimeDiagnostics.shared recordEvent:@"media_home_response_received" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider":requestedProvider,@"generation":@(generation),@"elapsed_ms":@((NSInteger)(responseElapsed*1000)),@"item_count":@([result[@"items"] isKindOfClass:NSArray.class]?[result[@"items"] count]:0),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
        if(error){owner.readinessStageLabel.text=owner.items.count?@"内容接口失败 · 当前仍显示有界缓存":@"内容接口读取失败";[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存内容 · 更新失败：%@",error.localizedDescription]:error.localizedDescription loading:NO];return;}
        if(owner.keyword.length || owner.category.length){owner.page=1;[owner loadListing:NO];return;}
        [[MediaMetadataCache shared] storeResult:result forSource:owner.source operation:@"home" arguments:requestArguments];
        [owner applyHomeResult:result];
        if(owner.homeMode)[owner refreshHomeModules];
        if(owner.homeMode&&owner.homeCategories.count){owner.homeShelfGeneration=generation;[owner loadHomeShelves:owner.homeCategories index:0 generation:generation sourceID:requestedSourceID provider:requestedProvider];}
        BOOL recommendationsUnavailable=[result[@"recommendationsUnavailable"] isEqual:@YES];
        owner.readinessStageLabel.text=recommendationsUnavailable?@"分类已读取 · 推荐加载失败，可选择分类继续浏览":@"影视内容接口已读取 · 实际播放需以视频首帧确认";
        [RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(owner.items.count),@"operation":@"home"}];
        if(owner.pendingBrowseState){[owner restorePendingBrowseState];return;}
        [owner showMessage:owner.items.count?@"":(recommendationsUnavailable?@"推荐暂不可用，请选择分类或输入关键词搜索":@"选择分类或输入关键词搜索") loading:NO];
    }];
}
- (void)applyHomeResult:(NSDictionary *)result {
    NSUInteger renderSerial=++self.diagnosticGridApplySerial;self.diagnosticGridConfiguredSerial=0;self.diagnosticGridVisibleSerial=0;NSArray *incoming=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];NSArray *incomingCategories=[result[@"categories"] isKindOfClass:NSArray.class]?result[@"categories"]:@[];[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_data_apply_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"render_serial":@(renderSerial),@"item_count":@(incoming.count),@"category_count":@(incomingCategories.count),@"home_mode":@(self.homeMode)}];
    self.homeResult=[result isKindOfClass:NSDictionary.class]?[result copy]:nil;self.homeResultSourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:@"";self.homeResultProvider=self.provider?:@"";
    self.items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];[self.grid reloadData];
    self.homeCategories=[result[@"categories"] isKindOfClass:NSArray.class]?result[@"categories"]:@[];
    self.filters=[result[@"filters"] isKindOfClass:NSDictionary.class]?result[@"filters"]:@{};
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSDictionary *category in incomingCategories){if(![category isKindOfClass:NSDictionary.class])continue;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:category[@"name"] forState:UIControlStateNormal];HostStylePillButton(button,NO);button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];button.accessibilityIdentifier=category[@"id"];[button addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[self.categories addArrangedSubview:button];}
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_data_apply_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"render_serial":@(renderSerial),@"item_count":@(self.items.count),@"category_count":@(self.homeCategories.count),@"home_mode":@(self.homeMode)}];
}
- (void)selectCategory:(UIButton *)button {self.category=button.accessibilityIdentifier;self.selectedFilters=[NSMutableDictionary dictionary];self.keyword=@"";self.search.searchBar.text=@"";for(UIButton *item in self.categories.arrangedSubviews){BOOL selected=item==button;item.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:HostNeutralSurface();HostSetLayerBorderColor(item,selected?[HostAccent() colorWithAlphaComponent:0.42]:HostBorder());[item setTitleColor:selected?HostAccent():HostText() forState:UIControlStateNormal];}self.page=1;if(!self.loading)[self loadListing:NO];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *keyword=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.keyword=keyword;
    NSUInteger generation=++self.searchGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner || owner.searchGeneration!=generation || !owner.source || owner.loading)return;owner.page=1;if(keyword.length)[owner loadListing:NO];else if(!owner.category.length){owner.nextHomeLoadTrigger=@"search_reset";[owner loadHome];}});
}
- (void)loadMore {if(!self.loading && self.hasMore){self.page++;[self loadListing:YES];}}
- (void)loadListing:(BOOL)append {
    if(!self.source)return;if(!self.keyword.length && !self.category.length){self.nextHomeLoadTrigger=@"listing_reset";[self loadHome];return;}NSUInteger generation=self.generation;NSString *requestedSourceID=[[self.source[@"id"] description] copy]?:@"";NSString *requestedProvider=[self.provider copy]?:@"";self.loading=YES;[self updateSelectionControls];NSString *operation=self.keyword.length?@"search":@"category";NSString *requestedKeyword=self.keyword?:@"",*requestedCategory=self.category?:@"";
    self.readinessStageLabel.text=self.keyword.length?@"资源运行中 · 正在搜索影视内容":@"资源运行中 · 正在加载分类内容";
    self.activeMediaOperation=operation;self.activeMediaRequestAppend=append;NSInteger requestedPage=self.page;
    NSMutableDictionary *args=[[self arguments:@{@"page":@(self.page)}] mutableCopy];if(self.keyword.length)args[@"keyword"]=self.keyword;else args[@"categoryId"]=self.category?:@"";
    NSInteger episode=self.widgetEpisode,season=self.widgetSeason;if([self.source[@"protocol"] isEqual:@"widget-extractor"]){args[@"episode"]=@(MAX(1,episode));args[@"season"]=@(MAX(1,season));}
    args[@"filters"]=self.selectedFilters?:@{};NSDictionary *requestedFilters=[self.selectedFilters copy]?:@{};
    BOOL hadCachedResult=NO;BOOL cacheStale=NO;NSUInteger cachedItemCount=0;
    if(!append){id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:operation arguments:args maximumAge:6*3600 isStale:&cacheStale];if([cached isKindOfClass:NSDictionary.class]){hadCachedResult=YES;self.items=[cached[@"items"] isKindOfClass:NSArray.class]?cached[@"items"]:@[];cachedItemCount=self.items.count;self.hasMore=[cached[@"hasMore"] boolValue];self.moreButton.hidden=!self.hasMore;[self.grid reloadData];[self showMessage:cacheStale?@"正在更新 · 暂用缓存结果":@"正在校验 · 显示上次结果" loading:YES];}}
    if(!append&&!hadCachedResult){self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载…" loading:YES];}self.moreButton.enabled=NO;
    CFTimeInterval requestStartedAt=CACurrentMediaTime();[RuntimeDiagnostics.shared recordEvent:@"media_listing_request_started" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"request_generation":@(generation),@"page":@(requestedPage),@"append":@(append),@"cache_hit":@(hadCachedResult),@"cache_stale":@(cacheStale),@"cached_item_count":@(cachedItemCount),@"search_term_length":@(requestedKeyword.length),@"has_category":@(requestedCategory.length>0),@"filter_count":@(requestedFilters.count)}];__weak typeof(self) weakSelf=self;
    [self.client call:operation arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;if(owner.generation!=generation||![[owner.source[@"id"] description] isEqual:requestedSourceID]||![(owner.provider?:@"") isEqual:requestedProvider]){[RuntimeDiagnostics.shared recordEvent:@"media_listing_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":owner.generation!=generation?@"superseded_generation":(![[owner.source[@"id"] description] isEqual:requestedSourceID]?@"source_changed":@"provider_changed")}];return;}if([owner.activeMediaOperation isEqualToString:operation])owner.activeMediaOperation=nil;owner.activeMediaRequestAppend=NO;owner.loading=NO;[owner updateSelectionControls];owner.moreButton.enabled=YES;[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil elapsed:MAX(0,CACurrentMediaTime()-requestStartedAt)];
        if(episode!=owner.widgetEpisode || season!=owner.widgetSeason || ![requestedKeyword isEqualToString:owner.keyword?:@""] || (!requestedKeyword.length && (![requestedCategory isEqualToString:owner.category?:@""] || ![requestedFilters isEqual:owner.selectedFilters?:@{}]))){[RuntimeDiagnostics.shared recordEvent:@"media_listing_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"operation":operation,@"request_generation":@(generation),@"requested_page":@(requestedPage),@"current_page":@(owner.page),@"reason":@"search_category_or_filter_changed"}];owner.page=1;[owner loadListing:NO];return;}
        NSInteger elapsedMS=(NSInteger)(MAX(0,CACurrentMediaTime()-requestStartedAt)*1000);
        if(error){[RuntimeDiagnostics.shared recordEvent:@"media_listing_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"page":@(requestedPage),@"append":@(append),@"elapsed_ms":@(elapsedMS),@"retained_cached_items":@(owner.items.count),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];owner.readinessStageLabel.text=owner.items.count?@"搜索接口失败 · 当前仍显示有界缓存":@"影视内容接口读取失败";if(append)owner.page=MAX(1,owner.page-1);[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存结果 · 更新失败：%@",error.localizedDescription]:error.localizedDescription loading:NO];return;}
        if(!append)[[MediaMetadataCache shared] storeResult:result forSource:owner.source operation:operation arguments:args];
        NSArray *incoming=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];
        NSMutableArray *all=append?[owner.items mutableCopy]:[NSMutableArray array];NSMutableSet *ids=[NSMutableSet set];for(NSDictionary *item in all)[ids addObject:item[@"id"]];for(NSDictionary *item in incoming)if(![ids containsObject:item[@"id"]]){[all addObject:item];[ids addObject:item[@"id"]];}
        owner.items=all;owner.readinessStageLabel.text=@"影视内容接口已读取 · 实际播放需以视频首帧确认";[RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(all.count),@"operation":operation}];[RuntimeDiagnostics.shared recordEvent:@"media_listing_result_applied" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"page":@(requestedPage),@"append":@(append),@"incoming_count":@(incoming.count),@"displayed_count":@(all.count),@"has_more":@([result[@"hasMore"] boolValue]),@"elapsed_ms":@(elapsedMS)}];if(owner.pendingRestorePage>requestedPage && [result[@"hasMore"] boolValue] && incoming.count && requestedPage<owner.pendingRestorePage){owner.page=requestedPage+1;[owner loadListing:YES];return;}if(owner.pendingRestorePage){owner.page=requestedPage;owner.pendingRestorePage=0;}owner.hasMore=[result[@"hasMore"] boolValue];owner.moreButton.hidden=!owner.hasMore;[owner.grid reloadData];[owner showMessage:all.count?@"":@"没有找到影片，请更换关键词或分类" loading:NO];
        if(owner.pendingRestoreOffset){CGFloat offset=owner.pendingRestoreOffset.doubleValue;owner.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[owner.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
    }];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return self.items.count;}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {NSInteger columns=collectionView.bounds.size.width>700?4:2;CGFloat width=floor((collectionView.bounds.size.width-28-(columns-1)*10)/columns);UIFont *name=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection],*remarks=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11] compatibleWithTraitCollection:self.traitCollection];return CGSizeMake(width,width*1.4+10+ceil(name.lineHeight)+ceil(remarks.lineHeight));}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    MediaPosterCell *cell=(MediaPosterCell *)[collectionView dequeueReusableCellWithReuseIdentifier:@"movie" forIndexPath:ip];
    BOOL firstCellForRender=self.diagnosticGridConfiguredSerial!=self.diagnosticGridApplySerial;if(firstCellForRender){self.diagnosticGridConfiguredSerial=self.diagnosticGridApplySerial;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_cell_configuration_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"render_serial":@(self.diagnosticGridApplySerial),@"item_index":@(ip.item),@"item_count":@(self.items.count)}];}
    [cell configureWithItem:self.items[ip.item]];
    if(firstCellForRender)[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_cell_configuration_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"render_serial":@(self.diagnosticGridApplySerial),@"item_index":@(ip.item),@"item_count":@(self.items.count)}];
    return cell;
}
- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if(self.diagnosticGridVisibleSerial==self.diagnosticGridApplySerial)return;self.diagnosticGridVisibleSerial=self.diagnosticGridApplySerial;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_first_cell_will_display" fields:@{@"service_id":self.source[@"id"]?:@"",@"render_serial":@(self.diagnosticGridApplySerial),@"item_index":@(indexPath.item),@"item_count":@(self.items.count),@"home_mode":@(self.homeMode)}];
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    HostAnimateSelection([collectionView cellForItemAtIndexPath:ip]);
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=self.items[ip.item];detail.source=self.source;detail.provider=self.provider;detail.onPlay=self.onPlay;[self pushMediaDetail:detail];
}
@end
