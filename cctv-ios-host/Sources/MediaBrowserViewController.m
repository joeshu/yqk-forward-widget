#import "MediaBrowserViewController.h"
#import "MediaFeedView.h"
#import "MediaAPIClient.h"
#import "HostImageLoader.h"
#import "HostTheme.h"
#import "MediaEpisodeLayout.h"
#import "HostToolbar.h"
#import "LocalServiceReadiness.h"
#import "ServiceStore.h"
#import "MediaEpisodeSelectionViewController.h"
#import "RuntimeDiagnostics.h"
#import "MediaWebViewController.h"
#import "MediaPlaybackStateStore.h"
#import "MediaPlaybackViewController.h"
#import "MediaMetadataCache.h"
#import "MediaGlobalSearchViewController.h"
#import "MediaSourceHealthStore.h"
#import "TVBoxCatalogStore.h"
#import "PyHost.h"
#import <float.h>
#import <math.h>
#import <QuartzCore/QuartzCore.h>

static void MediaLoadPosterWithRetry(NSString *url, UIImageView *imageView, NSUInteger retriesRemaining);
static void MediaLoadPosterWithRetry(NSString *url, UIImageView *imageView, NSUInteger retriesRemaining) {
    if(!url.length||!imageView)return;
    __weak UIImageView *weakImageView=imageView;
    [HostImageLoader.shared loadPosterURL:url intoImageView:imageView completion:^(BOOL succeeded,NSTimeInterval retryAfter){
        if(succeeded||!retriesRemaining||retryAfter<=0)return;
        NSTimeInterval delay=MIN(120.0,MAX(1.0,retryAfter+0.25));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            UIImageView *current=weakImageView;
            if(!current||!current.window||![current.accessibilityIdentifier isEqualToString:url])return;
            MediaLoadPosterWithRetry(url,current,retriesRemaining-1);
        });
    }];
}
// HostStylePillButton 会把标题字体写死为 14pt 固定字体；调用点再套一层按
// Dynamic Type 缩放的同字号字体，默认字号下外观不变。
static void MediaBrowserApplyScaledPillFont(UIButton *button) {
    button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
}

static NSArray<NSDictionary *> *MediaBrowserDictionaryRows(id rawRows, NSUInteger *discardedCount) {
    if(discardedCount)*discardedCount=0;
    if(![rawRows isKindOfClass:NSArray.class])return @[];
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray array];NSUInteger discarded=0;
    for(id row in (NSArray *)rawRows){if([row isKindOfClass:NSDictionary.class])[rows addObject:row];else discarded++;}
    if(discardedCount)*discardedCount=discarded;
    return rows;
}

static NSString *MediaBrowserItemIdentity(NSDictionary *item) {
    id identifier=item[@"id"];
    if(([identifier isKindOfClass:NSString.class]||[identifier isKindOfClass:NSNumber.class])&&[[identifier description] length])return [NSString stringWithFormat:@"id:%@",identifier];
    NSString *name=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"";
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";
    if(name.length||poster.length)return [NSString stringWithFormat:@"item:%lu:%@%lu:%@",(unsigned long)name.length,name,(unsigned long)poster.length,poster];
    return @"";
}

static BOOL MediaBrowserBoolean(id value) {
    if([value isKindOfClass:NSNumber.class])return [value boolValue];
    if([value isKindOfClass:NSString.class])return [value boolValue];
    return NO;
}

static BOOL MediaBrowserIdentityNameMatches(id value, NSString *savedName) {
    if(![value isKindOfClass:NSString.class]||![savedName isKindOfClass:NSString.class])return NO;
    NSString *candidate=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *saved=[savedName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return candidate.length&&saved.length&&[candidate localizedCaseInsensitiveCompare:saved]==NSOrderedSame;
}

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
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=self.screenTitle?:@"影视资源";self.shown=self.choices?:@[];self.selectedScope=@"*";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;self.tableView.tableFooterView=[UIView new];
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchResultsUpdater=self;self.search.searchBar.placeholder=([self.title containsString:@"平台"]||[self.title containsString:@"站点"])?@"搜索当前资源的站点":([self.title containsString:@"资源"]?@"搜索已导入资源":@"搜索选项");self.search.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closePicker)];
    [self configureScopes];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];UIView *header=self.tableView.tableHeaderView;if(header&&fabs(header.frame.size.width-self.tableView.bounds.size.width)>0.5){CGRect frame=header.frame;frame.size.width=self.tableView.bounds.size.width;header.frame=frame;self.tableView.tableHeaderView=header;} }
- (void)configureScopes {
    NSMutableOrderedSet<NSString *> *keys=[NSMutableOrderedSet orderedSet];for(NSDictionary *choice in self.choices){if(![choice isKindOfClass:NSDictionary.class])continue;NSString *key=[choice[@"scope"] isKindOfClass:NSString.class]?choice[@"scope"]:@"";if(key.length)[keys addObject:key];}self.scopeKeys=keys.array;
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),self.scopeKeys.count?52:8)];header.backgroundColor=UIColor.clearColor;
    if(self.scopeKeys.count){self.scopeScroll=[UIScrollView new];self.scopeScroll.translatesAutoresizingMaskIntoConstraints=NO;self.scopeScroll.showsHorizontalScrollIndicator=NO;self.scopeStack=[UIStackView new];self.scopeStack.translatesAutoresizingMaskIntoConstraints=NO;self.scopeStack.axis=UILayoutConstraintAxisHorizontal;self.scopeStack.spacing=8;[self.scopeScroll addSubview:self.scopeStack];[header addSubview:self.scopeScroll];[NSLayoutConstraint activateConstraints:@[[self.scopeScroll.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],[self.scopeScroll.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],[self.scopeScroll.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],[self.scopeScroll.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-4],[self.scopeStack.leadingAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.leadingAnchor],[self.scopeStack.trailingAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.trailingAnchor],[self.scopeStack.topAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.topAnchor],[self.scopeStack.bottomAnchor constraintEqualToAnchor:self.scopeScroll.contentLayoutGuide.bottomAnchor],[self.scopeStack.heightAnchor constraintEqualToAnchor:self.scopeScroll.frameLayoutGuide.heightAnchor]]];[self addScopeButton:@"*" title:[NSString stringWithFormat:@"全部 %lu",(unsigned long)self.choices.count]];for(NSString *key in self.scopeKeys){NSString *label=nil;for(NSDictionary *choice in self.choices)if([choice isKindOfClass:NSDictionary.class]&&[choice[@"scope"] isEqual:key]){label=[choice[@"scopeName"] isKindOfClass:NSString.class]?choice[@"scopeName"]:nil;break;}NSUInteger count=[[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){if(![choice isKindOfClass:NSDictionary.class])return NO;return [choice[@"scope"] isEqual:key];}]] count];[self addScopeButton:key title:[NSString stringWithFormat:@"%@ %lu",label.length?label:key,(unsigned long)count]];}}
    self.tableView.tableHeaderView=header;
}
- (void)addScopeButton:(NSString *)key title:(NSString *)title {UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.accessibilityIdentifier=key;button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];HostStylePillButton(button,[key isEqual:self.selectedScope]);MediaBrowserApplyScaledPillFont(button);[button setTitle:title forState:UIControlStateNormal];[button addTarget:self action:@selector(selectScope:) forControlEvents:UIControlEventTouchUpInside];[self.scopeStack addArrangedSubview:button];}
- (void)selectScope:(UIButton *)sender {self.selectedScope=sender.accessibilityIdentifier?:@"*";for(UIButton *button in self.scopeStack.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.selectedScope];HostStylePillButton(button,selected);MediaBrowserApplyScaledPillFont(button);}[self updateSearchResultsForSearchController:self.search];}
- (void)closePicker { [self.navigationController dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.shown.count;}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();if(!self.isViewLoaded)return;self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.tableView.separatorColor=HostSeparator();for(UIButton *button in self.scopeStack.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.selectedScope];HostStylePillButton(button,selected);MediaBrowserApplyScaledPillFont(button);}[self.tableView reloadData];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"source"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];NSDictionary *choice=index.row<self.shown.count?self.shown[index.row]:nil;if(![choice isKindOfClass:NSDictionary.class]){cell.textLabel.text=@"";cell.detailTextLabel.text=@"";cell.accessoryType=UITableViewCellAccessoryNone;return cell;}BOOL selected=[choice[@"selected"] isKindOfClass:NSNumber.class]?[choice[@"selected"] boolValue]:NO;cell.backgroundColor=selected?HostSelectedSurface():HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=selected?1.1:0.6;HostSetLayerBorderColor(cell,selected?HostAccent():HostBorder());cell.textLabel.text=[choice[@"name"] isKindOfClass:NSString.class]?choice[@"name"]:@"";cell.textLabel.textColor=selected?HostAccent():HostText();cell.textLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:15.5 weight:selected?UIFontWeightBold:UIFontWeightSemibold]];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=0;NSMutableArray *details=[NSMutableArray array];NSString *subtitle=[choice[@"subtitle"] isKindOfClass:NSString.class]?choice[@"subtitle"]:nil;if(subtitle.length)[details addObject:subtitle];NSString *url=[choice[@"url"] isKindOfClass:NSString.class]?choice[@"url"]:nil;if(url.length)[details addObject:url];cell.detailTextLabel.text=[details componentsJoinedByString:@"\n"];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12 weight:UIFontWeightRegular]];cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;cell.detailTextLabel.numberOfLines=0;cell.tintColor=HostAccent();cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {NSString *query=controller.searchBar.text?:@"";self.shown=[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){if(![choice isKindOfClass:NSDictionary.class])return NO;NSString *scope=[choice[@"scope"] isKindOfClass:NSString.class]?choice[@"scope"]:@"";if(![self.selectedScope isEqual:@"*"]&&![scope isEqual:self.selectedScope])return NO;BOOL matches=![query length];for(NSString *key in @[@"name",@"subtitle",@"url"]){NSString *value=[choice[key] isKindOfClass:NSString.class]?choice[key]:@"";if(query.length&&[value rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)matches=YES;}return matches;}]];if(!self.shown.count){UILabel *empty=[UILabel new];empty.text=query.length?@"没有匹配的选项，请修改或清除搜索词":@"当前分组暂无选项，请切换到全部";empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];empty.adjustsFontForContentSizeCategory=YES;empty.textColor=HostSecondaryText();empty.accessibilityIdentifier=@"media-picker-empty";self.tableView.backgroundView=empty;}else self.tableView.backgroundView=nil;[self.tableView reloadData];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {if(index.row<0||index.row>=self.shown.count)return;NSDictionary *choice=self.shown[index.row];if(![choice isKindOfClass:NSDictionary.class])return;void(^onSelect)(NSDictionary *)=self.onSelect;[self.navigationController dismissViewControllerAnimated:YES completion:^{if(onSelect)onSelect(choice);}];}
@end


@interface MediaDetailViewController : UIViewController
@property(nonatomic,copy) NSDictionary *item;
@property(nonatomic,copy) NSDictionary *source;
@property(nonatomic,copy) NSString *provider;
@property(nonatomic,copy) NSDictionary *detail;
@property(nonatomic,copy) NSDictionary *resumeEntry;
@property(nonatomic,strong) MediaAPIClient *client;
@property(nonatomic,copy) void (^onPlay)(NSDictionary *,NSDictionary *);
@property(nonatomic,copy) dispatch_block_t onPlaybackWillStart;
@property(nonatomic,copy) dispatch_block_t onReturnHome;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UIView *inlinePlaybackDock;
@property(nonatomic,strong) NSLayoutConstraint *inlinePlaybackDockTopConstraint;
@property(nonatomic) CGFloat activeNavigationSafeTop;
@property(nonatomic,strong) NSLayoutConstraint *detailScrollTopConstraint;
@property(nonatomic,strong) NSLayoutConstraint *inlinePlaybackScrollTopConstraint;
@property(nonatomic,strong) NSLayoutConstraint *inlinePlaybackDockHeightConstraint;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIImageView *posterView;
@property(nonatomic,strong) UIImageView *posterThumbnailView;
@property(nonatomic,strong) UIVisualEffectView *heroBlurView;
@property(nonatomic,strong) CAGradientLayer *heroGradient;
@property(nonatomic,strong) UIView *posterPlaceholder;
@property(nonatomic,strong) UIView *heroView;
@property(nonatomic,strong) UIView *heroSpacer;
@property(nonatomic,strong) UILabel *heroTitle;
@property(nonatomic,strong) UILabel *heroMetadata;
@property(nonatomic,strong) UILabel *metadataLabel;
@property(nonatomic,strong) UILabel *descriptionLabel;
@property(nonatomic,strong) UIButton *descriptionToggle;
@property(nonatomic,strong) UIButton *playButton;
@property(nonatomic,strong) UIButton *favoriteButton;
@property(nonatomic,strong) UIButton *parserButton;
@property(nonatomic,strong) UIStackView *parserRow;
@property(nonatomic,strong) UIStackView *routeButtons;
@property(nonatomic,strong) UIStackView *episodeGrid;
@property(nonatomic,strong) NSMutableArray<UIButton *> *episodeButtons;
@property(nonatomic,strong) UILabel *episodeTitle;
@property(nonatomic,strong) UILabel *pageLabel;
@property(nonatomic,strong) UIButton *previousPageButton;
@property(nonatomic,strong) UIButton *nextPageButton;
@property(nonatomic,strong) UIButton *episodeReverseButton;
@property(nonatomic) BOOL episodeOrderReversed;
@property(nonatomic,strong) MediaPlaybackViewController *inlinePlaybackController;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic) NSInteger selectedLineIndex;
@property(nonatomic) NSInteger selectedEpisodeIndex;
@property(nonatomic) NSInteger episodePage;
@property(nonatomic) BOOL descriptionExpanded;
@property(nonatomic) BOOL didAttemptServiceRecovery;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,copy) NSString *diagnosticTraceID;
- (void)loadDetail;
- (NSString *)safeDetailString:(id)value;
- (NSDictionary *)sanitizedDetail:(id)raw discardedLines:(NSUInteger *)discardedLines discardedEpisodes:(NSUInteger *)discardedEpisodes;
- (void)selectRoute:(UIButton *)sender;
- (void)selectParser;
- (void)updateParserSelectionButton;
- (NSString *)playbackParserCatalogID;
- (NSArray<NSDictionary *> *)availablePlaybackParsers;
- (NSString *)selectedPlaybackParserID;
- (void)selectEpisode:(UIButton *)sender;
- (void)shareTitle;
- (void)copyTitle;
- (void)scrollToEpisodes;
- (NSString *)posterURL;
- (void)restoreSelectionFromDetail:(NSDictionary *)previousDetail;
- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context;
- (void)updateInlinePlaybackDockLayout;
@end
static BOOL MediaDetailIsOpaqueIdentifierTitle(NSString *candidate, NSString *identifier) {
    NSString *cand = [candidate isKindOfClass:NSString.class] ? [candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSString *ident = [identifier isKindOfClass:NSString.class] ? [identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (!cand.length) return YES;
    NSString *low = cand.lowercaseString;
    if ([low hasPrefix:@"http://"] || [low hasPrefix:@"https://"]) return YES;
    if (ident.length && [cand caseInsensitiveCompare:ident] == NSOrderedSame &&
        [cand rangeOfString:@"^[A-Za-z0-9_.:/-]{6,128}$" options:NSRegularExpressionSearch].location != NSNotFound) {
        return YES;
    }
    if ([cand rangeOfString:@"^[A-Za-z0-9_-]{8,64}$" options:NSRegularExpressionSearch].location != NSNotFound &&
        [cand rangeOfString:@"[0-9]" options:NSRegularExpressionSearch].location != NSNotFound) {
        return YES;
    }
    return NO;
}
static NSString *MediaDetailPreferredTitle(NSString *detailName, NSString *itemName, NSString *itemID, NSString *synopsis) {
    NSString *dName = [detailName isKindOfClass:NSString.class] ? [detailName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSString *iName = [itemName isKindOfClass:NSString.class] ? [itemName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    NSString *ident = [itemID isKindOfClass:NSString.class] ? [itemID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (dName.length && !MediaDetailIsOpaqueIdentifierTitle(dName, ident)) return dName;
    if (iName.length && !MediaDetailIsOpaqueIdentifierTitle(iName, ident)) return iName;
    NSString *desc = [synopsis isKindOfClass:NSString.class] ? synopsis : @"";
    NSRange open = [desc rangeOfString:@"《"];
    if (open.location != NSNotFound && NSMaxRange(open) < desc.length) {
        NSRange close = [desc rangeOfString:@"》" options:0 range:NSMakeRange(NSMaxRange(open), desc.length - NSMaxRange(open))];
        if (close.location != NSNotFound && close.location > NSMaxRange(open) && close.location - NSMaxRange(open) <= 48) {
            NSString *extracted = [[desc substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (extracted.length) return extracted;
        }
    }
    return iName.length ? iName : dName;
}
@implementation MediaDetailViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithNibName:nil bundle:nil];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationBar *bar=self.navigationController.navigationBar;
    if(!bar)return;
    NSDictionary *titleAttributes=@{NSForegroundColorAttributeName:HostText(),NSFontAttributeName:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    UINavigationBarAppearance *scrolled=[UINavigationBarAppearance new];[scrolled configureWithDefaultBackground];scrolled.backgroundEffect=HostGlassBlur();scrolled.backgroundColor=HostGlassTint();scrolled.titleTextAttributes=titleAttributes;scrolled.largeTitleTextAttributes=titleAttributes;scrolled.shadowColor=UIColor.clearColor;
    UINavigationBarAppearance *edge=[UINavigationBarAppearance new];[edge configureWithTransparentBackground];edge.titleTextAttributes=titleAttributes;edge.largeTitleTextAttributes=titleAttributes;edge.backgroundColor=UIColor.clearColor;edge.shadowColor=UIColor.clearColor;
    bar.standardAppearance=scrolled;bar.scrollEdgeAppearance=edge;bar.compactAppearance=scrolled;if(@available(iOS 15.0,*))bar.compactScrollEdgeAppearance=edge;bar.translucent=YES;bar.tintColor=HostAccent();bar.prefersLargeTitles=NO;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if(!self.isMovingFromParentViewController)return;
    UINavigationController *navigation=self.navigationController;id<UIViewControllerTransitionCoordinator> transition=self.transitionCoordinator;
    void (^restoreNav)(void)=^{
        if(!navigation)return;
        BOOL targetHidesBar=navigation.navigationBarHidden||[navigation.topViewController isKindOfClass:NSClassFromString(@"MediaBrowserViewController")];
        HostStyleNavigation(navigation);
        if(targetHidesBar)navigation.navigationBar.prefersLargeTitles=NO;
    };
    if(transition)[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(!context.isCancelled)restoreNav();}];
    else restoreNav();
}
- (NSString *)safeDetailString:(id)value {
    if([value isKindOfClass:NSString.class]){
        NSString *str=(NSString *)value;
        NSString *low=str.lowercaseString;
        if([low containsString:@"[object object]"]||[low containsString:@"[object array]"]||[low containsString:@"[object undefined]"]||[low containsString:@"[object null]"]){
            str=[[[[str stringByReplacingOccurrencesOfString:@"[object Object]" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0,str.length)] stringByReplacingOccurrencesOfString:@"[object Array]" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0,str.length)] stringByReplacingOccurrencesOfString:@"[object Undefined]" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0,str.length)] stringByReplacingOccurrencesOfString:@"[object Null]" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0,str.length)];
            str=[[str stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ·/|-—,"]];
        }
        return str;
    }
    if([value isKindOfClass:NSNumber.class])return [value stringValue];
    return @"";
}
- (NSDictionary *)sanitizedDetail:(id)raw discardedLines:(NSUInteger *)discardedLines discardedEpisodes:(NSUInteger *)discardedEpisodes {
    if(discardedLines)*discardedLines=0;if(discardedEpisodes)*discardedEpisodes=0;
    if(![raw isKindOfClass:NSDictionary.class])return @{};
    NSMutableDictionary *clean=[(NSDictionary *)raw mutableCopy];
    NSSet<NSString *> *junkTokens=[NSSet setWithArray:@[@"url",@"null",@"nil",@"none",@"unknown",@"undefined",@"n/a",@"nan",@"[object object]",@"[object array]",@"{}",@"[]"]];
    NSSet<NSString *> *metaKeys=[NSSet setWithArray:@[@"year",@"area",@"lang",@"type",@"actor",@"director",@"remarks"]];
    for(NSString *key in @[@"id",@"name",@"year",@"area",@"lang",@"type",@"actor",@"director",@"description",@"remarks",@"poster",@"banner",@"vod_pic_slide",@"vod_pic",@"pic",@"cover",@"cover_url",@"coverUrl",@"image",@"img",@"thumbnail",@"thumb",@"poster_url",@"posterUrl"]){
        NSString *text=[self safeDetailString:raw[key]];
        NSString *trimmed=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *lowTrimmed=trimmed.lowercaseString;
        if([metaKeys containsObject:key]&&([junkTokens containsObject:lowTrimmed]||[lowTrimmed containsString:@"[object "]||[lowTrimmed hasPrefix:@"http://"]||[lowTrimmed hasPrefix:@"https://"]))text=@"";
        if(text.length)clean[key]=text;else [clean removeObjectForKey:key];
    }
    NSString *preferredTitle=MediaDetailPreferredTitle(clean[@"name"],[self safeDetailString:self.item[@"name"]],[self safeDetailString:self.item[@"id"]?:clean[@"id"]],clean[@"description"]);
    if(preferredTitle.length)clean[@"name"]=preferredTitle;
    NSMutableArray *lines=[NSMutableArray array];NSUInteger droppedLines=0,droppedEpisodes=0;
    if([raw[@"lines"] isKindOfClass:NSArray.class]){
        for(id rawLine in (NSArray *)raw[@"lines"]){
            if(![rawLine isKindOfClass:NSDictionary.class]){droppedLines++;continue;}
            NSMutableArray *episodes=[NSMutableArray array];
            if([rawLine[@"episodes"] isKindOfClass:NSArray.class]){
                for(id rawEpisode in (NSArray *)rawLine[@"episodes"]){
                    if(![rawEpisode isKindOfClass:NSDictionary.class]){droppedEpisodes++;continue;}
                    NSString *episodeID=[self safeDetailString:rawEpisode[@"id"]];
                    if(!episodeID.length){droppedEpisodes++;continue;}
                    NSString *episodeName=[self safeDetailString:rawEpisode[@"name"]];
                    [episodes addObject:@{@"id":episodeID,@"name":episodeName.length?episodeName:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)episodes.count+1],@"lineId":[self safeDetailString:rawEpisode[@"lineId"]]}];
                }
            }
            if(!episodes.count){droppedLines++;continue;}
            NSString *lineName=[self safeDetailString:rawLine[@"name"]];
            NSString *lineID=[self safeDetailString:rawLine[@"id"]];
            NSString *fallback=[NSString stringWithFormat:@"线路 %lu",(unsigned long)lines.count+1];
            [lines addObject:@{@"id":lineID.length?lineID:fallback,@"name":lineName.length?lineName:fallback,@"episodes":episodes}];
        }
    }
    clean[@"lines"]=lines;
    if(discardedLines)*discardedLines=droppedLines;if(discardedEpisodes)*discardedEpisodes=droppedEpisodes;
    return clean;
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=@"";self.view.backgroundColor=HostBackground();self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.selectedLineIndex=0;self.selectedEpisodeIndex=0;self.episodePage=0;self.episodeButtons=[NSMutableArray array];self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];back.frame=CGRectMake(0,0,44,44);[back setTitle:@"‹" forState:UIControlStateNormal];back.titleLabel.font=[UIFont systemFontOfSize:32 weight:UIFontWeightMedium];back.titleLabel.adjustsFontForContentSizeCategory=NO;back.titleEdgeInsets=UIEdgeInsetsMake(-3,0,0,0);back.tintColor=HostAccent();HostStyleGlassCard(back,14);HostInstallPressFeedback(back);back.accessibilityLabel=@"返回";back.accessibilityIdentifier=@"media-detail-back";[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:back];
    __weak typeof(self) weakSelf=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"ellipsis",@"title":@"更多影片操作",@"menu":[UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"返回影视首页" image:[UIImage systemImageNamed:@"house"] identifier:nil handler:^(UIAction *action){if(weakSelf.onReturnHome)weakSelf.onReturnHome();}],[UIAction actionWithTitle:@"重新加载详情" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action){[weakSelf loadDetail];}],[UIAction actionWithTitle:@"复制片名" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action){[weakSelf copyTitle];}],[UIAction actionWithTitle:@"分享影片信息" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action){[weakSelf shareTitle];}]]]}])];
    if(!MediaSourceUsesNativeCatalogAPI(self.source)&&[self.source[@"id"] isKindOfClass:NSString.class]){for(NSDictionary *stored in [ServiceStore services])if([stored[@"id"] isEqual:self.source[@"id"]]){self.source=stored;break;}}
    NSString *catalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");self.client=MediaSourceUsesNativeCatalogAPI(self.source)?[[MediaAPIClient alloc] initWithTVBoxSource:self.source]:[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue] catalogID:catalogID];
    NSDictionary *manifest=[self.source[@"manifest"] isKindOfClass:NSDictionary.class]?self.source[@"manifest"]:@{};NSDictionary *options=[manifest[@"options"] isKindOfClass:NSDictionary.class]?manifest[@"options"]:([self.source[@"options"] isKindOfClass:NSDictionary.class]?self.source[@"options"]:@{});NSInteger playTimeout=[options[@"playTimeoutMs"] respondsToSelector:@selector(integerValue)]?[options[@"playTimeoutMs"] integerValue]:0;if(playTimeout>0)self.client.playTimeoutMilliseconds=MIN(120000,MAX(1000,playTimeout));
    [self buildDetailLayout];[self refreshDetailHeader];[self loadDetail];
}
- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label=[UILabel new];label.font=HostRoundedFont(16.5,UIFontWeightBold,UIFontTextStyleHeadline);label.adjustsFontForContentSizeCategory=YES;label.textColor=HostText();label.text=text;return label;
}
- (UIButton *)actionButton:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;
    button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;
    HostStylePillButton(button,YES);MediaBrowserApplyScaledPillFont(button);button.layer.cornerRadius=17;button.contentEdgeInsets=UIEdgeInsetsMake(11,16,11,16);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[button setTitle:title forState:UIControlStateNormal];return button;
}
- (UIButton *)detailActionButton:(NSString *)title symbol:(NSString *)symbol label:(NSString *)label identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;button.accessibilityLabel=label;button.accessibilityTraits|=UIAccessibilityTraitButton;
    UIImageSymbolConfiguration *symbolConfig=[UIImageSymbolConfiguration configurationWithPointSize:13.5 weight:UIImageSymbolWeightSemibold];UIImage *image=[[UIImage systemImageNamed:symbol withConfiguration:symbolConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];if(image)[button setImage:image forState:UIControlStateNormal];[button setTitle:title forState:UIControlStateNormal];
    HostStylePillButton(button,NO);HostStyleGlassCard(button,14);HostInstallPressFeedback(button);button.layer.borderWidth=0.65;HostSetLayerBorderColor(button,HostBorder());
    button.tintColor=HostAccent();[button setTitleColor:HostText() forState:UIControlStateNormal];button.titleLabel.font=HostRoundedFont(13.5,UIFontWeightSemibold,UIFontTextStyleCaption1);button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.85;button.titleLabel.textAlignment=NSTextAlignmentCenter;button.semanticContentAttribute=UISemanticContentAttributeForceLeftToRight;button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;button.contentVerticalAlignment=UIControlContentVerticalAlignmentCenter;button.contentEdgeInsets=UIEdgeInsetsMake(9,10,9,10);button.imageEdgeInsets=UIEdgeInsetsMake(0,-3,0,3);button.titleEdgeInsets=UIEdgeInsetsMake(0,3,0,-3);button.imageView.contentMode=UIViewContentModeScaleAspectFit;
    if(button.imageView)[button bringSubviewToFront:button.imageView];if(button.titleLabel)[button bringSubviewToFront:button.titleLabel];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:42].active=YES;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)buildDetailLayout {
    self.scrollView=[UIScrollView new];self.scrollView.translatesAutoresizingMaskIntoConstraints=NO;self.scrollView.alwaysBounceVertical=YES;self.scrollView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.scrollView.accessibilityIdentifier=@"media-detail-scroll";[self.view addSubview:self.scrollView];
    self.contentStack=[UIStackView new];self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=9;
    self.contentStack.layoutMargins=UIEdgeInsetsMake(0,14,20,14);self.contentStack.layoutMarginsRelativeArrangement=YES;[self.scrollView addSubview:self.contentStack];
    self.detailScrollTopConstraint=[self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    [NSLayoutConstraint activateConstraints:@[self.detailScrollTopConstraint,
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],[self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor]]];
    self.status=[UILabel new];self.status.translatesAutoresizingMaskIntoConstraints=NO;self.status.textColor=HostSecondaryText();self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.status.adjustsFontForContentSizeCategory=YES;
    self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.hidden=YES;
    UIView *hero=[UIView new];self.heroView=hero;hero.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(hero,0);hero.layer.cornerRadius=0;hero.clipsToBounds=YES;hero.accessibilityIdentifier=@"media-detail-backdrop";
    self.posterPlaceholder=[UIView new];self.posterPlaceholder.translatesAutoresizingMaskIntoConstraints=NO;self.posterPlaceholder.backgroundColor=HostNeutralSurface();[hero addSubview:self.posterPlaceholder];
    UIImageView *placeholderIcon=[UIImageView new];placeholderIcon.translatesAutoresizingMaskIntoConstraints=NO;placeholderIcon.image=[UIImage systemImageNamed:@"film"];placeholderIcon.contentMode=UIViewContentModeScaleAspectFit;placeholderIcon.tintColor=[UIColor.secondaryLabelColor colorWithAlphaComponent:0.7];[self.posterPlaceholder addSubview:placeholderIcon];
    self.posterView=[UIImageView new];self.posterView.translatesAutoresizingMaskIntoConstraints=NO;self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;self.posterView.opaque=NO;self.posterView.backgroundColor=UIColor.clearColor;[hero addSubview:self.posterView];
    self.heroBlurView=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];self.heroBlurView.translatesAutoresizingMaskIntoConstraints=NO;self.heroBlurView.userInteractionEnabled=NO;self.posterView.alpha=0.88;self.heroBlurView.alpha=0.22;self.heroBlurView.hidden=NO;[hero addSubview:self.heroBlurView];
    UIView *shade=[UIView new];shade.translatesAutoresizingMaskIntoConstraints=NO;shade.backgroundColor=UIColor.clearColor;shade.userInteractionEnabled=NO;[hero addSubview:shade];
    self.heroGradient=[CAGradientLayer layer];self.heroGradient.opacity=0.45f;self.heroGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:0.78].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.12].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.02].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.06].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.58].CGColor];self.heroGradient.locations=@[@0.0,@0.18,@0.46,@0.66,@1.0];self.heroGradient.startPoint=CGPointMake(0.5,0);self.heroGradient.endPoint=CGPointMake(0.5,1);[hero.layer addSublayer:self.heroGradient];
    self.posterThumbnailView=[UIImageView new];self.posterThumbnailView.translatesAutoresizingMaskIntoConstraints=NO;self.posterThumbnailView.contentMode=UIViewContentModeScaleAspectFill;self.posterThumbnailView.clipsToBounds=YES;self.posterThumbnailView.layer.cornerRadius=12;self.posterThumbnailView.layer.cornerCurve=kCACornerCurveContinuous;self.posterThumbnailView.layer.borderWidth=0.8;self.posterThumbnailView.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;self.posterThumbnailView.backgroundColor=HostNeutralSurface();self.posterThumbnailView.hidden=NO;self.posterThumbnailView.isAccessibilityElement=NO;[hero addSubview:self.posterThumbnailView];
    self.heroTitle=[UILabel new];self.heroTitle.translatesAutoresizingMaskIntoConstraints=NO;self.heroTitle.font=HostRoundedFont(21,UIFontWeightBold,UIFontTextStyleTitle2);self.heroTitle.adjustsFontForContentSizeCategory=YES;self.heroTitle.textColor=UIColor.whiteColor;self.heroTitle.numberOfLines=2;self.heroTitle.layer.shadowColor=UIColor.blackColor.CGColor;self.heroTitle.layer.shadowOpacity=0.58;self.heroTitle.layer.shadowRadius=5.0;self.heroTitle.layer.shadowOffset=CGSizeMake(0,1.5);
    self.heroMetadata=[UILabel new];self.heroMetadata.translatesAutoresizingMaskIntoConstraints=NO;self.heroMetadata.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.heroMetadata.adjustsFontForContentSizeCategory=YES;self.heroMetadata.textColor=[UIColor.whiteColor colorWithAlphaComponent:0.88];self.heroMetadata.numberOfLines=1;self.heroMetadata.lineBreakMode=NSLineBreakByTruncatingTail;self.heroMetadata.layer.shadowColor=UIColor.blackColor.CGColor;self.heroMetadata.layer.shadowOpacity=0.45;self.heroMetadata.layer.shadowRadius=3.0;self.heroMetadata.layer.shadowOffset=CGSizeMake(0,1);
    [hero addSubview:self.status];[hero addSubview:self.heroTitle];[hero addSubview:self.heroMetadata];[self.scrollView insertSubview:hero belowSubview:self.contentStack];self.heroSpacer=[UIView new];self.heroSpacer.translatesAutoresizingMaskIntoConstraints=NO;self.heroSpacer.isAccessibilityElement=NO;[self.contentStack addArrangedSubview:self.heroSpacer];
    [NSLayoutConstraint activateConstraints:@[[hero.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],[hero.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[hero.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],[hero.bottomAnchor constraintEqualToAnchor:self.heroSpacer.bottomAnchor],[hero.heightAnchor constraintGreaterThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.36],[hero.heightAnchor constraintLessThanOrEqualToConstant:300],[self.heroSpacer.heightAnchor constraintGreaterThanOrEqualToAnchor:self.view.heightAnchor multiplier:0.36],[self.heroSpacer.heightAnchor constraintLessThanOrEqualToConstant:300],
        [self.posterPlaceholder.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.posterPlaceholder.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.posterPlaceholder.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.posterPlaceholder.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [placeholderIcon.centerXAnchor constraintEqualToAnchor:self.posterPlaceholder.centerXAnchor],[placeholderIcon.centerYAnchor constraintEqualToAnchor:self.posterPlaceholder.centerYAnchor],[placeholderIcon.widthAnchor constraintEqualToConstant:42],[placeholderIcon.heightAnchor constraintEqualToConstant:42],
        [self.posterView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.posterView.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.posterView.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.posterView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [self.heroBlurView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.heroBlurView.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.heroBlurView.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.heroBlurView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [shade.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[shade.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[shade.topAnchor constraintEqualToAnchor:hero.topAnchor],[shade.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
    [self.status.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],[self.status.centerYAnchor constraintEqualToAnchor:hero.centerYAnchor],[self.status.leadingAnchor constraintGreaterThanOrEqualToAnchor:hero.leadingAnchor constant:24],[self.status.trailingAnchor constraintLessThanOrEqualToAnchor:hero.trailingAnchor constant:-24],[self.status.widthAnchor constraintLessThanOrEqualToAnchor:hero.widthAnchor constant:-48],
        [self.posterThumbnailView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:18],[self.posterThumbnailView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-20],[self.posterThumbnailView.widthAnchor constraintEqualToConstant:72],[self.posterThumbnailView.heightAnchor constraintEqualToConstant:102],
        [self.heroTitle.leadingAnchor constraintEqualToAnchor:self.posterThumbnailView.trailingAnchor constant:14],[self.heroTitle.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-18],[self.heroTitle.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-53],
        [self.heroMetadata.leadingAnchor constraintEqualToAnchor:self.heroTitle.leadingAnchor],[self.heroMetadata.trailingAnchor constraintEqualToAnchor:self.heroTitle.trailingAnchor],
        [self.heroMetadata.topAnchor constraintEqualToAnchor:self.heroTitle.bottomAnchor constant:7],[self.heroMetadata.bottomAnchor constraintLessThanOrEqualToAnchor:hero.bottomAnchor constant:-20]]];
    UIView *infoCard=[UIView new];infoCard.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(infoCard,17);
    UIStackView *infoStack=[UIStackView new];infoStack.translatesAutoresizingMaskIntoConstraints=NO;infoStack.axis=UILayoutConstraintAxisVertical;infoStack.spacing=6;infoStack.layoutMargins=UIEdgeInsetsMake(12,14,12,14);infoStack.layoutMarginsRelativeArrangement=YES;[infoCard addSubview:infoStack];
    [NSLayoutConstraint activateConstraints:@[[infoStack.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor],[infoStack.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor],[infoStack.topAnchor constraintEqualToAnchor:infoCard.topAnchor],[infoStack.bottomAnchor constraintEqualToAnchor:infoCard.bottomAnchor]]];
    self.metadataLabel=[UILabel new];self.metadataLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];self.metadataLabel.adjustsFontForContentSizeCategory=YES;self.metadataLabel.textColor=HostText();self.metadataLabel.numberOfLines=2;[infoStack addArrangedSubview:self.metadataLabel];
    self.descriptionLabel=[UILabel new];self.descriptionLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.descriptionLabel.adjustsFontForContentSizeCategory=YES;self.descriptionLabel.textColor=HostSecondaryText();self.descriptionLabel.numberOfLines=3;[infoStack addArrangedSubview:self.descriptionLabel];
    self.descriptionToggle=[UIButton buttonWithType:UIButtonTypeSystem];self.descriptionToggle.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;[self.descriptionToggle setTitle:@"展开简介" forState:UIControlStateNormal];[self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];self.descriptionToggle.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];self.descriptionToggle.titleLabel.adjustsFontForContentSizeCategory=YES;[self.descriptionToggle addTarget:self action:@selector(toggleDescription) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(self.descriptionToggle);self.descriptionToggle.hidden=YES;[self.descriptionToggle.heightAnchor constraintGreaterThanOrEqualToConstant:36].active=YES;[infoStack addArrangedSubview:self.descriptionToggle];
    self.playButton=[self actionButton:@"▶︎  播放" identifier:@"media-detail-play" action:@selector(playCurrentEpisode)];self.playButton.accessibilityHint=@"播放当前线路和分集；上次播放过时会继续上次进度";[self.playButton.heightAnchor constraintGreaterThanOrEqualToConstant:52].active=YES;
    [self.contentStack addArrangedSubview:self.playButton];
    [self.contentStack addArrangedSubview:infoCard];
    UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisHorizontal;actions.alignment=UIStackViewAlignmentFill;actions.distribution=UIStackViewDistributionFillEqually;actions.spacing=8;actions.layoutMargins=UIEdgeInsetsMake(0,2,0,2);actions.layoutMarginsRelativeArrangement=YES;
    UIButton *copyButton=[self detailActionButton:@"复制" symbol:@"doc.on.doc" label:@"复制片名" identifier:@"media-detail-copy-title" action:@selector(copyTitle)];UIButton *shareButton=[self detailActionButton:@"分享" symbol:@"square.and.arrow.up" label:@"分享影片信息" identifier:@"media-detail-share" action:@selector(shareTitle)];self.favoriteButton=[self detailActionButton:@"收藏" symbol:@"heart" label:@"收藏影片" identifier:@"media-detail-favorite" action:@selector(toggleFavorite)];UIButton *episodesButton=[self detailActionButton:@"选集" symbol:@"list.number" label:@"查看选集" identifier:@"media-detail-jump-episodes" action:@selector(scrollToEpisodes)];
    [actions addArrangedSubview:copyButton];[actions addArrangedSubview:shareButton];[actions addArrangedSubview:self.favoriteButton];[actions addArrangedSubview:episodesButton];[self.contentStack addArrangedSubview:actions];
    UIView *sourceCard=[UIView new];sourceCard.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(sourceCard,17);
    UIStackView *sourceStack=[UIStackView new];sourceStack.translatesAutoresizingMaskIntoConstraints=NO;sourceStack.axis=UILayoutConstraintAxisVertical;sourceStack.spacing=9;sourceStack.layoutMargins=UIEdgeInsetsMake(14,14,14,14);sourceStack.layoutMarginsRelativeArrangement=YES;[sourceCard addSubview:sourceStack];
    [NSLayoutConstraint activateConstraints:@[[sourceStack.leadingAnchor constraintEqualToAnchor:sourceCard.leadingAnchor],[sourceStack.trailingAnchor constraintEqualToAnchor:sourceCard.trailingAnchor],[sourceStack.topAnchor constraintEqualToAnchor:sourceCard.topAnchor],[sourceStack.bottomAnchor constraintEqualToAnchor:sourceCard.bottomAnchor]]];
    [sourceStack addArrangedSubview:[self sectionLabel:@"播放线路"]];
    UIScrollView *routeScroll=[UIScrollView new];routeScroll.translatesAutoresizingMaskIntoConstraints=NO;routeScroll.showsHorizontalScrollIndicator=NO;[sourceStack addArrangedSubview:routeScroll];
    self.routeButtons=[UIStackView new];self.routeButtons.translatesAutoresizingMaskIntoConstraints=NO;self.routeButtons.axis=UILayoutConstraintAxisHorizontal;self.routeButtons.spacing=8;[routeScroll addSubview:self.routeButtons];
    [NSLayoutConstraint activateConstraints:@[[routeScroll.heightAnchor constraintGreaterThanOrEqualToConstant:44],[self.routeButtons.leadingAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.leadingAnchor],
        [self.routeButtons.trailingAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.trailingAnchor],[self.routeButtons.topAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.topAnchor],
        [self.routeButtons.bottomAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.bottomAnchor],[self.routeButtons.heightAnchor constraintEqualToAnchor:routeScroll.frameLayoutGuide.heightAnchor]]];
    self.parserRow=[UIStackView new];self.parserRow.axis=UILayoutConstraintAxisHorizontal;self.parserRow.alignment=UIStackViewAlignmentCenter;self.parserRow.spacing=8;
    UILabel *parserLabel=[self sectionLabel:@"解析接口"];parserLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];parserLabel.adjustsFontForContentSizeCategory=YES;[self.parserRow addArrangedSubview:parserLabel];
    UIView *parserSpacer=[UIView new];[parserSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[parserSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[self.parserRow addArrangedSubview:parserSpacer];
    self.parserButton=[UIButton buttonWithType:UIButtonTypeSystem];self.parserButton.accessibilityIdentifier=@"media-detail-parser-selector";self.parserButton.accessibilityLabel=@"选择解析接口";self.parserButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.parserButton.titleLabel.adjustsFontForContentSizeCategory=YES;HostStylePillButton(self.parserButton,NO);HostInstallPressFeedback(self.parserButton);self.parserButton.contentEdgeInsets=UIEdgeInsetsMake(8,13,8,13);[self.parserButton addTarget:self action:@selector(selectParser) forControlEvents:UIControlEventTouchUpInside];[self.parserRow addArrangedSubview:self.parserButton];[sourceStack addArrangedSubview:self.parserRow];
    self.episodeTitle=[self sectionLabel:@"选集"];[sourceStack addArrangedSubview:self.episodeTitle];
    UIStackView *paging=[UIStackView new];paging.axis=UILayoutConstraintAxisHorizontal;paging.alignment=UIStackViewAlignmentCenter;paging.spacing=6;self.pageLabel=[UILabel new];self.pageLabel.font=HostMonospacedDigitFont(12,UIFontWeightMedium,UIFontTextStyleCaption1);self.pageLabel.adjustsFontForContentSizeCategory=YES;self.pageLabel.adjustsFontSizeToFitWidth=YES;self.pageLabel.minimumScaleFactor=0.78;self.pageLabel.textColor=HostSecondaryText();self.pageLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.pageLabel.accessibilityIdentifier=@"media-detail-page-status";[self.pageLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[self.pageLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[paging addArrangedSubview:self.pageLabel];
    self.previousPageButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextPageButton=[UIButton buttonWithType:UIButtonTypeSystem];self.episodeReverseButton=[UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *pageSymCfg=[UIImageSymbolConfiguration configurationWithPointSize:12.5 weight:UIImageSymbolWeightBold];[self.previousPageButton setImage:[UIImage systemImageNamed:@"chevron.left" withConfiguration:pageSymCfg]?:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];[self.nextPageButton setImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:pageSymCfg]?:[UIImage systemImageNamed:@"chevron.right"] forState:UIControlStateNormal];self.previousPageButton.accessibilityLabel=@"上一页";self.nextPageButton.accessibilityLabel=@"下一页";HostStylePillButton(self.previousPageButton,NO);HostStylePillButton(self.nextPageButton,NO);HostInstallPressFeedback(self.previousPageButton);HostInstallPressFeedback(self.nextPageButton);self.previousPageButton.contentEdgeInsets=UIEdgeInsetsMake(6,11,6,11);self.nextPageButton.contentEdgeInsets=UIEdgeInsetsMake(6,11,6,11);self.previousPageButton.tintColor=HostText();self.nextPageButton.tintColor=HostText();[self.previousPageButton.widthAnchor constraintGreaterThanOrEqualToConstant:38].active=YES;[self.nextPageButton.widthAnchor constraintGreaterThanOrEqualToConstant:38].active=YES;
    [self.previousPageButton addTarget:self action:@selector(previousEpisodePage) forControlEvents:UIControlEventTouchUpInside];[self.nextPageButton addTarget:self action:@selector(nextEpisodePage) forControlEvents:UIControlEventTouchUpInside];
    self.episodeReverseButton.accessibilityLabel=@"切换选集正序或倒序";[self.episodeReverseButton setTitle:@"正序" forState:UIControlStateNormal];self.episodeReverseButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];HostStylePillButton(self.episodeReverseButton,NO);HostInstallPressFeedback(self.episodeReverseButton);self.episodeReverseButton.contentEdgeInsets=UIEdgeInsetsMake(6,12,6,12);[self.episodeReverseButton addTarget:self action:@selector(toggleEpisodeOrder) forControlEvents:UIControlEventTouchUpInside];[paging addArrangedSubview:self.episodeReverseButton];
    [paging addArrangedSubview:self.previousPageButton];[paging addArrangedSubview:self.nextPageButton];self.previousPageButton.hidden=YES;self.nextPageButton.hidden=YES;[self.previousPageButton.heightAnchor constraintGreaterThanOrEqualToConstant:36].active=YES;[self.nextPageButton.heightAnchor constraintGreaterThanOrEqualToConstant:36].active=YES;[self.episodeReverseButton.heightAnchor constraintGreaterThanOrEqualToConstant:36].active=YES;[sourceStack addArrangedSubview:paging];
    self.episodeGrid=[UIStackView new];self.episodeGrid.axis=UILayoutConstraintAxisVertical;self.episodeGrid.spacing=5;self.episodeGrid.distribution=UIStackViewDistributionFillEqually;self.episodeGrid.accessibilityIdentifier=@"media-detail-episode-grid";[sourceStack addArrangedSubview:self.episodeGrid];
    [self.contentStack addArrangedSubview:sourceCard];
    [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active=YES;
    [self updateParserSelectionButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.hidesWhenStopped=YES;self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[[self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)dealloc {[self.client cancel];self.inlinePlaybackController=nil;}
- (void)teardownInlinePlayback {MediaPlaybackViewController *player=self.inlinePlaybackController;if(!player)return;self.inlinePlaybackController=nil;self.playButton.hidden=NO;self.contentStack.layoutMargins=UIEdgeInsetsMake(0,14,20,14);[player willMoveToParentViewController:nil];[player.view removeFromSuperview];[player removeFromParentViewController];}
- (void)goBack {[self.navigationController popViewControllerAnimated:YES];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController){self.generation++;[self.client cancel];[self teardownInlinePlayback];}}
- (void)scrollToEpisodes {CGRect rect=[self.episodeTitle convertRect:self.episodeTitle.bounds toView:self.scrollView];CGFloat y=MAX(-self.scrollView.adjustedContentInset.top,rect.origin.y-12);[self.scrollView setContentOffset:CGPointMake(0,y) animated:YES];}
- (void)showTemporaryStatus:(NSString *)text {self.status.text=text;self.status.hidden=NO;__weak typeof(self) weakSelf=self;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaDetailViewController *owner=weakSelf;if(!owner)return;if([owner.status.text isEqualToString:text])owner.status.hidden=YES;});}
- (void)copyTitle {NSString *name=[self safeDetailString:self.detail[@"name"]];if(!name.length)name=[self safeDetailString:self.item[@"name"]];if(!name.length){[self showTemporaryStatus:@"没有可复制的片名"];return;}UIPasteboard.generalPasteboard.string=name;[self showTemporaryStatus:@"片名已复制"];}
- (void)shareTitle {NSString *name=[self.detail[@"name"] isKindOfClass:NSString.class]?self.detail[@"name"]:([self.item[@"name"] isKindOfClass:NSString.class]?self.item[@"name"]:@"影片");NSMutableArray *parts=[NSMutableArray arrayWithObject:name];NSString *metadata=[self metadataSummary];if(metadata.length)[parts addObject:metadata];NSString *text=[parts componentsJoinedByString:@" · "];UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];UIPopoverPresentationController *popover=share.popoverPresentationController;if(popover){popover.sourceView=self.view;popover.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);} [self presentViewController:share animated:YES completion:nil];}
- (NSString *)posterURL {
    NSArray *keys=@[@"banner",@"vod_pic_slide",@"poster",@"pic",@"vod_pic",@"cover",@"cover_url",@"coverUrl",@"image",@"img",@"thumbnail",@"thumb",@"poster_url",@"posterUrl"];
    NSURL *base=nil;NSString *api=[self.source[@"api"] isKindOfClass:NSString.class]?self.source[@"api"]:@"";NSURLComponents *apiParts=[NSURLComponents componentsWithString:api];if([@[@"http",@"https"] containsObject:apiParts.scheme.lowercaseString]&&apiParts.host.length&&!apiParts.user.length&&!apiParts.password.length)base=apiParts.URL;
    if(!base){NSInteger port=[self.source[@"port"] integerValue];if(port>0&&port<=65535)base=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%ld/",(long)port]];}
    for(NSDictionary *candidate in @[self.detail?:@{},self.item?:@{}])for(NSString *key in keys){id value=candidate[key];if(![value isKindOfClass:NSString.class])continue;NSString *raw=[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!raw.length||raw.length>8192)continue;
        NSURLComponents *parts=[NSURLComponents componentsWithString:raw];if([@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length&&!parts.user.length&&!parts.password.length)return raw;
        NSString *candidateURL=[raw hasPrefix:@"//"]?[NSString stringWithFormat:@"%@:%@",base.scheme.length?base.scheme:@"https",raw]:raw;NSURL *resolved=[NSURL URLWithString:candidateURL relativeToURL:base].absoluteURL;if(!resolved)continue;NSURLComponents *resolvedParts=[NSURLComponents componentsWithURL:resolved resolvingAgainstBaseURL:NO];if([@[@"http",@"https"] containsObject:resolvedParts.scheme.lowercaseString]&&resolvedParts.host.length&&!resolvedParts.user.length&&!resolvedParts.password.length&&resolved.absoluteString.length<=8192)return resolved.absoluteString;
    }
    return @"";
}
- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context {
    if(![result isKindOfClass:NSDictionary.class]||![context isKindOfClass:NSDictionary.class])return;
    if(self.inlinePlaybackController){[self.inlinePlaybackController playInlineResult:result context:context];self.heroView.hidden=YES;self.playButton.hidden=YES;return;}
    MediaPlaybackViewController *player=[MediaPlaybackViewController new];player.embeddedMode=YES;player.onPlaybackWillStart=self.onPlaybackWillStart;player.result=result;player.context=context;self.inlinePlaybackController=player;
    __weak typeof(self) weakSelf=self;player.onEpisodeSelectionChanged=^(NSDictionary *updatedContext){MediaDetailViewController *owner=weakSelf;if(!owner)return;NSArray *lines=owner.lines;NSInteger lineIndex=[updatedContext[@"lineIndex"] integerValue],episodeIndex=[updatedContext[@"episodeIndex"] integerValue];NSString *episodeID=[updatedContext[@"episodeID"] description]?:@"",*episodeName=[updatedContext[@"episodeName"] description]?:@"";BOOL matched=NO;
        if(lineIndex>=0&&lineIndex<lines.count){NSArray *episodes=[lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[(NSUInteger)lineIndex][@"episodes"]:@[];if(episodeIndex>=0&&episodeIndex<episodes.count){NSDictionary *candidate=episodes[(NSUInteger)episodeIndex];matched=!episodeID.length&&!episodeName.length||(episodeID.length&&[[candidate[@"id"] description] isEqual:episodeID])||(!episodeID.length&&episodeName.length&&[[candidate[@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame);}}
        if(!matched&&(episodeID.length||episodeName.length)){for(NSUInteger line=0;line<lines.count&&!matched;line++){NSArray *episodes=[lines[line][@"episodes"] isKindOfClass:NSArray.class]?lines[line][@"episodes"]:@[];for(NSUInteger episode=0;episode<episodes.count;episode++){NSDictionary *candidate=episodes[episode];if((episodeID.length&&[[candidate[@"id"] description] isEqual:episodeID])||(!episodeID.length&&episodeName.length&&[[candidate[@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame)){lineIndex=(NSInteger)line;episodeIndex=(NSInteger)episode;matched=YES;break;}}}}
        if(!matched||lineIndex<0||lineIndex>=lines.count)return;NSArray *episodes=[lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[(NSUInteger)lineIndex][@"episodes"]:@[];if(episodeIndex<0||episodeIndex>=episodes.count)return;owner.selectedLineIndex=lineIndex;owner.selectedEpisodeIndex=episodeIndex;owner.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)episodeIndex,episodes.count,owner.episodeOrderReversed);owner.resumeEntry=nil;[owner updateRouteAndEpisodeViews];};
    if(self.heroSpacer){[self.contentStack removeArrangedSubview:self.heroSpacer];[self.heroSpacer removeFromSuperview];self.heroSpacer=nil;}
    [self addChildViewController:player];[player loadViewIfNeeded];
    UIView *dock=[UIView new];dock.translatesAutoresizingMaskIntoConstraints=NO;dock.backgroundColor=UIColor.blackColor;dock.layer.cornerRadius=14;dock.layer.cornerCurve=kCACornerCurveContinuous;dock.clipsToBounds=YES;dock.accessibilityIdentifier=@"media-detail-floating-player";dock.accessibilityLabel=@"悬浮播放画面";[self.view addSubview:dock];self.inlinePlaybackDock=dock;
    self.inlinePlaybackDockHeightConstraint=[dock.heightAnchor constraintEqualToConstant:220];
    [NSLayoutConstraint activateConstraints:@[(self.inlinePlaybackDockTopConstraint=[dock.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4]),[dock.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[dock.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],self.inlinePlaybackDockHeightConstraint]];
    self.inlinePlaybackScrollTopConstraint=[self.scrollView.topAnchor constraintEqualToAnchor:dock.bottomAnchor constant:8];self.detailScrollTopConstraint.active=NO;self.inlinePlaybackScrollTopConstraint.active=YES;
    [player installFloatingInlineSurfaceInHost:dock controlsStack:self.contentStack];
    __weak typeof(self) weakOwner=self;player.onVideoAspectRatioChanged=^(CGFloat aspectRatio){MediaDetailViewController *owner=weakOwner;if(owner)[owner updateInlinePlaybackDockLayout];};
    [player didMoveToParentViewController:self];self.heroView.hidden=YES;self.playButton.hidden=YES;self.contentStack.layoutMargins=UIEdgeInsetsMake(6,14,24,14);[self updateInlinePlaybackDockLayout];[player playInlineResult:result context:context];[self.scrollView setContentOffset:CGPointZero animated:YES];
    [RuntimeDiagnostics.shared recordEvent:@"inline_playback_attached" category:@"playback" fields:@{@"correlation_id":context[@"correlationID"]?:@"",@"service_id":context[@"source"][@"id"]?:@"",@"line_index":context[@"lineIndex"]?:@0,@"episode_index":context[@"episodeIndex"]?:@0}];
}
- (void)updateInlinePlaybackDockLayout {
    if(!self.inlinePlaybackController||!self.inlinePlaybackDockHeightConstraint)return;
    CGFloat width=CGRectGetWidth(self.view.bounds),height=CGRectGetHeight(self.view.bounds);if(width<=0||height<=0)return;
    CGFloat maximum=MIN(420.0,MAX(180.0,height*.42));CGFloat target=[self.inlinePlaybackController preferredInlineVideoHeightForWidth:width maximumHeight:maximum];
    if(fabs(self.inlinePlaybackDockHeightConstraint.constant-target)>.5){self.inlinePlaybackDockHeightConstraint.constant=target;[self.view setNeedsLayout];}
}
- (void)loadDetail {
    NSUInteger generation=++self.generation;
    [self.client cancel];
    self.status.text=@"正在加载影片详情…";
    self.status.hidden=NO;
    [self.spinner startAnimating];
    NSString *requestedItemID=([self.item[@"id"] isKindOfClass:NSString.class]||[self.item[@"id"] isKindOfClass:NSNumber.class])?[self.item[@"id"] description]:@"";NSMutableDictionary *args=[@{@"id":requestedItemID} mutableCopy];
    NSString *itemTitleHint=[self safeDetailString:self.item[@"name"]];if(itemTitleHint.length)args[@"vodName"]=itemTitleHint;
    if(self.provider.length)args[@"provider"]=self.provider;
    BOOL hadCachedDetail=[self.detail isKindOfClass:NSDictionary.class];
    CFTimeInterval startedAt=CACurrentMediaTime();
    [RuntimeDiagnostics.shared recordEvent:@"media_detail_request_started" category:@"media_api" fields:@{
        @"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"",
        @"provider_id":self.provider?:@"", @"request_generation":@(generation),
        @"has_cached_detail":@(hadCachedDetail), @"cached_line_count":@(self.lines.count)
    }];
    static NSCache<NSString *, NSDictionary *> *safeDetailMemCache;
    static dispatch_once_t detailCacheOnce;
    dispatch_once(&detailCacheOnce, ^{ safeDetailMemCache=[NSCache new]; safeDetailMemCache.countLimit=48; });
    NSString *detailMemKey=requestedItemID.length?[NSString stringWithFormat:@"%@|%@|%@",self.source[@"id"]?:@"",self.provider?:@"",requestedItemID]:@"";
    if(!hadCachedDetail&&requestedItemID.length){
        id cachedRaw=[[MediaMetadataCache shared] resultForSource:self.source operation:@"detail" arguments:args maximumAge:1800 isStale:NULL];
        if(![cachedRaw isKindOfClass:NSDictionary.class]&&detailMemKey.length)cachedRaw=[safeDetailMemCache objectForKey:detailMemKey];
        if([cachedRaw isKindOfClass:NSDictionary.class]){
            NSDictionary *cachedSanitized=[self sanitizedDetail:cachedRaw discardedLines:NULL discardedEpisodes:NULL];
            if(cachedSanitized.count){
                self.detail=cachedSanitized;
                if(!self.resumeEntry){NSString *sourceID=self.source[@"id"]?:@"";self.resumeEntry=[MediaPlaybackStateStore latestHistoryForSourceID:sourceID provider:self.provider?:@"" itemID:requestedItemID];}
                [self restoreResumeEntrySelection];
                [self refreshDetailHeader];
                [self updateRouteAndEpisodeViews];
                if(self.lines.count){[self.spinner stopAnimating];self.status.hidden=YES;}
            }
        }
    }
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
            BOOL connRefused=[error.domain isEqualToString:NSURLErrorDomain]&&error.code==NSURLErrorCannotConnectToHost;
            BOOL retryableBusy=[error.userInfo[@"plugin_retryable"] boolValue];
            if((connRefused||retryableBusy)&&!MediaSourceUsesNativeCatalogAPI(owner.source)&&!owner.didAttemptServiceRecovery){
                owner.didAttemptServiceRecovery=YES;
                [PyHost refreshListenersAfterForeground];
                owner.status.text=@"正在恢复本机服务连接并重新加载详情…";
                owner.status.hidden=NO;
                [owner.spinner startAnimating];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    MediaDetailViewController *retryOwner=weakSelf;
                    if(retryOwner&&retryOwner.generation==generation)[retryOwner loadDetail];
                });
                return;
            }
            [RuntimeDiagnostics.shared recordEvent:@"media_detail_failed" category:@"media_api" fields:@{
                @"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"",
                @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"elapsed_ms":@(elapsedMS),
                @"has_cached_detail":@(hadCachedDetail), @"error_domain":error.domain?:@"",
                @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"invalid_response_shape",
                @"plugin_error_code":error.userInfo[@"plugin_error_code"]?:@"", @"failure_stage":error.userInfo[@"failure_stage"]?:@""
            }];
            if(owner.detail){owner.status.text=[NSString stringWithFormat:@"刷新失败 · 保留当前详情：%@",error.localizedDescription?:@"来源未返回详情"];owner.status.hidden=NO;}
            else{owner.status.text=[NSString stringWithFormat:@"影片详情加载失败\n%@",error.localizedDescription?:@"来源没有提供影片详情"];owner.status.hidden=NO;}
            return;
        }
        owner.didAttemptServiceRecovery=NO;
        NSUInteger discardedLines=0,discardedEpisodes=0;NSDictionary *sanitizedDetail=[owner sanitizedDetail:result discardedLines:&discardedLines discardedEpisodes:&discardedEpisodes];if(!sanitizedDetail){owner.status.text=@"来源返回的影片详情格式无法识别";owner.status.hidden=NO;return;}
        if(requestedItemID.length){[[MediaMetadataCache shared] storeResult:sanitizedDetail forSource:owner.source operation:@"detail" arguments:args];BOOL hasSignedEp=NO;for(NSDictionary *ln in [sanitizedDetail[@"lines"] isKindOfClass:NSArray.class]?sanitizedDetail[@"lines"]:@[]){for(NSDictionary *ep in [ln[@"episodes"] isKindOfClass:NSArray.class]?ln[@"episodes"]:@[]){NSString *eid=[[ep[@"id"] description] lowercaseString]?:@"";if([eid containsString:@"token="]||[eid containsString:@"sign="]||[eid containsString:@"auth="]){hasSignedEp=YES;break;}}if(hasSignedEp)break;}if(!hasSignedEp&&detailMemKey.length)[safeDetailMemCache setObject:sanitizedDetail forKey:detailMemKey];}
        NSDictionary *previousDetail=owner.detail;owner.detail=sanitizedDetail;[owner restoreSelectionFromDetail:previousDetail];
        if(discardedLines||discardedEpisodes)[RuntimeDiagnostics.shared recordEvent:@"media_detail_malformed_rows_skipped" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"discarded_line_count":@(discardedLines),@"discarded_episode_count":@(discardedEpisodes)}];
        NSUInteger episodeCount=0;
        for(id line in owner.lines){if([line isKindOfClass:NSDictionary.class]&&[line[@"episodes"] isKindOfClass:NSArray.class])episodeCount+=[line[@"episodes"] count];}
        [RuntimeDiagnostics.shared recordEvent:@"media_detail_readable" category:@"media_api" fields:@{
            @"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"",
            @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"elapsed_ms":@(elapsedMS),
            @"line_count":@(owner.lines.count), @"episode_count":@(episodeCount),
            @"has_description":@([owner.detail[@"description"] isKindOfClass:NSString.class]&&[owner.detail[@"description"] length]>0),
            @"has_poster":@(owner.posterURL.length>0)
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
    if(!self.lines.count){self.resumeEntry=nil;return;}
    NSInteger lineIndex=[entry[@"lineIndex"] integerValue],episodeIndex=[entry[@"episodeIndex"] integerValue];NSString *lineID=[entry[@"lineID"] description]?:@"",*episodeID=[entry[@"episodeID"] description]?:@"",*lineName=[entry[@"lineName"] isKindOfClass:NSString.class]?entry[@"lineName"]:@"",*episodeName=[entry[@"episodeName"] isKindOfClass:NSString.class]?entry[@"episodeName"]:@"";BOOL lineFound=NO;
    for(NSUInteger index=0;index<self.lines.count;index++)if(lineID.length&&[[self.lines[index][@"id"] description] isEqual:lineID]){lineIndex=(NSInteger)index;lineFound=YES;break;}
    if(!lineFound&&lineName.length){if(lineIndex>=0&&lineIndex<self.lines.count&&MediaBrowserIdentityNameMatches(self.lines[(NSUInteger)lineIndex][@"name"],lineName))lineFound=YES;else for(NSUInteger index=0;index<self.lines.count;index++)if(MediaBrowserIdentityNameMatches(self.lines[index][@"name"],lineName)){lineIndex=(NSInteger)index;lineFound=YES;break;}}
    if(!lineFound&&(lineIndex<0||lineIndex>=self.lines.count)){self.resumeEntry=nil;return;}
    NSArray *episodes=[self.lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[(NSUInteger)lineIndex][@"episodes"]:@[];BOOL episodeFound=NO;
    for(NSUInteger index=0;index<episodes.count;index++)if(episodeID.length&&[[episodes[index][@"id"] description] isEqual:episodeID]){episodeIndex=(NSInteger)index;episodeFound=YES;break;}
    if(!episodeFound&&episodeName.length){if(episodeIndex>=0&&episodeIndex<episodes.count&&MediaBrowserIdentityNameMatches(episodes[(NSUInteger)episodeIndex][@"name"],episodeName))episodeFound=YES;else for(NSUInteger index=0;index<episodes.count;index++)if(MediaBrowserIdentityNameMatches(episodes[index][@"name"],episodeName)){episodeIndex=(NSInteger)index;episodeFound=YES;break;}}
    if((episodeID.length&&!episodeFound)||(!episodeFound&&(episodeIndex<0||episodeIndex>=episodes.count))){self.resumeEntry=nil;return;}
    self.selectedLineIndex=lineIndex;self.selectedEpisodeIndex=episodeIndex;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)episodeIndex,episodes.count,self.episodeOrderReversed);self.episodePage=episodeGroup==NSNotFound?0:episodeGroup;
}
- (void)restoreSelectionFromDetail:(NSDictionary *)previousDetail {
    NSArray *oldLines=[previousDetail[@"lines"] isKindOfClass:NSArray.class]?previousDetail[@"lines"]:@[];
    if(!oldLines.count){NSArray *newLines=self.lines;self.selectedLineIndex=newLines.count?MIN(MAX(0,self.selectedLineIndex),(NSInteger)newLines.count-1):0;NSArray *episodes=self.selectedLineIndex<newLines.count&&[newLines[(NSUInteger)self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?newLines[(NSUInteger)self.selectedLineIndex][@"episodes"]:@[];self.selectedEpisodeIndex=episodes.count?MIN(MAX(0,self.selectedEpisodeIndex),(NSInteger)episodes.count-1):0;return;}
    NSInteger oldLineIndex=MIN(MAX(0,self.selectedLineIndex),(NSInteger)oldLines.count-1);NSDictionary *oldLine=[oldLines[(NSUInteger)oldLineIndex] isKindOfClass:NSDictionary.class]?oldLines[(NSUInteger)oldLineIndex]:@{};NSString *lineID=[oldLine[@"id"] description]?:@"",*lineName=[oldLine[@"name"] description]?:@"";NSArray *oldEpisodes=[oldLine[@"episodes"] isKindOfClass:NSArray.class]?oldLine[@"episodes"]:@[];NSInteger oldEpisodeIndex=oldEpisodes.count?MIN(MAX(0,self.selectedEpisodeIndex),(NSInteger)oldEpisodes.count-1):0;NSDictionary *oldEpisode=oldEpisodeIndex<oldEpisodes.count&&[oldEpisodes[(NSUInteger)oldEpisodeIndex] isKindOfClass:NSDictionary.class]?oldEpisodes[(NSUInteger)oldEpisodeIndex]:@{};NSString *episodeID=[oldEpisode[@"id"] description]?:@"",*episodeName=[oldEpisode[@"name"] description]?:@"";
    NSArray *newLines=self.lines;NSInteger nextLine=newLines.count?MIN(oldLineIndex,(NSInteger)newLines.count-1):0;BOOL lineMatched=NO;
    if(lineID.length){for(NSUInteger index=0;index<newLines.count;index++)if([[newLines[index][@"id"] description] isEqual:lineID]){nextLine=(NSInteger)index;lineMatched=YES;break;}}
    if(!lineMatched&&lineName.length){for(NSUInteger index=0;index<newLines.count;index++)if([[newLines[index][@"name"] description] localizedCaseInsensitiveCompare:lineName]==NSOrderedSame){nextLine=(NSInteger)index;lineMatched=YES;break;}}
    self.selectedLineIndex=nextLine;NSArray *newEpisodes=nextLine<newLines.count&&[newLines[(NSUInteger)nextLine][@"episodes"] isKindOfClass:NSArray.class]?newLines[(NSUInteger)nextLine][@"episodes"]:@[];NSInteger nextEpisode=newEpisodes.count?MIN(oldEpisodeIndex,(NSInteger)newEpisodes.count-1):0;
    BOOL episodeMatched=NO;if(episodeID.length){for(NSUInteger index=0;index<newEpisodes.count;index++)if([[newEpisodes[index][@"id"] description] isEqual:episodeID]){nextEpisode=(NSInteger)index;episodeMatched=YES;break;}}
    if(!episodeMatched&&episodeName.length){for(NSUInteger index=0;index<newEpisodes.count;index++)if([[newEpisodes[index][@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame){nextEpisode=(NSInteger)index;episodeMatched=YES;break;}}
    self.selectedEpisodeIndex=nextEpisode;self.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)MAX(0,nextEpisode),newEpisodes.count,self.episodeOrderReversed);
}
- (NSString *)metadataSummary {
    NSString *synopsis=[[self safeDetailString:self.detail[@"description"]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSSet<NSString *> *ignoredTokens=[NSSet setWithArray:@[@"url",@"http",@"https",@"null",@"nil",@"none",@"unknown",@"default",@"undefined",@"n/a",@"nan",@"0",@"未知",@"其它",@"其他",@"[object object]",@"[object array]",@"{}",@"[]"]];
    NSMutableArray *parts=[NSMutableArray array];
    for(NSString *key in @[@"year",@"area",@"lang",@"type",@"remarks"]){
        id rawValue=self.detail[key];
        if(![rawValue isKindOfClass:NSString.class])continue;
        NSString *value=[[self safeDetailString:rawValue] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!value.length)continue;
        NSString *lower=value.lowercaseString;
        if([ignoredTokens containsObject:lower]||[lower containsString:@"[object "]||[lower hasPrefix:@"http://"]||[lower hasPrefix:@"https://"])continue;
        if([key isEqualToString:@"remarks"]){
            if(value.length>28||[value containsString:@"。"]||[value containsString:@"，"]||[value containsString:@"；"])continue;
            if(synopsis.length>=8&&([synopsis containsString:value]||[value containsString:[synopsis substringToIndex:MIN((NSUInteger)8,synopsis.length)]]))continue;
        }
        BOOL duplicate=NO;
        for(NSString *existing in parts)if([existing localizedCaseInsensitiveCompare:value]==NSOrderedSame){duplicate=YES;break;}
        if(!duplicate)[parts addObject:value];
    }
    return parts.count?[parts componentsJoinedByString:@" · "]:@"";
}
- (void)refreshDetailHeader {
    NSString *poster=[self posterURL];self.posterView.image=nil;self.posterThumbnailView.image=nil;self.posterView.accessibilityLabel=poster.length?@"影片背景海报":@"暂无海报，显示影片占位图";self.posterThumbnailView.accessibilityLabel=poster.length?@"影片海报":@"暂无海报";self.posterPlaceholder.hidden=poster.length>0;if(poster.length){MediaLoadPosterWithRetry(poster,self.posterView,1);MediaLoadPosterWithRetry(poster,self.posterThumbnailView,1);}else{self.posterView.accessibilityIdentifier=nil;self.posterThumbnailView.accessibilityIdentifier=nil;}
    NSString *detailName=[self safeDetailString:self.detail[@"name"]];NSString *itemName=[self safeDetailString:self.item[@"name"]];NSString *preferredName=MediaDetailPreferredTitle(detailName,itemName,[self safeDetailString:self.item[@"id"]],[self safeDetailString:self.detail[@"description"]]);NSString *name=preferredName.length?preferredName:@"影片详情";self.title=name;self.heroTitle.text=name;self.heroMetadata.text=[self metadataSummary];
    NSString *synopsis=[[self safeDetailString:self.detail[@"description"]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *info=[NSMutableArray array];NSString *metadata=[self metadataSummary];if(metadata.length)[info addObject:metadata];
    NSString *director=[self.detail[@"director"] isKindOfClass:NSString.class]?[[self safeDetailString:self.detail[@"director"]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(director.length&&![@[@"url",@"null",@"未知",@"[object object]",@"[object array]"] containsObject:director.lowercaseString]&&![director.lowercaseString containsString:@"[object "])[info addObject:[NSString stringWithFormat:@"导演：%@",director]];
    NSString *actor=[self.detail[@"actor"] isKindOfClass:NSString.class]?[[self safeDetailString:self.detail[@"actor"]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(actor.length&&actor.length<=60&&![@[@"url",@"null",@"未知",@"[object object]",@"[object array]"] containsObject:actor.lowercaseString]&&![actor.lowercaseString containsString:@"[object "]&&(!synopsis.length||![synopsis containsString:actor]))[info addObject:[NSString stringWithFormat:@"主演：%@",actor]];
    self.metadataLabel.text=[info componentsJoinedByString:@"\n"];
    self.metadataLabel.hidden=(info.count==0);
    if(synopsis.length>1200){NSRange safeRange=[synopsis rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,1200)];synopsis=[[synopsis substringWithRange:safeRange] stringByAppendingString:@"…"];}self.descriptionLabel.text=synopsis.length?synopsis:@"暂无简介";self.descriptionToggle.hidden=synopsis.length<120;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:3;[self updateFavoriteButton];
}
- (NSString *)favoriteKey {NSString *sourceID=[self safeDetailString:self.source[@"id"]],*provider=self.provider?:@"",*itemID=[self safeDetailString:self.item[@"id"]];return [NSString stringWithFormat:@"%lu:%@%lu:%@%lu:%@",(unsigned long)sourceID.length,sourceID,(unsigned long)provider.length,provider,(unsigned long)itemID.length,itemID];}
- (void)updateFavoriteButton {
    NSDictionary *favorites=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};BOOL favorite=favorites[[self favoriteKey]]!=nil;UIImageSymbolConfiguration *configuration=[UIImageSymbolConfiguration configurationWithPointSize:13.5 weight:UIImageSymbolWeightSemibold];UIImage *image=[[UIImage systemImageNamed:favorite?@"heart.fill":@"heart" withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];if(image)[self.favoriteButton setImage:image forState:UIControlStateNormal];self.favoriteButton.tintColor=HostAccent();[self.favoriteButton setTitleColor:HostText() forState:UIControlStateNormal];if(self.favoriteButton.imageView)[self.favoriteButton bringSubviewToFront:self.favoriteButton.imageView];if(self.favoriteButton.titleLabel)[self.favoriteButton bringSubviewToFront:self.favoriteButton.titleLabel];self.favoriteButton.accessibilityLabel=favorite?@"取消收藏影片":@"收藏影片";
}
- (NSString *)parserPreferenceKey {NSString *sourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:([self.source[@"api"] isKindOfClass:NSString.class]?self.source[@"api"]:@"default");return [NSString stringWithFormat:@"cctv.media.parser.%@",sourceID];}
- (NSString *)playbackParserCatalogID {NSString *catalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");return [catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];}
- (NSArray<NSDictionary *> *)availablePlaybackParsers {NSString *catalogID=[self playbackParserCatalogID];if(!catalogID.length)return @[];return [TVBoxCatalogStore playbackParsersForCatalogID:catalogID];}
- (NSString *)selectedPlaybackParserID {NSString *selectedID=[NSUserDefaults.standardUserDefaults stringForKey:[self parserPreferenceKey]]?:@"";for(NSDictionary *parser in [self availablePlaybackParsers])if([parser[@"id"] isEqual:selectedID])return selectedID;return @"";}
- (void)updateParserSelectionButton {
    NSArray<NSDictionary *> *parsers=[self availablePlaybackParsers];self.parserRow.hidden=parsers.count==0;NSString *selectedID=[self selectedPlaybackParserID];NSString *title=@"自动解析";
    for(NSDictionary *parser in parsers)if([parser[@"id"] isEqual:selectedID]){title=parser[@"name"]?:@"解析接口";break;}
    [self.parserButton setTitle:[NSString stringWithFormat:@"%@ ▾",title] forState:UIControlStateNormal];self.parserButton.accessibilityValue=title;
}
- (void)selectParser {
    NSArray<NSDictionary *> *parsers=[self availablePlaybackParsers];if(!parsers.count)return;NSString *selectedID=[self selectedPlaybackParserID];
    NSMutableArray *choices=[NSMutableArray arrayWithObject:@{@"id":@"",@"name":@"自动",@"subtitle":@"优先尝试此资源合集中的 JSON 解析接口，失败后使用网页解析或站点原页",@"selected":@(!selectedID.length)}];
    for(NSDictionary *parser in parsers){NSString *type=[parser[@"type"] respondsToSelector:@selector(stringValue)]?[parser[@"type"] stringValue]:[parser[@"type"] description];NSString *kind=[@[@"0",@"web",@"html"] containsObject:type.lowercaseString]?@"网页解析":([@[@"1",@"json",@"api"] containsObject:type.lowercaseString]?@"JSON 解析接口":@"解析接口");NSMutableDictionary *choice=[@{@"id":parser[@"id"]?:@"",@"name":parser[@"name"]?:@"解析接口",@"subtitle":[NSString stringWithFormat:@"type %@ · %@ · %@",type.length?type:@"0",kind,parser[@"catalogName"]?:@"资源合集"],@"selected":@([parser[@"id"] isEqual:selectedID])} mutableCopy];if([parser[@"url"] isKindOfClass:NSString.class])choice[@"url"]=parser[@"url"];[choices addObject:choice];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"解析接口";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaDetailViewController *owner=weakSelf;if(!owner)return;NSString *identifier=[choice[@"id"] isKindOfClass:NSString.class]?choice[@"id"]:@"";[NSUserDefaults.standardUserDefaults setObject:identifier forKey:[owner parserPreferenceKey]];[owner updateParserSelectionButton];[RuntimeDiagnostics.shared recordEvent:@"media_parser_selection_changed" category:@"playback" fields:@{@"service_id":owner.source[@"id"]?:@"",@"parser_id":identifier,@"parser_name":choice[@"name"]?:@"自动"}];};
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker];navigation.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();HostStyleNavigation(navigation);navigation.navigationBar.prefersLargeTitles=NO;navigation.modalPresentationStyle=UIModalPresentationPageSheet;UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;}[self presentViewController:navigation animated:YES completion:nil];
}
- (void)toggleFavorite {
    NSMutableDictionary *favorites=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"] mutableCopy]?:[NSMutableDictionary dictionary];NSString *key=[self favoriteKey];
    if(favorites[key]) [favorites removeObjectForKey:key];else favorites[key]=@{@"sourceID":self.source[@"id"]?:@"",@"sourceName":self.source[@"name"]?:@"",@"provider":self.provider?:@"",@"item":self.item?:@{}};
    [NSUserDefaults.standardUserDefaults setObject:favorites forKey:@"cctv.mediaFavorites.v1"];[self updateFavoriteButton];
}
- (void)toggleDescription {self.descriptionExpanded=!self.descriptionExpanded;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:3;[self.descriptionToggle setTitle:self.descriptionExpanded?@"收起简介":@"展开简介" forState:UIControlStateNormal];}
- (void)toggleEpisodeOrder {
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];
    self.episodeOrderReversed=!self.episodeOrderReversed;
    NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)MAX(0,self.selectedEpisodeIndex),episodes.count,self.episodeOrderReversed);self.episodePage=episodeGroup==NSNotFound?0:episodeGroup;
    [RuntimeDiagnostics.shared recordEvent:@"media_episode_order_changed" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.source[@"id"]?:@"",@"provider_id":self.provider?:@"",@"reversed":@(self.episodeOrderReversed),@"episode_count":@(episodes.count),@"selected_episode_index":@(self.selectedEpisodeIndex)}];
    [self updateRouteAndEpisodeViews];
}
- (void)updateRouteAndEpisodeViews {
    for(UIView *view in self.routeButtons.arrangedSubviews.copy){[self.routeButtons removeArrangedSubview:view];[view removeFromSuperview];}if(self.selectedLineIndex>=self.lines.count)self.selectedLineIndex=0;
    for(NSUInteger index=0;index<self.lines.count;index++){NSDictionary *line=self.lines[index];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;NSString *name=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)index+1];
        [button setTitle:name forState:UIControlStateNormal];button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-route-%lu",(unsigned long)index];HostStylePillButton(button,index==self.selectedLineIndex);MediaBrowserApplyScaledPillFont(button);[button addTarget:self action:@selector(selectRoute:) forControlEvents:UIControlEventTouchUpInside];[self.routeButtons addArrangedSubview:button];}
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];self.selectedEpisodeIndex=episodes.count?MIN(MAX(0,self.selectedEpisodeIndex),(NSInteger)episodes.count-1):0;self.episodeTitle.text=[NSString stringWithFormat:@"选集 · %lu 集",(unsigned long)episodes.count];
    NSUInteger pageCount=MAX(1,(episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup);self.episodePage=MIN(self.episodePage,(NSInteger)pageCount-1);NSUInteger start=(NSUInteger)self.episodePage*CCTVEpisodesPerGroup,end=MIN(start+CCTVEpisodesPerGroup,episodes.count);
    NSUInteger firstSource=end>start?CCTVEpisodeSourceIndex(start,episodes.count,self.episodeOrderReversed):0,lastSource=end>start?CCTVEpisodeSourceIndex(end-1,episodes.count,self.episodeOrderReversed):0;
    self.pageLabel.text=episodes.count?[NSString stringWithFormat:@"第 %ld/%lu 组 · 第 %lu–%lu 集 · %@",(long)self.episodePage+1,(unsigned long)pageCount,(unsigned long)firstSource+1,(unsigned long)lastSource+1,self.episodeOrderReversed?@"倒序":@"正序"]:@"此线路没有可选分集";
    [self.episodeReverseButton setTitle:self.episodeOrderReversed?@"正序":@"倒序" forState:UIControlStateNormal];self.episodeReverseButton.accessibilityLabel=self.episodeOrderReversed?@"按正序排列分集，当前为倒序":@"按倒序排列分集，当前为正序";self.episodeReverseButton.hidden=episodes.count<2;
    self.previousPageButton.hidden=pageCount<=1;self.nextPageButton.hidden=pageCount<=1;self.previousPageButton.enabled=self.episodePage>0;self.nextPageButton.enabled=self.episodePage+1<pageCount;self.playButton.hidden=(self.inlinePlaybackController!=nil);self.playButton.enabled=episodes.count>0;self.playButton.alpha=episodes.count?1.0:0.55;
    NSDictionary *selectedLine=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex]:@{};NSDictionary *selectedEpisode=self.selectedEpisodeIndex<episodes.count?episodes[self.selectedEpisodeIndex]:@{};NSString *resumeLineID=[self.resumeEntry[@"lineID"] description]?:@"",*resumeEpisodeID=[self.resumeEntry[@"episodeID"] description]?:@"",*resumeLineName=[self.resumeEntry[@"lineName"] isKindOfClass:NSString.class]?self.resumeEntry[@"lineName"]:@"",*resumeEpisodeName=[self.resumeEntry[@"episodeName"] isKindOfClass:NSString.class]?self.resumeEntry[@"episodeName"]:@"";BOOL lineMatches=resumeLineID.length&&[[selectedLine[@"id"] description] isEqual:resumeLineID];if(!lineMatches&&resumeLineName.length)lineMatches=MediaBrowserIdentityNameMatches(selectedLine[@"name"],resumeLineName);if(!lineMatches)lineMatches=self.selectedLineIndex==[self.resumeEntry[@"lineIndex"] integerValue];BOOL episodeMatches=resumeEpisodeID.length&&[[selectedEpisode[@"id"] description] isEqual:resumeEpisodeID];if(!episodeMatches&&resumeEpisodeName.length)episodeMatches=MediaBrowserIdentityNameMatches(selectedEpisode[@"name"],resumeEpisodeName);if(!episodeMatches)episodeMatches=self.selectedEpisodeIndex==[self.resumeEntry[@"episodeIndex"] integerValue];BOOL resumeSelected=self.resumeEntry&&lineMatches&&episodeMatches;
    if(resumeSelected){NSString *verb=[self.resumeEntry[@"completed"] boolValue]?@"重新播放":@"继续观看";[self.playButton setTitle:[NSString stringWithFormat:@"▶︎  %@ · %@",verb,self.resumeEntry[@"episodeName"]?:@"上次分集"] forState:UIControlStateNormal];}else [self.playButton setTitle:@"▶︎  播放" forState:UIControlStateNormal];
    for(UIView *row in self.episodeGrid.arrangedSubviews.copy){[self.episodeGrid removeArrangedSubview:row];[row removeFromSuperview];}[self.episodeButtons removeAllObjects];if(!episodes.count)return;
    NSUInteger columnCount=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?3:4;NSUInteger visibleCount=end>start?end-start:0;NSUInteger rowCount=(visibleCount+columnCount-1)/columnCount;for(NSUInteger rowIndex=0;rowIndex<rowCount;rowIndex++){UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=6;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<columnCount;col++){NSUInteger displayIndex=start+rowIndex*columnCount+col;if(displayIndex<end){NSUInteger index=CCTVEpisodeSourceIndex(displayIndex,episodes.count,self.episodeOrderReversed);UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.layer.cornerRadius=14;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;NSDictionary *episode=episodes[index];NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];[button setTitle:name forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-episode-%lu",(unsigned long)index];HostStylePillButton(button,(NSInteger)index==self.selectedEpisodeIndex);if(resumeSelected&&(NSInteger)index==[self.resumeEntry[@"episodeIndex"] integerValue]){button.layer.borderWidth=1.2;HostSetLayerBorderColor(button,HostAccent());button.accessibilityHint=@"上次播放至此集";}button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.episodeButtons addObject:button];[row addArrangedSubview:button];}else{UIView *spacer=[UIView new];spacer.isAccessibilityElement=NO;[row addArrangedSubview:spacer];}}
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        MediaDetailViewController *owner=weakSelf;if(!owner)return;
        if(owner.selectedLineIndex>=0&&(NSUInteger)owner.selectedLineIndex<owner.routeButtons.arrangedSubviews.count&&[owner.routeButtons.superview isKindOfClass:UIScrollView.class]){
            UIView *activeRoute=owner.routeButtons.arrangedSubviews[(NSUInteger)owner.selectedLineIndex];
            [(UIScrollView *)owner.routeButtons.superview scrollRectToVisible:[activeRoute convertRect:activeRoute.bounds toView:owner.routeButtons.superview] animated:YES];
        }
    });
}
- (void)selectRoute:(UIButton *)sender {
    if(sender.tag<0||sender.tag>=self.lines.count||sender.tag==self.selectedLineIndex)return;
    HostAnimateSelection(sender);
    NSUInteger previousLine=self.selectedLineIndex;NSInteger previousEpisodeIndex=self.selectedEpisodeIndex;
    NSArray *previousEpisodes=previousLine<self.lines.count&&[self.lines[previousLine][@"episodes"] isKindOfClass:NSArray.class]?self.lines[previousLine][@"episodes"]:@[];NSDictionary *previousEpisode=self.selectedEpisodeIndex<previousEpisodes.count?previousEpisodes[self.selectedEpisodeIndex]:@{};NSString *previousEpisodeID=[previousEpisode[@"id"] description]?:@"",*previousEpisodeName=[previousEpisode[@"name"] description]?:@"";
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
    NSInteger matchedEpisode=-1;if(previousEpisodeID.length)for(NSUInteger index=0;index<episodes.count;index++)if([[episodes[index][@"id"] description] isEqual:previousEpisodeID]){matchedEpisode=(NSInteger)index;break;}if(matchedEpisode<0&&previousEpisodeName.length)for(NSUInteger index=0;index<episodes.count;index++)if([[episodes[index][@"name"] description] localizedCaseInsensitiveCompare:previousEpisodeName]==NSOrderedSame){matchedEpisode=(NSInteger)index;break;}self.selectedEpisodeIndex=episodes.count?(matchedEpisode>=0?matchedEpisode:MIN(MAX(0,previousEpisodeIndex),(NSInteger)episodes.count-1)):0;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,episodes.count,self.episodeOrderReversed);self.episodePage=episodeGroup==NSNotFound?0:episodeGroup;
    [self updateRouteAndEpisodeViews];
    if(self.inlinePlaybackController&&episodes.count)[self resolveAndPlaySelectedEpisode];
}
- (void)previousEpisodePage {if(self.episodePage>0){self.episodePage--;[self updateRouteAndEpisodeViews];}}
- (void)nextEpisodePage {NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(self.episodePage+1<(NSInteger)((episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup)){self.episodePage++;[self updateRouteAndEpisodeViews];}}
- (void)selectEpisode:(UIButton *)sender {
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];
    if(sender.tag>=episodes.count)return;
    HostAnimateSelection(sender);
    self.resumeEntry=nil;
    self.selectedEpisodeIndex=sender.tag;
    [RuntimeDiagnostics.shared recordEvent:@"media_episode_selected" category:@"media_api" fields:@{
        @"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"", @"provider_id":self.provider?:@"",
        @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex), @"line_count":@(self.lines.count), @"episode_count":@(episodes.count), @"selection_source":@"detail_ui"
    }];
    // Reflect the selected item before resolving its URL. Otherwise the old
    // episode stays highlighted while the request is in flight and can appear
    // selected again when playback returns to this detail page.
    self.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,episodes.count,self.episodeOrderReversed);
    [self updateRouteAndEpisodeViews];
    [self resolveAndPlaySelectedEpisode];
}
- (void)playCurrentEpisode {NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(!episodes.count)return;if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;[self resolveAndPlaySelectedEpisode];}
- (void)resolveAndPlaySelectedEpisode {
    if(self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)return;
    NSDictionary *line=self.lines[self.selectedLineIndex],*episode=episodes[self.selectedEpisodeIndex];NSUInteger generation=++self.generation;[self.client cancel];self.status.hidden=NO;self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];if(self.inlinePlaybackController){self.inlinePlaybackController.status.text=self.status.text;self.inlinePlaybackController.status.accessibilityLabel=self.status.text;[self.inlinePlaybackController.spinner startAnimating];}[self.spinner startAnimating];[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"", @"provider_id":self.provider?:@"", @"request_generation":@(generation), @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex), @"line_count":@(self.lines.count), @"episode_count":@(episodes.count), @"episode_has_id":@([episode[@"id"] description].length>0), @"line_has_id":@([line[@"id"] description].length>0)}];
    NSString *parserID=[self selectedPlaybackParserID];NSString *vodTitle=MediaDetailPreferredTitle([self safeDetailString:self.detail[@"name"]],[self safeDetailString:self.item[@"name"]],[self safeDetailString:self.item[@"id"]],[self safeDetailString:self.detail[@"description"]]);NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@"",@"parserID":parserID,@"vodName":vodTitle,@"episodeName":[episode[@"name"] description]?:@"",@"episodeIndex":@(self.selectedEpisodeIndex)} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaDetailViewController *owner=weakSelf;if(!owner)return;if(owner.generation!=generation){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"request_generation":@(generation), @"current_generation":@(owner.generation), @"reason":@"superseded_selection"}];return;}[owner.spinner stopAnimating];owner.status.hidden=NO;
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"line_index":@(owner.selectedLineIndex), @"episode_index":@(owner.selectedEpisodeIndex), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"result_received":@([result isKindOfClass:NSDictionary.class])}];owner.status.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];if(owner.inlinePlaybackController){[owner.inlinePlaybackController.spinner stopAnimating];owner.inlinePlaybackController.status.text=owner.status.text;owner.inlinePlaybackController.status.accessibilityLabel=owner.status.text;}[owner.scrollView setContentOffset:CGPointMake(0,-owner.scrollView.adjustedContentInset.top) animated:YES];[owner updateRouteAndEpisodeViews];return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"line_index":@(owner.selectedLineIndex), @"episode_index":@(owner.selectedEpisodeIndex), @"result_has_media_url":@([result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0), @"result_parse_mode":@([result[@"parse"] respondsToSelector:@selector(integerValue)]?[result[@"parse"] integerValue]:0), @"result_alternate_count":@([result[@"alternates"] isKindOfClass:NSArray.class]?[result[@"alternates"] count]:0)}];owner.status.hidden=YES;NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"episodeID":[episode[@"id"] description]?:@"",@"episodeName":[episode[@"name"] description]?:@"",@"lineIndex":@(owner.selectedLineIndex),@"episodeIndex":@(owner.selectedEpisodeIndex),@"parserID":parserID,@"correlationID":owner.diagnosticTraceID?:@""};if(owner.onPlay)owner.onPlay(result,context);
    }];
}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();if(!self.isViewLoaded)return;self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.metadataLabel.textColor=HostText();self.descriptionLabel.textColor=HostSecondaryText();[self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];self.status.textColor=HostSecondaryText();self.episodeTitle.textColor=HostText();self.pageLabel.textColor=HostSecondaryText();HostStylePillButton(self.playButton,YES);MediaBrowserApplyScaledPillFont(self.playButton);[self updateFavoriteButton];[self updateParserSelectionButton];[self updateRouteAndEpisodeViews];if(self.inlinePlaybackController)[self.inlinePlaybackController reloadThemeAppearance];}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    if(self.isMovingFromParentViewController&&self.inlinePlaybackDockTopConstraint&&self.activeNavigationSafeTop>self.view.safeAreaInsets.top+0.5){
        self.inlinePlaybackDockTopConstraint.constant=4.0+(self.activeNavigationSafeTop-self.view.safeAreaInsets.top);
    }
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];if(!self.isMovingFromParentViewController&&self.view.safeAreaInsets.top>0)self.activeNavigationSafeTop=self.view.safeAreaInsets.top;[CATransaction begin];[CATransaction setDisableActions:YES];self.heroGradient.frame=self.heroView.bounds;[CATransaction commit];UIEdgeInsets inset=UIEdgeInsetsMake(0,0,MAX(24,self.view.safeAreaInsets.bottom+20),0);self.scrollView.contentInset=inset;self.scrollView.scrollIndicatorInsets=inset;[self updateInlinePlaybackDockLayout]; }
@end
@interface MediaEntryListCell : UITableViewCell
@end
@implementation MediaEntryListCell
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat padding=14;
    CGFloat posterWidth=52;
    CGFloat posterHeight=74;
    CGFloat contentHeight=self.contentView.bounds.size.height;
    CGFloat contentWidth=self.contentView.bounds.size.width;
    CGFloat posterY=floor((contentHeight-posterHeight)/2.0);
    self.imageView.frame=CGRectMake(padding,posterY,posterWidth,posterHeight);
    self.imageView.contentMode=self.imageView.image.symbolImage?UIViewContentModeCenter:UIViewContentModeScaleAspectFill;
    self.imageView.clipsToBounds=YES;
    self.imageView.layer.drawsAsynchronously=YES;
    CGFloat accessoryWidth=self.accessoryType!=UITableViewCellAccessoryNone?28:0;
    CGFloat textX=padding+posterWidth+12;
    CGFloat textWidth=MAX(60,contentWidth-textX-padding-accessoryWidth);
    CGRect textFrame=self.textLabel.frame;
    textFrame.origin.x=textX;
    textFrame.size.width=textWidth;
    self.textLabel.frame=textFrame;
    CGRect detailFrame=self.detailTextLabel.frame;
    detailFrame.origin.x=textX;
    detailFrame.size.width=textWidth;
    self.detailTextLabel.frame=detailFrame;
    UIView *watchProgress=[self.contentView viewWithTag:9201];
    if(watchProgress)watchProgress.frame=CGRectMake(16,MAX(0,contentHeight-3),MAX(0,contentWidth-32),2.5);
}
@end

static NSString *MediaBrowserStationCoreName(NSString *name) {
    if(![name isKindOfClass:NSString.class]||!name.length)return @"";
    NSString *clean=name;
    for(NSString *token in @[@"🦋",@"•",@"·",@" ",@"[",@"]",@"(",@")",@"（",@"）",@".js",@".py",@"APP",@"py",@"js",@"关梯",@"影视",@"视频",@"影院",@"电影",@"4K",@"动漫",@"短剧",@"体育",@"直播",@"资源",@"剧场"]){
        clean=[clean stringByReplacingOccurrencesOfString:token withString:@""];
    }
    return [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSDictionary *MediaBrowserFallbackSupportedSite(NSDictionary *site,NSArray<NSDictionary *> *sites) {
    if(![site isKindOfClass:NSDictionary.class]||[site[@"supported"] boolValue]||sites.count<4)return nil;
    NSString *core=MediaBrowserStationCoreName(site[@"name"]);
    if(core.length<2)return nil;
    for(NSDictionary *cand in sites){
        if(![cand isKindOfClass:NSDictionary.class]||![cand[@"supported"] boolValue])continue;
        if([MediaBrowserStationCoreName(cand[@"name"]) isEqualToString:core])return cand;
    }
    for(NSDictionary *cand in sites){
        if(![cand isKindOfClass:NSDictionary.class]||![cand[@"supported"] boolValue])continue;
        NSString *candCore=MediaBrowserStationCoreName(cand[@"name"]);
        if(candCore.length>=2&&([candCore containsString:core]||[core containsString:candCore]))return cand;
    }
    return nil;
}

@interface MediaFavoritesViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *entries;
@property(nonatomic,copy) void (^onSelect)(NSDictionary *entry);
@end
@implementation MediaFavoritesViewController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=@"影视收藏";self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.tableView.separatorColor=HostSeparator();self.tableView.rowHeight=92;self.tableView.estimatedRowHeight=92;
    [self reloadFavoriteEntries];
}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();if(!self.isViewLoaded)return;self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.tableView.separatorColor=HostSeparator();[self.tableView reloadData];}
- (void)reloadFavoriteEntries {
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray array];
    [saved enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSDictionary *entry,BOOL *stop){
        if([entry isKindOfClass:NSDictionary.class]&&[entry[@"item"] isKindOfClass:NSDictionary.class]){
            NSMutableDictionary *copy=[entry mutableCopy];copy[@"__favoriteKey"]=key;[rows addObject:copy];
        }
    }];
    self.entries=[rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSString *left=a[@"item"][@"name"]?:@"",*right=b[@"item"][@"name"]?:@"";return [left localizedStandardCompare:right];}];
    self.navigationItem.rightBarButtonItem=self.entries.count?[[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClearFavorites)]:nil;
}
- (void)confirmClearFavorites {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清空影视收藏？" message:@"将移除本机保存的全部影视收藏记录。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){[NSUserDefaults.standardUserDefaults removeObjectForKey:@"cctv.mediaFavorites.v1"];[self reloadFavoriteEntries];[self.tableView reloadData];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(self.entries.count){self.tableView.backgroundView=nil;return self.entries.count;}
    UILabel *empty=[[UILabel alloc] initWithFrame:self.tableView.bounds];empty.text=@"还没有收藏影视\n在影片详情页点按「收藏」即可保存";empty.textAlignment=NSTextAlignmentCenter;empty.numberOfLines=0;empty.textColor=HostSecondaryText();self.tableView.backgroundView=empty;return 0;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MediaEntryListCell *cell=(MediaEntryListCell *)[tableView dequeueReusableCellWithIdentifier:@"media.favorite"];if(!cell)cell=[[MediaEntryListCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media.favorite"];
    NSDictionary *entry=self.entries[indexPath.row],*item=entry[@"item"]?:@{};cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.text=item[@"name"]?:@"影片";cell.textLabel.textColor=HostText();cell.textLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold]];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=2;cell.detailTextLabel.font=HostMonospacedDigitFont(12.5,UIFontWeightRegular,UIFontTextStyleCaption1);cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.imageView.layer.cornerRadius=10;cell.imageView.layer.cornerCurve=kCACornerCurveContinuous;cell.imageView.clipsToBounds=YES;cell.imageView.layer.borderWidth=0.6;HostSetLayerBorderColor(cell.imageView,HostBorder());
    NSMutableArray *parts=[NSMutableArray array];if([entry[@"sourceName"] length])[parts addObject:entry[@"sourceName"]];if([entry[@"provider"] length])[parts addObject:entry[@"provider"]];if([item[@"remarks"] length])[parts addObject:item[@"remarks"]];cell.detailTextLabel.text=[parts componentsJoinedByString:@" · "];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";if(poster.length)MediaLoadPosterWithRetry(poster,cell.imageView,1);else{cell.imageView.image=[UIImage systemImageNamed:@"film"];cell.imageView.accessibilityIdentifier=nil;cell.imageView.contentMode=UIViewContentModeCenter;cell.imageView.tintColor=HostSecondaryText();}return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {[tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.onSelect&&indexPath.row<self.entries.count)self.onSelect(self.entries[indexPath.row]);}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.row>=self.entries.count)return nil;
    NSString *favKey=self.entries[indexPath.row][@"__favoriteKey"];
    __weak typeof(self) weakSelf=self;
    UIContextualAction *unfav=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"取消收藏" handler:^(__unused UIContextualAction *action,__unused UIView *view,void (^done)(BOOL)){
        MediaFavoritesViewController *owner=weakSelf;if(!owner||!favKey.length){done(NO);return;}
        NSMutableDictionary *saved=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"] mutableCopy]?:[NSMutableDictionary dictionary];
        [saved removeObjectForKey:favKey];[NSUserDefaults.standardUserDefaults setObject:saved forKey:@"cctv.mediaFavorites.v1"];
        [owner reloadFavoriteEntries];[owner.tableView reloadData];done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[unfav]];
}
@end

@interface MediaWatchHistoryViewController : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *entries;
@property(nonatomic,copy) void (^onSelect)(NSDictionary *entry);
@end
@implementation MediaWatchHistoryViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.title=@"观看历史";self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.tableView.separatorColor=HostSeparator();self.tableView.rowHeight=92;self.tableView.estimatedRowHeight=92;
    self.entries=MediaPlaybackStateStore.watchHistory;
    [self updateClearHistoryButton];
}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();if(!self.isViewLoaded)return;self.view.backgroundColor=HostBackground();self.view.tintColor=HostAccent();self.tableView.backgroundColor=HostBackground();self.tableView.separatorColor=HostSeparator();[self.tableView reloadData];}
- (void)updateClearHistoryButton {self.navigationItem.rightBarButtonItem=self.entries.count?[[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(confirmClearHistory)]:nil;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if(self.entries.count){self.tableView.backgroundView=nil;return self.entries.count;}
    UILabel *empty=[[UILabel alloc] initWithFrame:self.tableView.bounds];empty.text=@"还没有观看记录\n播放过的影片会保存在这里";empty.textAlignment=NSTextAlignmentCenter;empty.numberOfLines=0;empty.textColor=HostSecondaryText();self.tableView.backgroundView=empty;return 0;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MediaEntryListCell *cell=(MediaEntryListCell *)[tableView dequeueReusableCellWithIdentifier:@"media.history"];if(!cell)cell=[[MediaEntryListCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media.history"];
    NSDictionary *entry=self.entries[indexPath.row],*item=entry[@"item"]?:@{};cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.text=item[@"name"]?:@"影片";cell.textLabel.textColor=HostText();cell.textLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold]];cell.textLabel.adjustsFontForContentSizeCategory=YES;cell.textLabel.numberOfLines=2;cell.detailTextLabel.font=HostMonospacedDigitFont(12.5,UIFontWeightRegular,UIFontTextStyleCaption1);cell.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    cell.imageView.layer.cornerRadius=10;cell.imageView.layer.cornerCurve=kCACornerCurveContinuous;cell.imageView.clipsToBounds=YES;cell.imageView.layer.borderWidth=0.6;HostSetLayerBorderColor(cell.imageView,HostBorder());
    NSTimeInterval position=[entry[@"position"] doubleValue],duration=[entry[@"duration"] doubleValue];NSUInteger mm=(NSUInteger)MAX(0,position)/60,ss=(NSUInteger)MAX(0,position)%60;
    NSString *progress=[entry[@"completed"] boolValue]?@"已看完":(duration>0?[NSString stringWithFormat:@"看到 %02lu:%02lu",(unsigned long)mm,(unsigned long)ss]:@"已开始播放");
    NSMutableArray *parts=[NSMutableArray array];if([entry[@"episodeName"] length])[parts addObject:entry[@"episodeName"]];if([entry[@"sourceName"] length])[parts addObject:entry[@"sourceName"]];if([entry[@"provider"] length])[parts addObject:entry[@"provider"]];[parts addObject:progress];
    cell.detailTextLabel.text=[parts componentsJoinedByString:@" · "];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    UIProgressView *watchProgress=(UIProgressView *)[cell.contentView viewWithTag:9201];
    if(!watchProgress){watchProgress=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];watchProgress.tag=9201;watchProgress.accessibilityIdentifier=@"media.history.progress";watchProgress.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleTopMargin;[cell.contentView addSubview:watchProgress];}
    watchProgress.trackTintColor=[HostBorder() colorWithAlphaComponent:0.22];watchProgress.progressTintColor=HostAccent();
    float ratio=[entry[@"completed"] boolValue]?1.0f:(duration>0?(float)MIN(1.0,MAX(0.04,position/duration)):0.15f);
    watchProgress.progress=ratio;watchProgress.frame=CGRectMake(16,MAX(0,CGRectGetHeight(cell.contentView.bounds)-3),MAX(0,CGRectGetWidth(cell.contentView.bounds)-32),2.5);
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";if(poster.length)MediaLoadPosterWithRetry(poster,cell.imageView,1);else{cell.imageView.image=[UIImage systemImageNamed:@"film"];cell.imageView.accessibilityIdentifier=nil;cell.imageView.contentMode=UIViewContentModeCenter;cell.imageView.tintColor=HostSecondaryText();}return cell;
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
static NSString * const MediaBrowserGridColumnsDefaultsKey = @"cctv.mediaGridColumns.v1";
static NSInteger MediaBrowserGridColumns(void) {return [NSUserDefaults.standardUserDefaults integerForKey:MediaBrowserGridColumnsDefaultsKey]==4?4:3;}
static NSArray<NSDictionary *> *MediaHomeModuleDefinitions(void) {
    return @[@{@"id":@"recommendations",@"title":@"精选推荐",@"detail":@"展示当前站点的轮播与热门影片"},@{@"id":@"catalog",@"title":@"分类预览",@"detail":@"滚动到分类时读取预览；顶部分类始终可用"}];
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
    [super viewDidLoad];self.title=@"媒体显示";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;self.tableView.tintColor=HostAccent();self.modules=[MediaHomeEnabledModules() mutableCopy];self.pinnedSources=[MediaHomePinnedSources() mutableCopy];
    if(self.navigationController.viewControllers.firstObject==self)self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}
- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.tableView.tintColor=HostAccent();[self.tableView reloadData];
}
- (void)close {if(self.navigationController.viewControllers.firstObject!=self)[self.navigationController popViewControllerAnimated:YES];else[self dismissViewControllerAnimated:YES completion:self.onChange];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?MediaHomeModuleDefinitions().count:(section==1?2:self.sources.count);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return section==0?@"显示模块":(section==1?@"海报网格列数":@"固定的影视来源");}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return section==0?@"精选来自当前站点与本机观看记录。隐藏模块不会删除收藏或历史。":(section==1?@"3 列卡片更大；4 列布局更紧凑。此设置用于媒体分类网格；大字体模式会自动增大卡片。":(self.sources.count?@"固定来源会在资源选择器中优先显示，不会提前启动服务。":@"导入影视资源后，可以在这里固定常用来源。"));}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"media-home-setting"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media-home-setting"];cell.backgroundColor=HostCard();cell.layer.cornerRadius=14;cell.layer.cornerCurve=kCACornerCurveContinuous;cell.clipsToBounds=YES;cell.layer.borderWidth=0.6;HostSetLayerBorderColor(cell,HostBorder());cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryNone;cell.tintColor=HostAccent();
    if(indexPath.section==1){NSInteger columns=indexPath.row==0?3:4;cell.accessoryView=nil;cell.selectionStyle=UITableViewCellSelectionStyleDefault;cell.textLabel.text=[NSString stringWithFormat:@"%ld 列%@",(long)columns,columns==3?@" · 标准":@" · 紧凑"];cell.detailTextLabel.text=columns==3?@"海报和标题更大，浏览更舒适。":@"单屏展示更多影片，海报更紧凑。";cell.accessoryType=MediaBrowserGridColumns()==columns?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;cell.accessibilityIdentifier=[NSString stringWithFormat:@"media-home-grid-columns-%ld",(long)columns];return cell;}
    NSString *identifier=nil;BOOL enabled=NO;if(indexPath.section==0){NSDictionary *row=MediaHomeModuleDefinitions()[indexPath.row];identifier=row[@"id"];cell.textLabel.text=row[@"title"];cell.detailTextLabel.text=row[@"detail"];enabled=[self.modules containsObject:identifier];}else{NSDictionary *source=self.sources[indexPath.row];identifier=source[@"id"]?:@"";cell.textLabel.text=source[@"name"]?:@"影视资源";NSString *engine=source[@"engine"]?:@"未知运行引擎";cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · 点按卡片时才启动",engine];enabled=[self.pinnedSources containsObject:identifier];}
    UISwitch *toggle=[UISwitch new];toggle.onTintColor=HostAccent();toggle.on=enabled;toggle.accessibilityIdentifier=[NSString stringWithFormat:@"%@:%@",indexPath.section==0?@"module":@"source",identifier];[toggle addTarget:self action:@selector(toggleSetting:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {if(indexPath.section!=1){[tableView deselectRowAtIndexPath:indexPath animated:YES];return;}[NSUserDefaults.standardUserDefaults setInteger:indexPath.row==0?3:4 forKey:MediaBrowserGridColumnsDefaultsKey];[tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];if(self.onChange)self.onChange();}
- (void)toggleSetting:(UISwitch *)sender {
    NSArray *parts=[sender.accessibilityIdentifier componentsSeparatedByString:@":"];if(parts.count!=2)return;NSString *kind=parts[0],*identifier=parts[1];NSMutableSet *set=[kind isEqual:@"module"]?self.modules:self.pinnedSources;if(sender.isOn)[set addObject:identifier];else[set removeObject:identifier];NSString *key=[kind isEqual:@"module"]?MediaHomeModulesDefaultsKey:MediaHomePinnedSourcesDefaultsKey;[NSUserDefaults.standardUserDefaults setObject:[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:key];if([kind isEqual:@"module"])[NSUserDefaults.standardUserDefaults setInteger:3 forKey:MediaHomeModulesSchemaKey];if(self.onChange)self.onChange();
}
@end

typedef NS_ENUM(NSInteger, MediaContentMode) { MediaContentModeFeatured, MediaContentModeCategory };

@interface MediaBrowserViewController () <UISearchResultsUpdating,UIScrollViewDelegate>
@property(nonatomic, strong) UICollectionView *grid;
@property(nonatomic) MediaContentMode contentMode;
@property(nonatomic,strong) NSSet<NSString *> *visibleCategoryIDs;
@property(nonatomic,strong) NSMutableSet<NSString *> *homeShelfAttempts;
@property(nonatomic,strong) NSMutableDictionary *categorySessions;
@property(nonatomic,strong) NSLayoutConstraint *floatingSearchBottomConstraint;
@property(nonatomic,strong) UIButton *floatingHomeSearchButton;
@property(nonatomic,strong) NSLayoutConstraint *categoryScrollHeightConstraint;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic,strong) UIScrollView *homeScroll;
@property(nonatomic,strong) UIView *homeTopImmersiveScrim;
@property(nonatomic,strong) UIVisualEffectView *homeTopGlassBlurView;
@property(nonatomic,strong) CAGradientLayer *homeTopImmersiveGradient;
@property(nonatomic,strong) NSLayoutConstraint *selectionRowTopConstraint;
@property(nonatomic) CGFloat statusBarSafeInset;
@property(nonatomic) CGPoint navigationReturnContentOffset;
@property(nonatomic) BOOL hasNavigationReturnPosition;
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
@property(nonatomic,strong) NSLayoutConstraint *moreButtonBottomConstraint;
@property(nonatomic) CGFloat bottomOverlayInset;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UIStackView *selectionRow;
@property(nonatomic, strong) UIButton *sourceSelectButton;
@property(nonatomic, strong) UIButton *providerSelectButton;
@property(nonatomic,strong) UIButton *homeMenuButton;
@property(nonatomic, strong) MediaAPIClient *client;
@property(nonatomic, strong) LocalServiceReadiness *readiness;
@property(nonatomic, copy) NSArray<NSDictionary *> *sources;
@property(nonatomic, copy) NSDictionary *source;
@property(nonatomic, copy) NSArray<NSDictionary *> *providers;
@property(nonatomic, copy) NSString *provider;
@property(nonatomic,copy) NSString *selectedCatalogID;
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
@property(nonatomic) NSTimeInterval capabilityReadinessStartedAt;
@property(nonatomic,strong) NSDictionary<NSString *,NSString *> *watchHistoryLookup;
@property(nonatomic,copy) NSString *diagnosticTraceID;
@property(nonatomic,strong) MediaAPIClient *configurationClient;
@property(nonatomic,strong) LocalServiceReadiness *detachedReadiness;
@property(nonatomic) NSUInteger detachedGeneration;
@property(nonatomic) BOOL forceVisibleShelfRefresh;
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
@property(nonatomic,strong) NSMutableSet<NSString *> *homeCategoryLoadsInFlight;
@property(nonatomic) BOOL homeShelfQueueActive;
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
- (UIMenu *)homeActionsMenu;
- (void)pushMediaPage:(UIViewController *)page;
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action;
- (void)updateHomeStatusCard;
- (void)clearHomeResult;
- (void)performHomeStatusAction;
- (BOOL)isHomePageVisible;
- (void)updateSelectionControls;
- (NSDictionary *)selectedCatalog;
- (NSDictionary *)sourceForCatalogSite:(NSDictionary *)site catalog:(NSDictionary *)catalog;
- (void)selectCatalogResource:(NSDictionary *)catalog;
- (void)chooseCatalogProvider;
- (UIButton *)homeToolbarButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier label:(NSString *)label action:(SEL)action;
- (void)updateHomeGridLayout;
- (void)updateVisibleHomePosters;
- (void)loadVisibleHomeShelves;
- (void)openGlobalSearch;
- (void)openGlobalSearchForKeyword:(nullable NSString *)keyword excludingIndexSources:(BOOL)excludeIndexSources;
- (BOOL)openMetadataSearchForItem:(NSDictionary *)item;
- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories index:(NSUInteger)index generation:(NSUInteger)generation sourceID:(NSString *)sourceID provider:(NSString *)provider;
- (NSString *)categorySessionKey;
- (void)prepareDetailSource:(NSDictionary *)source completion:(dispatch_block_t)completion;
- (NSArray<NSDictionary *> *)scopeFeedSections:(NSArray<NSDictionary *> *)sections;
- (NSArray<NSDictionary *> *)mediaFeedSections;
- (void)selectFeedSection:(NSDictionary *)section;
- (void)updateMediaFeedInsets;
- (void)refreshMediaContent;
- (void)updateCategorySelection;
- (void)saveCategorySession;
- (void)selectMediaCategory:(NSString *)identifier;
- (NSString *)stateKeyForSource:(NSDictionary *)source provider:(NSString *)provider;
- (void)loadHome;
@end
@implementation MediaBrowserViewController
- (NSArray<NSDictionary *> *)scopeFeedSections:(NSArray<NSDictionary *> *)sections {
    NSMutableArray *scoped=[NSMutableArray arrayWithCapacity:sections.count];for(NSDictionary *section in sections){NSMutableDictionary *entry=[section mutableCopy];entry[@"sourceID"]=[self.source[@"id"] description]?:@"";entry[@"providerID"]=self.provider?:@"";entry[@"source"]=self.source?:@{};[scoped addObject:entry];}return scoped;
}
- (NSArray<NSDictionary *> *)mediaFeedSections {
    NSMutableArray *sections=[NSMutableArray array];
    if(!self.homeMode){
        NSString *name=self.keyword.length?[NSString stringWithFormat:@"搜索：%@",self.keyword]:@"全部影片";for(NSDictionary *category in self.homeCategories)if([category[@"id"] isEqual:self.category]){name=category[@"name"]?:name;break;}
        NSArray *filterOptions=[self.filters[self.category?:@""] isKindOfClass:NSArray.class]?self.filters[self.category?:@""]:@[];
        [sections addObject:@{@"id":@"category-grid",@"kind":@"grid",@"title":name,@"action":@"filters",@"actionTitle":filterOptions.count?@"筛选":@"",@"items":self.items?:@[]}];
        if(self.loading&&!self.items.count)[sections addObject:@{@"id":@"loading",@"kind":@"skeleton",@"items":@[]}];
        if(!self.loading&&!self.items.count)[sections addObject:@{@"id":@"empty",@"kind":@"status",@"title":@"暂无影片",@"subtitle":self.status.text.length?self.status.text:@"试试其他分类或筛选条件",@"actionTitle":@"重试",@"action":@"retry"}];
        else if(!self.loading&&self.status.text.length)[sections addObject:@{@"id":@"query-status",@"kind":@"status",@"title":self.status.text,@"actionTitle":@"重试",@"action":@"retry"}];
        return [self scopeFeedSections:sections];
    }
    NSSet *enabled=MediaHomeEnabledModules();NSString *provider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&provider];NSArray *raw=MediaBrowserDictionaryRows(home[@"items"],NULL);NSMutableArray *recommendations=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *item in raw){NSString *key=MediaBrowserItemIdentity(item);if(key.length&&[seen containsObject:key])continue;if(key.length)[seen addObject:key];[recommendations addObject:item];}
    NSUInteger bannerCount=MIN((NSUInteger)5,recommendations.count);
    if([enabled containsObject:@"recommendations"]&&bannerCount)[sections addObject:@{@"id":@"hero",@"kind":@"hero",@"heroTopInset":@([self stableTopSafeAreaInset]+104),@"items":[recommendations subarrayWithRange:NSMakeRange(0,bannerCount)]}];
    if(NO&&[enabled containsObject:@"continue"]){NSMutableArray *resume=[NSMutableArray array];for(NSDictionary *entry in MediaPlaybackStateStore.watchHistory){if([entry[@"completed"] boolValue]||[entry[@"position"] doubleValue]<=0)continue;NSMutableDictionary *item=[entry[@"item"] mutableCopy]?:[NSMutableDictionary dictionary];NSString *epName=[entry[@"episodeName"] isKindOfClass:NSString.class]?entry[@"episodeName"]:@"";NSString *srcName=[entry[@"sourceName"] isKindOfClass:NSString.class]?entry[@"sourceName"]:@"";item[@"remarks"]=epName.length?epName:@"继续观看";item[@"feedSubtitle"]=srcName.length?[NSString stringWithFormat:@"继续观看 · %@",srcName]:@"继续观看";item[@"__historyEntry"]=entry;[resume addObject:item];if(resume.count==10)break;}if(resume.count)[sections addObject:@{@"id":@"continue",@"kind":@"posters",@"title":@"继续观看",@"items":resume,@"actionTitle":@"全部",@"action":@"history"}];}
    if([enabled containsObject:@"recommendations"]&&recommendations.count>bannerCount){NSUInteger count=MIN((NSUInteger)10,recommendations.count-bannerCount);[sections addObject:@{@"id":@"popular",@"kind":@"posters",@"title":@"热门推荐",@"items":[recommendations subarrayWithRange:NSMakeRange(bannerCount,count)]}];}
    if([enabled containsObject:@"catalog"]){for(NSDictionary *category in [self.homeCategories subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)8,self.homeCategories.count))]){NSString *identifier=category[@"id"];NSDictionary *args=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];id cached=[MediaMetadataCache.shared resultForSource:self.source operation:@"category" arguments:args maximumAge:DBL_MAX isStale:NULL];NSArray *items=[cached isKindOfClass:NSDictionary.class]?MediaBrowserDictionaryRows(cached[@"items"],NULL):@[];BOOL attempted=[self.homeShelfAttempts containsObject:identifier]&&![self.homeCategoryLoadsInFlight containsObject:identifier];NSString *kind=items.count?@"posters":(attempted?@"status":@"skeleton");[sections addObject:@{@"id":[@"category-" stringByAppendingString:identifier],@"kind":kind,@"title":category[@"name"]?:@"分类",@"items":[items subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)8,items.count))],@"categoryID":identifier,@"actionTitle":@"全部",@"subtitle":@"暂未读取到内容，点按全部浏览此分类"}];}}
    if(self.homeStatusLoading&&!bannerCount)[sections insertObject:@{@"id":@"loading",@"kind":@"skeleton",@"title":@"正在加载当前站点",@"items":@[]} atIndex:0];
    if(!self.homeStatusLoading&&(self.status.text.length||(!recommendations.count&&!self.homeCategories.count))){BOOL noSource=!self.source;NSString *title=noSource?([self selectedCatalog]?@"选择内部站点":@"开始浏览影视"):(self.status.text.length?self.status.text:@"当前站点暂无推荐");BOOL searchOnly=[self.source[@"capabilities"] containsObject:@"search"]&&![self.source[@"capabilities"] containsObject:@"home"];[sections addObject:@{@"id":@"status",@"kind":@"status",@"title":title,@"subtitle":noSource?@"只加载你选择的资源与站点":@"可切换分类或搜索当前站点",@"actionTitle":noSource?([self selectedCatalog]?@"选择站点":@"添加资源"):(searchOnly?@"搜索本站":@"重试"),@"action":noSource?@"resources":(searchOnly?@"search":@"retry")}];}
    if(!sections.count)[sections addObject:@{@"id":@"display-empty",@"kind":@"status",@"title":@"暂无精选内容",@"subtitle":@"可以选择顶部分类浏览，或调整媒体显示模块",@"actionTitle":@"媒体显示",@"action":@"display-settings"}];
    return [self scopeFeedSections:sections];
}
- (CGFloat)stableTopSafeAreaInset {
    CGFloat fallback=self.statusBarSafeInset>0?self.statusBarSafeInset:self.view.safeAreaInsets.top;
    return HostStatusBarSafeTop(self.view,fallback);
}
- (void)syncStableTopHeaderLayout {
    if(!self.isViewLoaded||!self.selectionRowTopConstraint)return;
    CGFloat viewSafeTop=self.view.safeAreaInsets.top;
    CGFloat stableTop=[self stableTopSafeAreaInset];
    CGFloat navBarInflation=MAX(0.0,viewSafeTop-stableTop);
    CGFloat desiredConstant=4.0-navBarInflation;
    if(fabs(self.selectionRowTopConstraint.constant-desiredConstant)>0.05){
        self.selectionRowTopConstraint.constant=desiredConstant;
    }
}
- (void)setTopSafeAreaInset:(CGFloat)inset {
    if(!isfinite(inset))inset=0;
    inset=HostStatusBarSafeTop(self.view,MAX(0,inset));
    if(fabs(self.statusBarSafeInset-inset)<0.5)return;
    self.statusBarSafeInset=inset;
    if(self.isViewLoaded){[self syncStableTopHeaderLayout];[self updateMediaFeedInsets];}
}
- (void)prepareForNavigationTransition {
    if(!self.isViewLoaded||!self.grid||self.hasNavigationReturnPosition)return;
    self.navigationReturnContentOffset=self.grid.contentOffset;
    self.hasNavigationReturnPosition=YES;
    if(self.homeMode)self.pendingHomeOffsetRestore=@(self.navigationReturnContentOffset.y);
}
- (void)refreshHeaderAfterNavigationTransition {
    if(!self.isViewLoaded||!self.grid)return;
    [self syncStableTopHeaderLayout];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self updateMediaFeedInsets];
    if(self.hasNavigationReturnPosition){
        CGFloat minimum=-self.grid.adjustedContentInset.top;
        CGFloat maximum=MAX(minimum,self.grid.contentSize.height-self.grid.bounds.size.height+self.grid.adjustedContentInset.bottom);
        CGPoint restored=CGPointMake(self.navigationReturnContentOffset.x,MIN(MAX(self.navigationReturnContentOffset.y,minimum),maximum));
        if(fabs(self.grid.contentOffset.y-restored.y)>0.5||fabs(self.grid.contentOffset.x-restored.x)>0.5){
            [self.grid setContentOffset:restored animated:NO];
        }
        self.hasNavigationReturnPosition=NO;
    }
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self syncStableTopHeaderLayout];
    [self updateMediaFeedInsets];
}
- (void)updateMediaFeedInsets {
    if(!self.grid)return;
    [self syncStableTopHeaderLayout];
    CGFloat stableTop=[self stableTopSafeAreaInset];
    CGFloat navInflation=MAX(0.0,self.view.safeAreaInsets.top-stableTop);
    CGFloat rawCategoryBottom=CGRectGetMaxY(self.categoryScroll.frame);
    if(navInflation>0.5&&rawCategoryBottom>stableTop+108.0)rawCategoryBottom-=navInflation;
    CGFloat deterministicCategoryBottom=self.categoryScroll.hidden?(stableTop+48.0):(stableTop+4.0+44.0+6.0+MAX(44.0,CGRectGetHeight(self.categoryScroll.bounds)));
    CGFloat effectiveCategoryBottom=rawCategoryBottom>0?MIN(rawCategoryBottom,deterministicCategoryBottom):deterministicCategoryBottom;
    CGFloat overlay=MAX(self.view.safeAreaInsets.top+54,CGRectGetMaxY(self.categoryScroll.frame)+6);
    overlay=MAX(stableTop+54,effectiveCategoryBottom+6);
    BOOL hero=NO;for(NSDictionary *section in [(MediaFeedView *)self.grid sections])if([section[@"kind"] isEqual:@"hero"]){hero=YES;break;}
    UIEdgeInsets next=UIEdgeInsetsMake(self.homeMode&&hero?0:overlay,0,MAX(self.bottomOverlayInset,self.view.safeAreaInsets.bottom)+84,0);
    if(!UIEdgeInsetsEqualToEdgeInsets(self.grid.contentInset,next)){BOOL atTop=self.grid.contentOffset.y<=-self.grid.contentInset.top+1;self.grid.contentInset=next;if(atTop&&!self.hasNavigationReturnPosition)[self.grid setContentOffset:CGPointMake(0,-next.top) animated:NO];}self.grid.scrollIndicatorInsets=UIEdgeInsetsMake(overlay,0,self.bottomOverlayInset,0);self.floatingSearchBottomConstraint.constant=-(MAX(self.bottomOverlayInset,self.view.safeAreaInsets.bottom)+12);
    CGRect targetScrimFrame=CGRectMake(0,0,self.view.bounds.size.width,overlay+20);
    if(!CGRectEqualToRect(self.homeTopImmersiveScrim.frame,targetScrimFrame)){
        self.homeTopImmersiveScrim.frame=targetScrimFrame;
        self.homeTopGlassBlurView.frame=self.homeTopImmersiveScrim.bounds;
    }
    CGFloat progress=MIN(1,MAX(0,(self.grid.contentOffset.y+next.top)/120));CGFloat alpha=0.0*(hero?progress:0.0);self.homeTopGlassBlurView.alpha=0.0;self.homeTopGlassBlurView.hidden=YES;self.homeTopImmersiveScrim.alpha=0.0;self.homeTopImmersiveScrim.hidden=YES;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.homeTopImmersiveGradient.frame=self.homeTopImmersiveScrim.bounds;
    self.homeTopImmersiveGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:alpha].CGColor,(id)[UIColor colorWithWhite:0 alpha:alpha*.75].CGColor,(id)UIColor.clearColor.CGColor];
    [CATransaction commit];
}
- (void)selectFeedSection:(NSDictionary *)section {
    if(![section[@"sourceID"] isEqual:([self.source[@"id"] description]?:@"")]||![section[@"providerID"] isEqual:self.provider?:@""])return;
    NSString *category=section[@"categoryID"];if(category.length){[self selectMediaCategory:category];return;}NSString *action=section[@"action"];
    if([action isEqual:@"display-settings"])[self openHomeConfiguration];else if([action isEqual:@"history"])[self openHistory];else if([action isEqual:@"filters"])[self chooseFilters];else if([action isEqual:@"search"])[self openGlobalSearch];else if([action isEqual:@"resources"])[self performHomeStatusAction];else if([action isEqual:@"retry"])[self refreshMediaContent];
}
- (void)refreshMediaContent {
    [self.homeShelfAttempts removeAllObjects];self.forceVisibleShelfRefresh=YES;[self.categorySessions removeObjectForKey:[self categorySessionKey]];self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;
    if(!self.source){[self.grid.refreshControl endRefreshing];[self performHomeStatusAction];return;}
    self.generation++;[self.client cancel];[self.readiness cancel];self.loading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;
    if(!self.client||self.sourceInvalidated||(!MediaSourceUsesNativeCatalogAPI(self.source)&&![PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""])){[self saveCurrentBrowseState];[self activate:self.source keepingHome:self.homeMode];return;}
    if(self.serviceUnavailable){[self.grid.refreshControl endRefreshing];[self checkCurrentService];return;}
    if(self.homeMode){self.nextHomeLoadTrigger=@"media_pull_refresh";[self loadHome];}else{self.page=1;[self loadListing:NO];}
}
- (void)updateCategorySelection {
    for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.category]||([button.accessibilityIdentifier isEqual:@"__featured__"]&&self.homeMode);HostStylePillButton(button,selected);MediaBrowserApplyScaledPillFont(button);button.layer.cornerRadius=17;[button setTitleColor:selected?HostOnAccent():HostSecondaryText() forState:UIControlStateNormal];if(selected){button.backgroundColor=HostAccent();HostSetLayerBorderColor(button,HostAccent());}button.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);}
}
- (NSString *)categorySessionKey {return [NSString stringWithFormat:@"%@|%@",[self stateKeyForSource:self.source provider:self.provider],self.category?:@""];}
- (void)saveCategorySession {
    if(self.homeMode||!self.category.length||!self.items.count||self.loading)return;self.categorySessions[[self categorySessionKey]]=@{@"items":self.items?:@[],@"filters":self.selectedFilters?:@{},@"page":@(MAX(1,self.page)),@"hasMore":@(self.hasMore),@"offset":@(self.grid.contentOffset.y),@"savedAt":@(NSDate.date.timeIntervalSince1970)};
    while(self.categorySessions.count>12){NSString *oldest=nil;NSTimeInterval timestamp=DBL_MAX;for(NSString *key in self.categorySessions){NSTimeInterval value=[self.categorySessions[key][@"savedAt"] doubleValue];if(value<timestamp){timestamp=value;oldest=key;}}if(!oldest)break;[self.categorySessions removeObjectForKey:oldest];}
}
- (void)selectMediaCategory:(NSString *)identifier {
    if(!identifier.length){[self showHome:YES];return;}if(!self.homeMode&&[self.category isEqual:identifier])return;
    if(self.homeMode)[self saveHomeScrollOffset];else[self saveCategorySession];self.generation++;[self.client cancel];self.loading=NO;self.activeMediaOperation=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.visibleCategoryIDs=[NSSet set];self.homeMode=NO;self.category=identifier;self.keyword=@"";self.search.searchBar.text=@"";self.selectedFilters=[NSMutableDictionary dictionary];self.page=1;self.hasMore=NO;self.items=@[];self.status.text=@"";[self updateCategorySelection];[self notifyDisplayModeChanged];
    NSDictionary *saved=self.categorySessions[[self categorySessionKey]];if(saved&&NSDate.date.timeIntervalSince1970-[saved[@"savedAt"] doubleValue]>6*3600){[self.categorySessions removeObjectForKey:[self categorySessionKey]];saved=nil;}if(saved){self.items=saved[@"items"];self.selectedFilters=[saved[@"filters"] mutableCopy];self.page=[saved[@"page"] integerValue];self.hasMore=[saved[@"hasMore"] boolValue];[self.grid reloadData];[self updateMediaFeedInsets];[self.grid layoutIfNeeded];[self.grid setContentOffset:CGPointMake(0,[saved[@"offset"] doubleValue]) animated:NO];return;}
    [self.grid reloadData];[self updateMediaFeedInsets];[self.grid setContentOffset:CGPointMake(0,-self.grid.adjustedContentInset.top) animated:NO];[self loadListing:NO];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf=self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){MediaBrowserViewController *owner=weakSelf;if(owner.homeMode)[owner refreshHomeModules];}];
}

- (void)searchHistorySettingChanged:(NSNotification *)notification {if([notification.userInfo[@"enabled"] boolValue]&&![notification.userInfo[@"cleared"] boolValue])return;for(NSString *key in self.browseStates.allKeys.copy){NSMutableDictionary *state=[self.browseStates[key] mutableCopy];if(state){state[@"keyword"]=@"";self.browseStates[key]=state;}}if(self.pendingBrowseState){NSMutableDictionary *pending=[self.pendingBrowseState mutableCopy];pending[@"keyword"]=@"";self.pendingBrowseState=pending;}}
- (NSString *)homeScrollOffsetKeyForSource:(NSDictionary *)source {
    NSString *sourceID=[source[@"id"] description]?:@"",*provider=self.provider?:[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",sourceID]]?:@"";NSString *key=[NSString stringWithFormat:@"cctv.mediaHome.scrollOffset.v3.%lu:%@%lu:%@",(unsigned long)sourceID.length,sourceID,(unsigned long)provider.length,provider];
    if(![NSUserDefaults.standardUserDefaults objectForKey:key]){NSString *legacy=[NSString stringWithFormat:@"cctv.mediaHome.scrollOffset.v2.%lu:%@",(unsigned long)sourceID.length,sourceID];id offset=[NSUserDefaults.standardUserDefaults objectForKey:legacy];if(offset)[NSUserDefaults.standardUserDefaults setObject:offset forKey:key];}return key;
}
- (void)saveHomeScrollOffset {if(!self.homeScroll||!self.source)return;CGFloat y=self.homeScroll.contentOffset.y;[NSUserDefaults.standardUserDefaults setDouble:y forKey:[self homeScrollOffsetKeyForSource:self.source]];self.pendingHomeOffsetRestore=@(y);}
- (void)restoreHomeScrollOffsetIfNeeded {if(!self.homeMode||!self.pendingHomeOffsetRestore||self.homeScroll.bounds.size.height<=0)return;[self.grid layoutIfNeeded];CGFloat minimum=-self.homeScroll.adjustedContentInset.top;CGFloat maximum=MAX(minimum,self.homeScroll.contentSize.height-self.homeScroll.bounds.size.height+self.homeScroll.adjustedContentInset.bottom);self.homeScroll.contentOffset=CGPointMake(self.homeScroll.contentOffset.x,MIN(MAX(self.pendingHomeOffsetRestore.doubleValue,minimum),maximum));self.pendingHomeOffsetRestore=nil;}
- (void)saveSessionState {if(self.homeMode)[self saveHomeScrollOffset];else[self saveCategorySession];[self saveCurrentBrowseState];}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];[self saveSessionState];
    // 任意离页（含正常 push 详情/搜索）都取消在途请求会导致返回后重复请求与
    // 闪烁；只有真正离开（pop/dismiss）时才取消并标记恢复重载。
    BOOL leaving=self.isMovingFromParentViewController||self.isBeingDismissed||self.navigationController.isBeingDismissed;
    if(leaving&&(self.loading||self.homeShelfRequestInFlight||self.activeMediaOperation.length)){
        NSString *operation=self.activeMediaOperation.length?self.activeMediaOperation:(self.homeShelfRequestInFlight?@"home_shelf":@"readiness");self.cancelledMediaOperation=operation;self.cancelledMediaRequestWasAppend=self.activeMediaRequestAppend;self.resumeCancelledMediaRequestOnAppear=YES;self.generation++;self.homeShelfGeneration=0;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeShelfAttempts minusSet:self.homeCategoryLoadsInFlight];[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaRequestAppend=NO;self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;[self.readiness cancel];[self.client cancel];
        if(self.cancelledMediaRequestWasAppend&&( [operation isEqualToString:@"category"]||[operation isEqualToString:@"search"]))self.page=MAX(1,self.page-1);
        if(!self.homeMode)[self saveCurrentBrowseState];else self.nextHomeLoadTrigger=nil;[self updateSelectionControls];
        [RuntimeDiagnostics.shared recordEvent:@"media_request_cancelled_on_page_exit" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"", @"operation":operation, @"reason":@"parent_page_disappeared", @"correlation_id":self.diagnosticTraceID?:@""}];
    }
}
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.watchHistoryLookup=nil;
    if(self.foregroundCheckNeeded){[self resumeAfterForeground];return;}
    if(self.resumeCancelledMediaRequestOnAppear){self.resumeCancelledMediaRequestOnAppear=NO;NSString *operation=self.cancelledMediaOperation?:@"";BOOL wasAppend=self.cancelledMediaRequestWasAppend;self.cancelledMediaOperation=nil;
        [RuntimeDiagnostics.shared recordEvent:@"media_request_resumed_after_page_return" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"", @"operation":operation, @"append":@(wasAppend), @"correlation_id":self.diagnosticTraceID?:@""}];
        if([operation isEqualToString:@"capabilities"]||[operation isEqualToString:@"providers"]){[self loadCapabilities];return;}
        if([operation isEqualToString:@"home"]){self.nextHomeLoadTrigger=@"page_return";[self loadHome];return;}
        if([operation isEqualToString:@"home_shelf"]){[self refreshHomeModules];[self loadVisibleHomeShelves];return;}
        if([operation isEqualToString:@"category"]||[operation isEqualToString:@"search"]){self.cancelledMediaRequestWasAppend=NO;if(wasAppend){self.page++;[self loadListing:YES];}else[self loadListing:NO];return;}
        self.cancelledMediaRequestWasAppend=NO;
        if(self.source)[self activate:self.source keepingHome:YES];return;
    }
    [self syncStableTopHeaderLayout];
    [self updateMediaFeedInsets];
    if(self.homeMode)[self refreshHomeModules];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated];HostStyleNavigation(self.navigationController);if(self.navigationController.navigationBarHidden)self.navigationController.navigationBar.prefersLargeTitles=NO;[self refreshHeaderAfterNavigationTransition];[self loadVisibleHomeShelves]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        HostStyleNavigation(self.navigationController);
        HostRefreshAppearanceLayers(self.view.window);
    }
    if(previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self.grid.collectionViewLayout invalidateLayout];
        [self.grid reloadData];
        [self updateHomeGridLayout];
    }
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updateMediaFeedInsets];}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.view.backgroundColor=HostBackground();self.title=@"";self.items=@[];self.keyword=@"";self.contentMode=MediaContentModeFeatured;self.homeCategoryLoadsInFlight=[NSMutableSet set];self.homeShelfAttempts=[NSMutableSet set];self.categorySessions=[NSMutableDictionary dictionary];self.visibleCategoryIDs=[NSSet set];
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];self.browseStates=[saved mutableCopy]?:[NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(searchHistorySettingChanged:) name:@"MediaGlobalSearchHistoryDidChange" object:nil];
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.status=[UILabel new];self.readinessStageLabel=[UILabel new];self.resourceButton=[UIButton buttonWithType:UIButtonTypeSystem];self.moreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    MediaFeedView *feed=[[MediaFeedView alloc] initWithFrame:CGRectZero];feed.translatesAutoresizingMaskIntoConstraints=NO;feed.backgroundColor=HostBackground();feed.accessibilityIdentifier=@"media-unified-feed";feed.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.grid=feed;self.homeScroll=feed;[self.view addSubview:feed];
    __weak typeof(self) weakSelf=self;
    feed.sectionsProvider=^NSArray *{return [weakSelf mediaFeedSections]?:@[];};
    feed.onSelectItem=^(NSDictionary *item,NSDictionary *section){MediaBrowserViewController *owner=weakSelf;if(!owner)return;NSDictionary *history=item[@"__historyEntry"];if(history){[owner openHistoryEntry:history];return;}if(![section[@"sourceID"] isEqual:([owner.source[@"id"] description]?:@"")]||![section[@"providerID"] isEqual:owner.provider?:@""])return;[owner openHomeRecommendation:item source:section[@"source"] provider:section[@"providerID"]];};
    feed.onSelectSection=^(NSDictionary *section){[weakSelf selectFeedSection:section];};
    feed.onScroll=^(UIScrollView *scroll){[weakSelf scrollViewDidScroll:scroll];};
    feed.onNearEnd=^{MediaBrowserViewController *owner=weakSelf;if(owner&&!owner.homeMode)[owner loadMore];};
    feed.onVisibleCategories=^(NSArray *identifiers){MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.visibleCategoryIDs=[NSSet setWithArray:identifiers];[owner loadVisibleHomeShelves];};
    UIRefreshControl *refresh=[UIRefreshControl new];refresh.tintColor=HostAccent();[refresh addTarget:self action:@selector(refreshMediaContent) forControlEvents:UIControlEventValueChanged];feed.refreshControl=refresh;
    self.homeTopImmersiveScrim=[UIView new];self.homeTopImmersiveScrim.userInteractionEnabled=NO;self.homeTopImmersiveScrim.backgroundColor=UIColor.clearColor;self.homeTopImmersiveScrim.alpha=0.0;self.homeTopImmersiveScrim.hidden=YES;self.homeTopGlassBlurView=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];self.homeTopGlassBlurView.userInteractionEnabled=NO;self.homeTopGlassBlurView.alpha=0.0;self.homeTopGlassBlurView.hidden=YES;[self.homeTopImmersiveScrim addSubview:self.homeTopGlassBlurView];self.homeTopImmersiveGradient=[CAGradientLayer layer];self.homeTopImmersiveGradient.locations=@[@0,@0.68,@1];self.homeTopImmersiveGradient.opacity=0.0f;[self.homeTopImmersiveScrim.layer addSublayer:self.homeTopImmersiveGradient];[self.view addSubview:self.homeTopImmersiveScrim];
    self.selectionRow=[UIStackView new];self.selectionRow.translatesAutoresizingMaskIntoConstraints=NO;self.selectionRow.axis=UILayoutConstraintAxisHorizontal;self.selectionRow.spacing=8;self.selectionRow.alignment=UIStackViewAlignmentCenter;[self.view addSubview:self.selectionRow];
    self.sourceSelectButton=[self selectionButtonWithSymbol:@"square.stack.3d.up" identifier:@"media-source-selector" action:@selector(chooseResource)];self.providerSelectButton=[self selectionButtonWithSymbol:@"globe" identifier:@"media-provider-selector" action:@selector(chooseProvider)];
    [self.selectionRow addArrangedSubview:self.sourceSelectButton];[self.selectionRow addArrangedSubview:self.providerSelectButton];
    self.homeMenuButton=[self homeToolbarButtonWithSymbol:@"person.crop.circle" identifier:@"media-my-button" label:@"我的收藏与观看历史" action:NULL];self.homeMenuButton.menu=[self homeActionsMenu];self.homeMenuButton.showsMenuAsPrimaryAction=YES;[self.selectionRow addArrangedSubview:self.homeMenuButton];
    self.categoryScroll=[UIScrollView new];self.categoryScroll.translatesAutoresizingMaskIntoConstraints=NO;self.categoryScroll.showsHorizontalScrollIndicator=NO;self.categoryScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.categoryScroll.contentInset=UIEdgeInsetsMake(0,0,0,14);[self.view addSubview:self.categoryScroll];
    self.categories=[UIStackView new];self.categories.translatesAutoresizingMaskIntoConstraints=NO;self.categories.axis=UILayoutConstraintAxisHorizontal;self.categories.alignment=UIStackViewAlignmentCenter;self.categories.spacing=8;[self.categoryScroll addSubview:self.categories];self.categoryScrollHeightConstraint=[self.categoryScroll.heightAnchor constraintGreaterThanOrEqualToConstant:0];
    self.floatingHomeSearchButton=[self floatingButtonWithSymbol:@"magnifyingglass" identifier:@"media-home-floating-search" action:@selector(openGlobalSearch)];self.floatingHomeSearchButton.accessibilityLabel=@"搜索影视";self.floatingHomeSearchButton.backgroundColor=HostAccent();self.floatingHomeSearchButton.tintColor=UIColor.whiteColor;self.floatingHomeSearchButton.clipsToBounds=NO;self.floatingHomeSearchButton.layer.shadowColor=UIColor.blackColor.CGColor;self.floatingHomeSearchButton.layer.shadowOpacity=.3;self.floatingHomeSearchButton.layer.shadowRadius=12;self.floatingHomeSearchButton.layer.shadowOffset=CGSizeMake(0,4);[self.view addSubview:self.floatingHomeSearchButton];
    self.floatingSearchBottomConstraint=[self.floatingHomeSearchButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-100];
    [NSLayoutConstraint activateConstraints:@[
        [feed.topAnchor constraintEqualToAnchor:self.view.topAnchor],[feed.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[feed.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[feed.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        (self.selectionRowTopConstraint=[self.selectionRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4]),[self.selectionRow.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:14],[self.selectionRow.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14],[self.selectionRow.heightAnchor constraintEqualToConstant:44],
        [self.sourceSelectButton.widthAnchor constraintEqualToAnchor:self.providerSelectButton.widthAnchor multiplier:1.15],[self.sourceSelectButton.heightAnchor constraintEqualToConstant:44],[self.providerSelectButton.heightAnchor constraintEqualToConstant:44],[self.homeMenuButton.widthAnchor constraintEqualToConstant:44],[self.homeMenuButton.heightAnchor constraintEqualToConstant:44],
        [self.categoryScroll.topAnchor constraintEqualToAnchor:self.selectionRow.bottomAnchor constant:6],[self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],self.categoryScrollHeightConstraint,
        [self.categories.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor constant:14],[self.categories.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor constant:-14],[self.categories.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor],[self.categories.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor],[self.categories.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.floatingHomeSearchButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-18],self.floatingSearchBottomConstraint,[self.floatingHomeSearchButton.widthAnchor constraintEqualToConstant:56],[self.floatingHomeSearchButton.heightAnchor constraintEqualToConstant:56]]];
    [self loadSources];[self updateMediaFeedInsets];[self notifyDisplayModeChanged];
}
- (void)setBottomOverlayInset:(CGFloat)inset {
    _bottomOverlayInset=isfinite(inset)?MAX(0,inset):0;if(self.isViewLoaded)[self updateMediaFeedInsets];
}
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);HostStyleGlassCard(button,22);button.contentEdgeInsets=UIEdgeInsetsMake(8,13,8,13);button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15] maximumPointSize:19];button.titleLabel.adjustsFontForContentSizeCategory=NO;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.82;button.accessibilityIdentifier=identifier;button.isAccessibilityElement=YES;button.accessibilityTraits|=UIAccessibilityTraitButton;UIImageSymbolConfiguration *symCfg=[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];[button setImage:[UIImage systemImageNamed:symbol withConfiguration:symCfg]?:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostAccent();button.layer.shadowColor=UIColor.blackColor.CGColor;button.layer.shadowOpacity=0.14;button.layer.shadowRadius=8.0;button.layer.shadowOffset=CGSizeMake(0,3);button.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,7);[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (UIButton *)homeToolbarButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier label:(NSString *)label action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(button,22);HostInstallPressFeedback(button);button.accessibilityIdentifier=identifier;button.accessibilityLabel=label;button.isAccessibilityElement=YES;button.accessibilityTraits=UIAccessibilityTraitButton;button.tintColor=HostText();button.imageView.contentMode=UIViewContentModeScaleAspectFit;button.showsMenuAsPrimaryAction=NO;UIImageSymbolConfiguration *symCfg=[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];[button setImage:[UIImage systemImageNamed:symbol withConfiguration:symCfg]?:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    if(action)[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UIButton *)floatingButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);button.layer.cornerRadius=28;button.layer.cornerCurve=kCACornerCurveContinuous;button.clipsToBounds=YES;button.backgroundColor=HostGlassTint();HostSetLayerBorderColor(button,HostBorder());button.layer.borderWidth=0.7;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostText();button.accessibilityIdentifier=identifier;button.isAccessibilityElement=YES;button.accessibilityTraits|=UIAccessibilityTraitButton;if(action)[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (UIMenu *)homeActionsMenu {
    __weak typeof(self) weakSelf=self;
    return [UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"收藏" image:[UIImage systemImageNamed:@"heart"] identifier:nil handler:^(UIAction *a){[weakSelf openFavorites];}],[UIAction actionWithTitle:@"观看历史" image:[UIImage systemImageNamed:@"clock"] identifier:nil handler:^(UIAction *a){[weakSelf openHistory];}]]];
}
- (void)pushMediaPage:(UIViewController *)page {
    if(!page||!self.navigationController)return;
    [self prepareForNavigationTransition];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    [self.navigationController pushViewController:page animated:YES];
}
- (void)updateSelectionControls {
    NSString *sourceCatalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");
    if(!self.selectedCatalogID.length&&sourceCatalogID.length)self.selectedCatalogID=sourceCatalogID;
    NSDictionary *catalog=[self selectedCatalog];NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"";
    NSString *sourceName=[self.source[@"name"] isKindOfClass:NSString.class]?self.source[@"name"]:@"";
    BOOL sourceBelongsToCatalog=catalogName.length&&[sourceCatalogID isEqual:catalog[@"id"]];
    NSString *sourceTitle=catalogName.length?catalogName:(sourceName.length?sourceName:@"选择影视资源或合集");
    [self.sourceSelectButton setTitle:[NSString stringWithFormat:@"%@  ▾",sourceTitle] forState:UIControlStateNormal];
    self.sourceSelectButton.accessibilityLabel=sourceTitle.length?[NSString stringWithFormat:@"影视资源：%@，点按切换",sourceTitle]:@"选择影视资源或合集";
    self.sourceSelectButton.accessibilityHint=@"打开影视资源合集；只在二级列表中加载所选站点";
    NSString *providerTitle=sourceBelongsToCatalog?sourceName:nil;
    NSString *providerID=self.provider;
    NSString *savedProviderKey=[NSString stringWithFormat:@"mediaProvider.%@",self.source[@"id"]?:@""];
    NSString *savedProviderID=[NSUserDefaults.standardUserDefaults stringForKey:savedProviderKey];
    if(!providerID.length)providerID=savedProviderID;
    for(NSDictionary *candidate in self.providers){if([candidate[@"id"] isEqual:providerID]){providerTitle=[candidate[@"name"] isKindOfClass:NSString.class]?candidate[@"name"]:candidate[@"id"];break;}}
    if(!providerTitle.length&&providerID.length){
        NSString *savedName=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProviderName.%@",self.source[@"id"]?:@""]];
        providerTitle=[savedProviderID isEqualToString:providerID]&&savedName.length?savedName:providerID;
    }
    BOOL directAPI=MediaSourceUsesNativeCatalogAPI(self.source)&&!catalogName.length;
    BOOL singleMacCMS=[catalog[@"catalogKind"] isEqual:@"maccms"]&&([catalog[@"sites"] isKindOfClass:NSArray.class]?[catalog[@"sites"] count]:0)<=1;
    NSArray *capabilities=[self.source[@"capabilities"] isKindOfClass:NSArray.class]?self.source[@"capabilities"]:@[];
    BOOL knownSingleSite=capabilities.count>0&&![capabilities containsObject:@"providers"]&&!self.providers.count;
    NSString *emptySiteTitle=catalogName.length?@"选择站点":(!self.source?@"选择站点":(self.pendingProviderPickerAfterLoad?@"正在读取站点…":(knownSingleSite?@"单站点资源":(self.loading?@"加载站点…":(!capabilities.count||[capabilities containsObject:@"providers"]||!self.client||self.sourceInvalidated?@"选择站点":@"单站点资源")))));
    NSString *siteTitle=directAPI?@"单站点资源":(singleMacCMS?@"切换采集站":(providerTitle.length?providerTitle:emptySiteTitle));
    self.providerSelectButton.hidden=NO;
    BOOL catalogSelector=catalogName.length>0;
    [self.providerSelectButton setTitle:[NSString stringWithFormat:@"%@%@",siteTitle,(directAPI||(!catalogSelector&&!self.source))?@"":@"  ▾"] forState:UIControlStateNormal];
    self.providerSelectButton.enabled=catalogSelector||(!directAPI&&self.source!=nil&&!(self.pendingProviderPickerAfterLoad&&self.loading));
    self.providerSelectButton.alpha=self.providerSelectButton.enabled?1.0:0.62;
    self.providerSelectButton.accessibilityLabel=directAPI?@"此资源为单站点接口":(providerTitle.length?[NSString stringWithFormat:@"内部站点：%@，点按切换",providerTitle]:@"选择内部站点");
    self.providerSelectButton.accessibilityHint=catalogSelector?@"打开此合集中的站点列表；只加载点选的站点":(self.pendingProviderPickerAfterLoad?@"正在准备并读取站点列表":(self.providers.count?@"打开当前影视资源的站点列表":@"点按后按需准备资源并读取站点列表"));
}
- (BOOL)isHomeMode {return self.contentMode==MediaContentModeFeatured;}
- (void)setHomeMode:(BOOL)homeMode {self.contentMode=homeMode?MediaContentModeFeatured:MediaContentModeCategory;}
- (void)setBrowseControlsHidden:(BOOL)hidden {
    self.navigationItem.searchController=nil;self.navigationItem.rightBarButtonItems=nil;self.navigationItem.prompt=nil;self.grid.hidden=NO;self.categoryScroll.hidden=self.categories.arrangedSubviews.count==0;self.categoryScrollHeightConstraint.constant=self.categoryScroll.hidden?0:44;[self updateMediaFeedInsets];[self.grid reloadData];
}
- (void)toggleHomeBrowse {[self showHome:YES];}
- (void)notifyDisplayModeChanged {if(self.onDisplayModeChanged)self.onDisplayModeChanged(self.homeMode);}
- (void)showHome:(BOOL)animated {
    if(!self.homeMode){[self saveCategorySession];self.generation++;[self.client cancel];self.loading=NO;self.activeMediaOperation=nil;}self.status.text=@"";self.homeStatusLoading=NO;self.homeMode=YES;[self.grid.refreshControl endRefreshing];self.category=nil;self.keyword=@"";self.selectedFilters=[NSMutableDictionary dictionary];self.title=@"";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;[self setBrowseControlsHidden:YES];[self updateCategorySelection];[self notifyDisplayModeChanged];
    self.pendingHomeOffsetRestore=[NSUserDefaults.standardUserDefaults objectForKey:[self homeScrollOffsetKeyForSource:self.source]];[self restoreHomeScrollOffsetIfNeeded];
    [self refreshHomeModules];
    if(animated)[UIView transitionWithView:self.homeScroll duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
}
- (void)showBrowse:(BOOL)animated {
    self.homeMode=NO;self.title=@"";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;[self setBrowseControlsHidden:NO];[self notifyDisplayModeChanged];
    if(self.source && (!self.client||!self.source[@"capabilities"]||self.sourceInvalidated||(!MediaSourceUsesNativeCatalogAPI(self.source)&&![PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""]))){[self activate:self.source keepingHome:NO];}
    else if(!self.source){self.items=@[];[self.grid reloadData];[self showMessage:@"尚未导入影视资源，请先在资源页导入并启用影视包" loading:NO];}
    else if(self.pendingBrowseState){[self restorePendingBrowseState];}
    if(animated)[UIView transitionWithView:self.grid duration:0.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:nil completion:nil];
}

- (void)updateHomeGridLayout {[self.grid reloadData];[self updateMediaFeedInsets];}
- (void)updateVisibleHomePosters {[self loadVisibleHomeShelves];}
- (BOOL)isHomePageVisible {
    if(!self.view.window||self.view.hidden||self.homeScroll.hidden)return NO;
    UIViewController *top=self.navigationController.topViewController;
    return top==self||top==self.parentViewController;
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {if(scrollView==self.homeScroll)[self saveHomeScrollOffset];}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {if(scrollView==self.homeScroll&&!decelerate)[self saveHomeScrollOffset];}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView==self.homeScroll){
        [self updateMediaFeedInsets];
        [self updateVisibleHomePosters];
        CGFloat offset=scrollView.contentOffset.y+scrollView.adjustedContentInset.top;
        CGFloat collapseProgress=MIN(1.0,MAX(0.0,(offset-24.0)/96.0));
        self.selectionRow.alpha=1.0-collapseProgress*0.18;
    }
}
- (NSDictionary *)cachedHomeResultForSelectedProvider:(NSString **)providerOut {
    if(!self.source)return nil;
    NSString *provider=self.provider.length?self.provider:[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",self.source[@"id"]?:@""]];
    if(providerOut)*providerOut=provider?:@"";
    NSString *sourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:@"";
    if(self.homeResult&&[self.homeResultSourceID isEqualToString:sourceID]&&[(self.homeResultProvider?:@"") isEqualToString:(provider?:@"")])return self.homeResult;
    NSMutableDictionary *arguments=[NSMutableDictionary dictionary];if(provider.length)arguments[@"provider"]=provider;
    id result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:arguments maximumAge:DBL_MAX isStale:NULL];
    if(![result isKindOfClass:NSDictionary.class])return nil;NSMutableDictionary *normalized=[result mutableCopy];normalized[@"items"]=MediaBrowserDictionaryRows(result[@"items"],NULL);normalized[@"categories"]=MediaBrowserDictionaryRows(result[@"categories"],NULL);if(![normalized[@"filters"] isKindOfClass:NSDictionary.class])normalized[@"filters"]=@{};return normalized;
}
- (void)clearHomeResult {self.homeResult=nil;self.homeResultSourceID=nil;self.homeResultProvider=nil;}
- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories index:(NSUInteger)index generation:(NSUInteger)generation sourceID:(NSString *)sourceID provider:(NSString *)provider {
    NSUInteger limit=MIN((NSUInteger)8,categories.count);
    if(index>=limit){self.homeShelfQueueActive=NO;return;}
    if(!self.client||self.homeShelfRequestInFlight||self.generation!=generation||self.homeShelfGeneration!=generation||
       ![[self.source[@"id"] description] isEqual:sourceID]||![(self.provider?:@"") isEqual:provider]||!self.isHomePageVisible){self.homeShelfQueueActive=NO;return;}
    NSDictionary *category=categories[index];NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?[category[@"id"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    NSString *name=[category[@"name"] isKindOfClass:NSString.class]?[category[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(!identifier.length||!name.length){[self loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];return;}
    if(![self.visibleCategoryIDs containsObject:identifier]||[self.homeShelfAttempts containsObject:identifier]){self.homeShelfQueueActive=NO;return;}
    [self.homeShelfAttempts addObject:identifier];
    NSDictionary *arguments=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];BOOL stale=NO;
    id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:arguments maximumAge:6*3600 isStale:&stale];
    NSUInteger cachedCount=[cached isKindOfClass:NSDictionary.class]&&[cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0;
    [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_cache_decision" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":sourceID,@"provider_id":provider?:@"",@"category_index":@(index),@"cache_hit":@([cached isKindOfClass:NSDictionary.class]),@"cache_stale":@(stale),@"cached_item_count":@(cachedCount),@"refresh_skipped":@([cached isKindOfClass:NSDictionary.class]&&!stale)}];
    if(cached&&!stale&&!self.forceVisibleShelfRefresh){[self loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];return;}
    CFTimeInterval started=CACurrentMediaTime();__weak typeof(self) weakSelf=self;self.homeShelfQueueActive=YES;self.homeShelfRequestInFlight=YES;[self.homeCategoryLoadsInFlight addObject:identifier];self.activeMediaOperation=@"home_shelf";
    [self.client call:@"category" arguments:arguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner.homeCategoryLoadsInFlight removeObject:identifier];if(owner.homeShelfGeneration==generation){owner.homeShelfRequestInFlight=NO;if([owner.activeMediaOperation isEqualToString:@"home_shelf"])owner.activeMediaOperation=nil;}if(owner.generation!=generation||!owner.homeMode||![[owner.source[@"id"] description] isEqual:sourceID]||![(owner.provider?:@"") isEqual:provider]){NSString *reason=owner.generation!=generation?@"superseded_generation":(!owner.homeMode?@"home_mode_changed":(![[owner.source[@"id"] description] isEqual:sourceID]?@"source_changed":@"provider_changed"));[RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":reason}];return;}
        NSTimeInterval elapsed=MAX(0,CACurrentMediaTime()-started);
        if(!error&&[result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class]){
            NSMutableDictionary *normalized=[result mutableCopy];normalized[@"items"]=MediaBrowserDictionaryRows(result[@"items"],NULL);[[MediaMetadataCache shared] storeResult:normalized forSource:owner.source operation:@"category" arguments:arguments];
            [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"item_count":@(([result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class])?[result[@"items"] count]:0),@"elapsed_ms":@((NSInteger)(elapsed*1000))}];
        }else{
            [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"elapsed_ms":@((NSInteger)(elapsed*1000)),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
        }
        if(owner.isHomePageVisible)[owner refreshHomeModules];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(15*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{MediaBrowserViewController *page=weakSelf;if(page)[page loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];});
    }];
}
- (void)updateHomeStatusCard {if(self.isViewLoaded)[self refreshHomeModules];}
- (void)performHomeStatusAction {if(!self.source){if([self selectedCatalog])[self chooseCatalogProvider];else[self openResources];return;}if(self.serviceUnavailable){[self restartCurrentService];return;} NSString *diagnostics=[NSString stringWithFormat:@"%@ %@",self.status.text?:@"",self.readinessStageLabel.text?:@""];BOOL failed=NO;for(NSString *marker in @[@"失败",@"超时",@"错误",@"无法",@"无效",@"不可用",@"移除",@"failed",@"timeout",@"error",@"refused",@"not found"]){if([diagnostics localizedCaseInsensitiveContainsString:marker]){failed=YES;break;}} BOOL active=MediaSourceUsesNativeCatalogAPI(self.source)||[PyHost isRunningServiceIdentifier:self.source[@"id"]?:@""]; if(!active||self.sourceInvalidated||failed){self.nextHomeLoadTrigger=@"home_status_action";[self activate:self.source keepingHome:YES];return;}[self refreshMediaContent];}
- (void)loadVisibleHomeShelves {
    if(!self.homeMode||self.loading||self.homeShelfRequestInFlight||self.homeShelfQueueActive||!self.client||!self.isHomePageVisible)return;
    for(NSUInteger index=0;index<MIN((NSUInteger)8,self.homeCategories.count);index++){NSString *identifier=self.homeCategories[index][@"id"];if(![self.visibleCategoryIDs containsObject:identifier]||[self.homeShelfAttempts containsObject:identifier])continue;NSDictionary *args=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];BOOL stale=NO;id cached=[MediaMetadataCache.shared resultForSource:self.source operation:@"category" arguments:args maximumAge:6*3600 isStale:&stale];if(cached&&!stale&&!self.forceVisibleShelfRefresh)continue;self.homeShelfGeneration=self.generation;self.homeShelfQueueActive=YES;[self loadHomeShelves:self.homeCategories index:index generation:self.generation sourceID:[self.source[@"id"] description]?:@"" provider:self.provider?:@""];return;}
}
- (void)refreshHomeModules {
    if(self.homeRebuildScheduled||!self.isViewLoaded)return;self.homeRebuildScheduled=YES;__weak typeof(self) weakSelf=self;
    id<UIViewControllerTransitionCoordinator> coordinator=self.navigationController.transitionCoordinator;
    if(coordinator&&[(MediaFeedView *)self.grid sections].count>0){
        [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
            MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.homeRebuildScheduled=NO;
            if(!context.isCancelled)[owner rebuildHomeModulesNow];
        }];
        return;
    }
    dispatch_async(dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.homeRebuildScheduled=NO;[owner rebuildHomeModulesNow];});
}
- (void)rebuildHomeModulesNow {
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_modules_rebuild_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"content_mode":self.homeMode?@"featured":@"category"}];
    CGPoint preservedOffset=self.grid.contentOffset;
    BOOL hadSections=[(MediaFeedView *)self.grid sections].count>0;
    [self.grid reloadData];[self updateMediaFeedInsets];[self restoreHomeScrollOffsetIfNeeded];
    if(hadSections&&!self.pendingHomeOffsetRestore&&self.grid.bounds.size.height>0){
        CGFloat minimum=-self.grid.adjustedContentInset.top;
        CGFloat maximum=MAX(minimum,self.grid.contentSize.height-self.grid.bounds.size.height+self.grid.adjustedContentInset.bottom);
        CGPoint clamped=CGPointMake(preservedOffset.x,MIN(MAX(preservedOffset.y,minimum),maximum));
        if(fabs(self.grid.contentOffset.y-clamped.y)>0.5)[self.grid setContentOffset:clamped animated:NO];
    }
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_modules_rebuild_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"section_count":@([(MediaFeedView *)self.grid sections].count)}];
}
- (void)openGlobalSearchFromHome {[self openGlobalSearch];}
- (void)browseRecommendations {[self showHome:YES];}
- (void)pushMediaDetail:(MediaDetailViewController *)detail {
    if(!detail)return;
    if(self.homeShelfRequestInFlight||[self.activeMediaOperation isEqualToString:@"home_shelf"]){
        self.homeShelfGeneration=0;
        self.homeShelfRequestInFlight=NO;
        self.homeShelfQueueActive=NO;
        [self.homeShelfAttempts minusSet:self.homeCategoryLoadsInFlight];
        [self.homeCategoryLoadsInFlight removeAllObjects];
        if([self.activeMediaOperation isEqualToString:@"home_shelf"])self.activeMediaOperation=nil;
        [self.client cancelWithReason:@"yield_to_detail_request"];
    }
    __weak typeof(self) weakSelf=self;
    __weak MediaDetailViewController *weakDetail=detail;
    detail.onPlay=^(NSDictionary *result,NSDictionary *context){MediaDetailViewController *owner=weakDetail;if(owner)[owner showInlinePlaybackResult:result context:context];};
    detail.onReturnHome=^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;if([owner.navigationController.viewControllers containsObject:owner])[owner.navigationController popToViewController:owner animated:YES];else if(owner.parentViewController&&[owner.navigationController.viewControllers containsObject:owner.parentViewController])[owner.navigationController popToViewController:owner.parentViewController animated:YES];else[owner.navigationController popToRootViewControllerAnimated:YES];};
    [self pushMediaPage:detail];
}
- (void)prepareDetailSource:(NSDictionary *)source completion:(dispatch_block_t)completion {
    if(MediaSourceUsesNativeCatalogAPI(source)||[PyHost isRunningServiceIdentifier:source[@"id"]?:@""]){completion();return;}
    if(!self.onActivateService){[self showMessage:@"请先在资源页启用此来源" loading:NO];return;}
    NSUInteger request=++self.detachedGeneration;[self.detachedReadiness cancel];UIViewController *requestingPage=self.navigationController.topViewController;__weak typeof(self) weakSelf=self;
    [self showMessage:[NSString stringWithFormat:@"正在准备 %@…",source[@"name"]?:@"影片来源"] loading:YES];
    self.onActivateService(source,^(NSError *error){MediaBrowserViewController *owner=weakSelf;if(!owner||owner.detachedGeneration!=request||owner.navigationController.topViewController!=requestingPage)return;if(error){[owner showMessage:error.localizedDescription loading:NO];return;}
        NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",source[@"port"]]];owner.detachedReadiness=[[LocalServiceReadiness alloc] initWithURL:url timeout:45 requiresHealthJSON:YES];
        [owner.detachedReadiness start:^(NSError *failure,NSTimeInterval elapsed){MediaBrowserViewController *page=weakSelf;if(!page||page.detachedGeneration!=request||page.navigationController.topViewController!=requestingPage)return;[page showMessage:failure.localizedDescription?:@"" loading:NO];if(!failure)completion();}];
    });
}
- (void)openHomeRecommendation:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    if(![item isKindOfClass:NSDictionary.class]||![source isKindOfClass:NSDictionary.class])return;if([self openMetadataSearchForItem:item])return;
    __weak typeof(self) weakSelf=self;[self prepareDetailSource:source completion:^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlaybackWillStart=owner.onPlaybackWillStart;[owner pushMediaDetail:detail];}];
}
- (void)browsePinnedSource:(NSDictionary *)source {self.pendingBrowseState=nil;self.provider=nil;self.nextHomeLoadTrigger=@"home_pinned_source";[self activate:source];}
- (void)reloadMediaDisplayConfigurationIfLoaded {
    if(!self.isViewLoaded)return;
    if(self.homeMode)[self refreshHomeModules];
    [self.grid.collectionViewLayout invalidateLayout];
    [self.grid reloadData];
}
- (UIViewController *)mediaDisplaySettingsViewController {
    MediaHomeConfigurationViewController *page=[MediaHomeConfigurationViewController new];page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];__weak typeof(self) weakSelf=self;page.onChange=^{[weakSelf reloadMediaDisplayConfigurationIfLoaded];};return page;
}
- (void)openHomeConfiguration {[self pushMediaPage:[self mediaDisplaySettingsViewController]];}
- (void)openHomeFavorite:(NSDictionary *)entry {
    NSDictionary *source=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:entry[@"sourceID"]]){source=candidate;break;}
    if(!source){[self showMessage:@"该收藏对应的来源已移除，请先在资源页恢复" loading:NO];return;}
    [self openHomeRecommendation:[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{} source:source provider:entry[@"provider"]?:@""];
}
- (void)openPendingHomeDetailForSource:(NSDictionary *)source provider:(NSString *)provider {
    NSDictionary *pending=self.pendingHomeDetail;if(![pending isKindOfClass:NSDictionary.class]||![[pending[@"source"][@"id"] description] isEqual:[source[@"id"] description]])return;
    NSDictionary *item=[pending[@"item"] isKindOfClass:NSDictionary.class]?pending[@"item"]:@{};self.pendingHomeDetail=nil;if([self openMetadataSearchForItem:item])return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];[self.detachedReadiness cancel];}
- (NSString *)stateKeyForSource:(NSDictionary *)source provider:(NSString *)provider {return [NSString stringWithFormat:@"%@|%@",source[@"id"]?:@"",provider?:@""];}
- (void)saveCurrentBrowseState {if(!self.source)return;if(!self.browseStates)self.browseStates=[NSMutableDictionary dictionary];NSString *key=[self stateKeyForSource:self.source provider:self.provider];NSString *keyword=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]&&[self.keyword isKindOfClass:NSString.class]?self.keyword:@"";if(keyword.length>256)keyword=[keyword substringToIndex:256];NSDictionary *filters=[self.selectedFilters isKindOfClass:NSDictionary.class]?self.selectedFilters:@{};self.browseStates[key]=@{@"mode":self.homeMode?@"featured":@"category",@"keyword":keyword,@"category":self.category?:@"",@"filters":filters,@"provider":self.provider?:@"",@"page":@(MAX(1,MIN(100,self.page))),@"season":@(MAX(1,self.widgetSeason)),@"episode":@(MAX(1,self.widgetEpisode)),@"offset":@(self.grid.contentOffset.y),@"savedAt":@(NSDate.date.timeIntervalSince1970)};while(self.browseStates.count>32){NSString *oldest=nil;double timestamp=DBL_MAX;for(NSString *candidate in self.browseStates){double value=[self.browseStates[candidate][@"savedAt"] doubleValue];if(value<timestamp){timestamp=value;oldest=candidate;}}if(!oldest)break;[self.browseStates removeObjectForKey:oldest];}[NSUserDefaults.standardUserDefaults setObject:self.browseStates forKey:@"media.browseStates.v1"];}
- (void)restorePendingBrowseState {NSDictionary *state=self.pendingBrowseState;self.pendingBrowseState=nil;if(!state)return;self.keyword=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]&&[state[@"keyword"] isKindOfClass:NSString.class]?state[@"keyword"]:@"";self.category=[state[@"category"] isKindOfClass:NSString.class]?state[@"category"]:@"";if(self.category.length){BOOL found=NO;for(NSDictionary *category in self.homeCategories)if([category[@"id"] isEqual:self.category]){found=YES;break;}if(!found){self.category=nil;self.homeMode=YES;self.pendingRestoreOffset=nil;[self updateCategorySelection];[self showMessage:@"此前分类已移除，请重新选择" loading:NO];return;}}self.selectedFilters=[state[@"filters"] isKindOfClass:NSDictionary.class]?[state[@"filters"] mutableCopy]:[NSMutableDictionary dictionary];self.pendingRestorePage=MAX(1,MIN(100,[state[@"page"] integerValue]));self.page=self.pendingRestorePage;self.widgetSeason=MAX(1,[state[@"season"] integerValue]);self.widgetEpisode=MAX(1,[state[@"episode"] integerValue]);self.pendingRestoreOffset=@([state[@"offset"] doubleValue]);self.search.searchBar.text=self.keyword;self.navigationItem.prompt=[self.source[@"protocol"] isEqual:@"widget-extractor"]?[NSString stringWithFormat:@"第 %ld 季 · 第 %ld 集",(long)self.widgetSeason,(long)self.widgetEpisode]:nil;for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.category];button.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:HostNeutralSurface();HostSetLayerBorderColor(button,selected?[HostAccent() colorWithAlphaComponent:0.42]:HostBorder());[button setTitleColor:selected?HostAccent():HostText() forState:UIControlStateNormal];}if(self.keyword.length||self.category.length){self.homeMode=NO;[self updateCategorySelection];[self notifyDisplayModeChanged];self.page=1;[self loadListing:NO];return;}self.pendingRestorePage=0;CGFloat offset=self.pendingRestoreOffset.doubleValue;self.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[self.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
- (void)openFavorites {
    MediaFavoritesViewController *page=[MediaFavoritesViewController new];__weak typeof(self) weakSelf=self;page.onSelect=^(NSDictionary *entry){[weakSelf openHomeFavorite:entry];};[self pushMediaPage:page];
}
- (void)openHistory {
    MediaWatchHistoryViewController *page=[MediaWatchHistoryViewController new];__weak typeof(self) weakSelf=self;
    page.onSelect=^(NSDictionary *entry){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHistoryEntry:entry];};
    [self pushMediaPage:page];
}
- (void)openHistoryEntry:(NSDictionary *)entry {
    NSDictionary *source=nil;NSArray *sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];for(NSDictionary *candidate in sources)if([candidate[@"id"] isEqual:entry[@"sourceID"]]){source=candidate;break;}
    if(!source){[self showMessage:@"观看记录对应的来源不可用，请先在资源页恢复" loading:NO];return;}
    __weak typeof(self) weakSelf=self;[self prepareDetailSource:source completion:^{[weakSelf openHistoryDetail:entry source:source provider:entry[@"provider"]?:@""];}];
}
- (void)openHistoryDetail:(NSDictionary *)entry source:(NSDictionary *)source provider:(NSString *)provider {
    NSDictionary *item=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};
    if([self openMetadataSearchForItem:item])return;
    id itemID=item[@"id"];if(![itemID isKindOfClass:NSString.class]&&![itemID isKindOfClass:NSNumber.class]){[self showMessage:@"观看记录缺少影片标识，无法重新打开详情" loading:NO];return;}
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.resumeEntry=entry;detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];
}
- (void)openResources {if(self.onResources)self.onResources();}
- (void)openGlobalSearch {
    [self openGlobalSearchForKeyword:nil excludingIndexSources:NO];
}
- (void)openGlobalSearchForKeyword:(NSString *)keyword excludingIndexSources:(BOOL)excludeIndexSources {
    MediaGlobalSearchViewController *page=[MediaGlobalSearchViewController new];NSArray *available=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];if(excludeIndexSources){NSMutableArray *playableSources=[NSMutableArray array];for(NSDictionary *source in available)if(![source[@"protocol"] isEqual:@"douban-index"])[playableSources addObject:source];available=playableSources.copy;}page.sources=available;if(!excludeIndexSources){page.currentSourceID=[self.source[@"id"] description];page.currentProviderID=self.provider?:@"";page.currentCatalogID=self.selectedCatalogID;}page.initialKeyword=keyword;page.onActivateService=self.onActivateService;__weak typeof(self) weakSelf=self;
    page.onSelectResult=^(NSDictionary *item,NSDictionary *source,NSString *provider){MediaBrowserViewController *owner=weakSelf;if(!owner)return;if([owner openMetadataSearchForItem:item])return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=owner.onPlay;detail.onPlaybackWillStart=owner.onPlaybackWillStart;[owner pushMediaDetail:detail];};
    [self pushMediaPage:page];
}
- (BOOL)openMetadataSearchForItem:(NSDictionary *)item {
    NSString *identifier=[item[@"id"] isKindOfClass:NSString.class]?item[@"id"]:@"";if(![identifier hasPrefix:@"msearch:"])return NO;NSString *keyword=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"";if(!keyword.length){NSArray *parts=[identifier componentsSeparatedByString:@"###"];if(parts.count>1)keyword=parts[1];}keyword=[keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!keyword.length){[self showMessage:@"豆瓣索引没有返回可搜索的片名" loading:NO];return YES;}NSArray *all=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];NSUInteger playableCount=0;for(NSDictionary *source in all)if(![source[@"protocol"] isEqual:@"douban-index"])playableCount++;if(!playableCount){[self showMessage:[NSString stringWithFormat:@"%@ 是片名索引，不提供视频流。请先导入一个点播源，再从此处搜索播放。",keyword] loading:NO];return YES;}[self openGlobalSearchForKeyword:keyword excludingIndexSources:YES];return YES;
}
- (void)presentPicker:(MediaSourcePicker *)picker {
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker];navigation.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();HostStyleNavigation(navigation);navigation.navigationBar.prefersLargeTitles=NO;navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;}
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)loadSources {
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=nil,*catalog=[self selectedCatalog];
    for(NSDictionary *source in self.sources){NSString *member=source[@"catalogID"]?:source[@"tvboxCatalogID"]?:@"";if([source[@"id"] isEqual:saved]&&(!catalog||[member isEqual:catalog[@"id"]])){selected=source;break;}}
    if(!selected&&!catalog&&self.sources.count)selected=self.sources.firstObject;
    if(!selected){self.source=nil;self.provider=nil;self.providers=@[];self.homeLoadDeferred=YES;[self updateSelectionControls];[self showMessage:catalog?@"请选择合集中的一个站点":@"尚未添加影视资源" loading:NO];return;}
    self.source=selected;self.pendingHomeOffsetRestore=[NSUserDefaults.standardUserDefaults objectForKey:[self homeScrollOffsetKeyForSource:selected]];NSString *provider=@"";NSDictionary *cached=[self cachedHomeResultForSelectedProvider:&provider];if(cached){self.provider=provider;[self applyHomeResult:cached];}
    [self updateSelectionControls];if(self.deferAutomaticLoading){self.homeLoadDeferred=YES;[self refreshHomeModules];return;}
    self.homeLoadDeferred=NO;[self activate:selected keepingHome:YES];
}
- (void)loadHomeOnDemand {
    if(!self.homeLoadDeferred)return;
    if(!self.source&&[self selectedCatalog]){self.nextHomeLoadTrigger=nil;[self chooseCatalogProvider];return;}
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
    if(!self.isViewLoaded)return;NSArray *updated=self.sourcesProvider?self.sourcesProvider():@[];self.sources=updated;
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"]?:@"";NSDictionary *current=nil;for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:self.source[@"id"]]){current=candidate;break;}
    if(current&&(!saved.length||[saved isEqual:current[@"id"]])){BOOL changed=![(current[@"packageRoot"]?:@"") isEqual:(self.source[@"packageRoot"]?:@"")]||![(current[@"api"]?:@"") isEqual:(self.source[@"api"]?:@"")];if(changed){[self.categorySessions removeAllObjects];[self saveSessionState];[self activate:current keepingHome:self.homeMode];}else{self.source=current;[self updateSelectionControls];[self refreshHomeModules];}return;}
    [self saveSessionState];self.generation++;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.client=nil;self.loading=NO;self.homeStatusLoading=NO;self.activeMediaOperation=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;self.source=nil;self.provider=nil;self.providers=@[];self.items=@[];self.homeCategories=@[];self.homeMode=YES;self.category=nil;self.keyword=@"";[self clearHomeResult];for(UIView *view in self.categories.arrangedSubviews.copy){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}self.deferAutomaticLoading=NO;[self loadSources];
}
- (void)returnToHomeFromNavigation { [self showHome:NO]; }
- (BOOL)refreshHomeContentFromResourcePage {if(!self.source){[self loadSources];return self.source!=nil;}[self refreshMediaContent];return YES;}
- (void)openSourceIdentifier:(NSString *)identifier {
    NSString *targetID=[identifier isKindOfClass:NSString.class]?[identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    if(!targetID.length){[self showMessage:@"没有指定影视来源" loading:NO];return;}
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    NSDictionary *target=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:targetID]){target=candidate;break;}
    if(!target){[self updateSelectionControls];[self showMessage:@"此来源已从资源合集移除，请回到资源页重新选择" loading:NO];return;}
    NSString *catalogID=[target[@"catalogID"] isKindOfClass:NSString.class]?target[@"catalogID"]:([target[@"tvboxCatalogID"] isKindOfClass:NSString.class]?target[@"tvboxCatalogID"]:@"");
    if(catalogID.length){self.selectedCatalogID=catalogID;[NSUserDefaults.standardUserDefaults setObject:catalogID forKey:@"selectedMediaCatalogID"];}else{self.selectedCatalogID=@"";[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];}
    [NSUserDefaults.standardUserDefaults setObject:targetID forKey:@"selectedMediaSource"];
    if([self.source[@"id"] isEqual:targetID] && (self.readiness!=nil || (self.loading && [self.activeMediaOperation isEqualToString:@"capabilities"]) || (self.loading && [self.activeMediaOperation isEqualToString:@"home"]))){
        [self updateSelectionControls];
        return;
    }
    self.nextHomeLoadTrigger=@"resource_list_open";
    [self activate:target];
}
- (void)showMessage:(NSString *)message loading:(BOOL)loading {
    NSString *clean=message?:@"";
    if([clean isEqualToString:@"AbortError"]||[clean localizedCaseInsensitiveContainsString:@"AbortError"]||[clean isEqualToString:@"The operation was aborted."]){
        NSString *sName=[self.source[@"name"] isKindOfClass:NSString.class]&&[self.source[@"name"] length]?self.source[@"name"]:@"当前站点";
        clean=[NSString stringWithFormat:@"连接「%@」超时（远端响应过慢或受网络环境限制），请重试或切换其他站点",sName];
    }
    self.status.text=clean;self.homeStatusLoading=loading;if(!loading)[self.grid.refreshControl endRefreshing];[self refreshHomeModules];
}
- (void)chooseResource {
    NSArray<NSDictionary *> *catalogs=self.catalogsProvider?self.catalogsProvider():@[];
    self.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];
    if(!self.sources.count&&!catalogs.count){[self openResources];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *source in self.sources){NSString *memberID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");if(memberID.length)continue;BOOL current=[source[@"id"] isEqual:self.source[@"id"]];NSString *engineValue=[source[@"engine"] isKindOfClass:NSString.class]?source[@"engine"]:@"";NSString *engine=engineValue.lowercaseString;NSString *scope=([engine containsString:@"python"]||[engine containsString:@"py"])?@"python":([engine containsString:@"node"])?@"node":([engine containsString:@"javascript"]||[engine isEqual:@"js"])?@"javascriptcore":@"other";NSString *scopeName=[scope isEqual:@"python"]?@"Python":([scope isEqual:@"node"]?@"Node.js":([scope isEqual:@"javascriptcore"]?@"JavaScriptCore":@"其他"));NSString *status=[source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"已导入";NSString *name=[source[@"name"] isKindOfClass:NSString.class]?source[@"name"]:@"影视资源";NSString *url=[source[@"url"] isKindOfClass:NSString.class]?source[@"url"]:@"";NSString *subtitle=[NSString stringWithFormat:@"%@ · %@%@",scopeName,current?@"当前资源 · ":@"",status];[choices addObject:@{@"name":name,@"subtitle":subtitle,@"url":url,@"source":source,@"scope":scope,@"scopeName":scopeName,@"selected":@(current)}];}
    for(NSDictionary *catalog in catalogs){NSString *catalogID=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";if(!catalogID.length)continue;NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];NSUInteger usable=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])usable++;for(NSDictionary *live in lives)if([live[@"supported"] boolValue])usable++;NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"资源合集";NSString *subtitle=[NSString stringWithFormat:@"一个资源站 · 按需选择 %lu 个内部站点/直播列表 · 点选后再加载",(unsigned long)usable];[choices addObject:@{@"name":catalogName,@"subtitle":subtitle,@"catalogID":catalogID,@"scope":@"catalog",@"scopeName":@"资源合集",@"selected":@([self.selectedCatalogID isEqual:catalogID])}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"选择影视资源或资源合集";[choices sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){BOOL first=[MediaHomePinnedSources() containsObject:a[@"source"][@"id"]?:@""],second=[MediaHomePinnedSources() containsObject:b[@"source"][@"id"]?:@""];return first==second?NSOrderedSame:(first?NSOrderedAscending:NSOrderedDescending);}];picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner)return;NSString *catalogID=[choice[@"catalogID"] isKindOfClass:NSString.class]?choice[@"catalogID"]:@"";if(catalogID.length){NSDictionary *catalog=nil;NSArray *availableCatalogs=owner.catalogsProvider?owner.catalogsProvider():@[];for(NSDictionary *item in availableCatalogs)if([item[@"id"] isEqual:catalogID]){catalog=item;break;}if(catalog)[owner selectCatalogResource:catalog];return;}NSDictionary *source=choice[@"source"];if(source){NSString *memberID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");owner.selectedCatalogID=memberID;owner.deferAutomaticLoading=NO;owner.homeLoadDeferred=NO;if(memberID.length)[NSUserDefaults.standardUserDefaults setObject:memberID forKey:@"selectedMediaCatalogID"];else[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=@"resource_selector";if(owner.homeMode)[owner activate:source keepingHome:YES];else[owner activate:source];}};[self presentPicker:picker];
}
- (NSDictionary *)selectedCatalog {
    if(!self.selectedCatalogID.length){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaCatalogID"];if(saved.length)self.selectedCatalogID=saved;}
    NSArray *catalogs=self.catalogsProvider?self.catalogsProvider():@[];for(NSDictionary *catalog in catalogs)if([catalog[@"id"] isEqual:self.selectedCatalogID])return catalog;return nil;
}
- (NSDictionary *)sourceForCatalogSite:(NSDictionary *)site catalog:(NSDictionary *)catalog {
    NSString *catalogID=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"",*key=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"",*apiKind=[site[@"apiKind"] isKindOfClass:NSString.class]?site[@"apiKind"]:@"";
    if(!self.sources)self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    NSString *nativeID=([apiKind isEqual:@"tvbox-api"]||[apiKind isEqual:@"maccms-api"]||[apiKind isEqual:@"douban-index"]||[apiKind isEqual:@"jar-bridge"])?[NSString stringWithFormat:@"%@:%@:%@",apiKind,catalogID,key]:@"";
    for(NSDictionary *source in self.sources){if(nativeID.length&&[source[@"id"] isEqual:nativeID])return source;NSString *sourceCatalog=[source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:([source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:@"");if(![sourceCatalog isEqual:catalogID])continue;NSArray *siteKeys=[source[@"tvboxSiteKeys"] isKindOfClass:NSArray.class]?source[@"tvboxSiteKeys"]:@[];if([source[@"tvboxSiteKey"] isEqual:key]||[siteKeys containsObject:key])return source;}
    return nil;
}
- (void)selectCatalogResource:(NSDictionary *)catalog {
    NSString *identifier=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";if(!identifier.length)return;
    [self saveCurrentBrowseState];self.selectedCatalogID=identifier;[NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"selectedMediaCatalogID"];
    NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];
    NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];
    if(([catalog[@"catalogKind"] isEqual:@"maccms"]||(sites.count==1&&!lives.count))&&sites.count==1){
        NSDictionary *onlySite=[sites.firstObject isKindOfClass:NSDictionary.class]?sites.firstObject:nil;
        NSDictionary *source=onlySite?[self sourceForCatalogSite:onlySite catalog:catalog]:nil;
        if(source&&[onlySite[@"supported"] boolValue]){
            self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;self.pendingProviderPickerAfterLoad=NO;
            self.nextHomeLoadTrigger=@"catalog_single_site_auto";
            [NSUserDefaults.standardUserDefaults setObject:source[@"id"]?:@"" forKey:@"selectedMediaSource"];
            [self activate:source keepingHome:YES];
            return;
        }
    }
    NSString *sourceCatalog=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");
    if(![sourceCatalog isEqual:identifier]){self.generation++;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.readiness=nil;self.client=nil;self.source=nil;self.provider=nil;self.providers=@[];self.loading=NO;self.homeStatusLoading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;self.homeLoadDeferred=YES;self.items=@[];self.homeCategories=@[];self.category=nil;self.keyword=@"";self.selectedFilters=[NSMutableDictionary dictionary];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaSource"];[self clearHomeResult];[self.grid reloadData];}
    self.deferAutomaticLoading=YES;[self updateSelectionControls];[self showMessage:[NSString stringWithFormat:@"已选择 %@ · 从二级胶囊选择内部站点",catalog[@"name"]?:@"资源合集"] loading:NO];
}
- (void)chooseCatalogProvider {
    NSDictionary *catalog=[self selectedCatalog];if(!catalog){self.selectedCatalogID=@"";[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];[self chooseProvider];return;}
    self.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];
    NSString *catalogID=catalog[@"id"]?:@"";NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];NSMutableArray *choices=[NSMutableArray array];
    if([catalog[@"catalogKind"] isEqual:@"maccms"]&&sites.count<=1&&!lives.count){
        NSArray *allCatalogs=self.catalogsProvider?self.catalogsProvider():@[];
        for(NSDictionary *macCat in allCatalogs){
            if(![macCat[@"catalogKind"] isEqual:@"maccms"])continue;
            NSString *macCatID=macCat[@"id"]?:@"";
            for(NSDictionary *macSite in ([macCat[@"sites"] isKindOfClass:NSArray.class]?macCat[@"sites"]:@[])){
                NSDictionary *macSource=[self sourceForCatalogSite:macSite catalog:macCat];
                BOOL current=macSource&&[macSource[@"id"] isEqual:self.source[@"id"]];
                NSString *apiURL=[macSite[@"api"] isKindOfClass:NSString.class]?macSite[@"api"]:@"";
                NSString *host=[NSURL URLWithString:apiURL].host?:@"MacCMS 接口";
                NSMutableDictionary *choice=[@{@"name":macSite[@"name"]?:macCat[@"name"]?:@"采集站点",@"subtitle":[NSString stringWithFormat:@"MacCMS 采集接口 · %@%@",host,current?@" · 当前站点":@""],@"site":macSite,@"catalogID":macCatID,@"siteKey":macSite[@"key"]?:@"",@"scope":@"site",@"scopeName":@"采集站点",@"selected":@(current),@"supported":@([macSite[@"supported"] boolValue])} mutableCopy];
                if(macSource)choice[@"source"]=macSource;
                [choices addObject:choice];
            }
        }
    }
    if(!choices.count){
    for(NSDictionary *site in sites){BOOL supported=[site[@"supported"] boolValue];NSDictionary *effectiveSite=site;NSDictionary *fallbackSite=supported?nil:MediaBrowserFallbackSupportedSite(site,sites);if(fallbackSite){supported=YES;effectiveSite=fallbackSite;}NSDictionary *source=[self sourceForCatalogSite:effectiveSite catalog:catalog];NSString *siteKey=effectiveSite[@"key"]?:@"";BOOL current=source&&[source[@"id"] isEqual:self.source[@"id"]];NSString *status=[site[@"status"] isKindOfClass:NSString.class]?site[@"status"]:@"按需加载";if(fallbackSite)status=[NSString stringWithFormat:@"iOS 脚本适配 · 已关联 %@",fallbackSite[@"name"]?:@"可用站点"];if(source)status=@"已加入合集 · 点按切换";NSString *apiKind=effectiveSite[@"apiKind"]?:@"";NSString *kindLabel=[apiKind isEqual:@"script"]?@"脚本站点":([apiKind isEqual:@"maccms-api"]?@"MacCMS 接口":([apiKind isEqual:@"douban-index"]?@"豆瓣影视索引":([apiKind isEqual:@"jar-bridge"]?@"Android/JAR 适配站点":@"影视接口")));NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",kindLabel,status];NSMutableDictionary *choice=[@{@"name":site[@"name"]?:@"未命名影视站点",@"subtitle":subtitle,@"site":effectiveSite,@"catalogID":catalogID,@"siteKey":siteKey,@"scope":@"site",@"scopeName":@"影视站点",@"selected":@(current),@"supported":@(supported)} mutableCopy];if(source)choice[@"source"]=source;[choices addObject:choice];}
    for(NSDictionary *live in lives){if(![live[@"supported"] boolValue])continue;NSString *savedURL=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"tvboxLiveSelection.%@",catalogID]]?:@"";BOOL selected=[savedURL isEqual:live[@"url"]?:@""];[choices addObject:@{@"name":live[@"name"]?:@"直播列表",@"subtitle":@"直播列表 · 仅加载所选清单",@"live":live,@"catalogID":catalogID,@"scope":@"live",@"scopeName":@"直播列表",@"selected":@(selected)}];}
    }
    if(!choices.count){[self showMessage:@"这个资源合集没有可用的内部站点" loading:NO];return;}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=[NSString stringWithFormat:@"%@ · 内部站点",catalog[@"name"]?:@"资源合集"];picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner)return;NSString *chosenCatID=[choice[@"catalogID"] isKindOfClass:NSString.class]&&[choice[@"catalogID"] length]?choice[@"catalogID"]:catalogID;owner.selectedCatalogID=chosenCatID;[NSUserDefaults.standardUserDefaults setObject:chosenCatID forKey:@"selectedMediaCatalogID"];
        NSDictionary *live=choice[@"live"];if(live){if(owner.onSubscribeCatalogLive)owner.onSubscribeCatalogLive(live,catalogID);else if(owner.onOpenTVBoxCatalog)owner.onOpenTVBoxCatalog(catalogID);return;}
        NSDictionary *site=choice[@"site"];if(!site)return;if(![site[@"supported"] boolValue]){[owner showMessage:site[@"status"]?:@"此站点类型暂不支持 iOS 加载" loading:NO];return;}NSDictionary *source=choice[@"source"]?:[owner sourceForCatalogSite:site catalog:catalog];NSString *apiKind=site[@"apiKind"]?:@"";
        if(source){owner.deferAutomaticLoading=NO;owner.homeLoadDeferred=NO;owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=@"catalog_site_selection";[NSUserDefaults.standardUserDefaults setObject:source[@"id"]?:@"" forKey:@"selectedMediaSource"];if([source[@"id"] isEqual:owner.source[@"id"]]){owner.provider=nil;[owner loadHome];}else if(owner.homeMode)[owner activate:source keepingHome:YES];else[owner activate:source];return;}
        if([apiKind isEqual:@"script"]&&owner.onImportCatalogSite){owner.deferAutomaticLoading=NO;owner.homeLoadDeferred=NO;owner.onImportCatalogSite(site,catalogID);return;}
        [owner showMessage:@"此站点暂不能在 iOS 上加载" loading:NO];
    };
    [self presentPicker:picker];
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
    self.backgroundLoadInterrupted=self.loading||self.homeShelfRequestInFlight;[self.homeShelfAttempts minusSet:self.homeCategoryLoadsInFlight];
    [self.readiness cancelWithReason:@"app_backgrounded"];[self.client cancel];[self.configurationClient cancel];
    self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;
    self.resumeCancelledMediaRequestOnAppear=NO;
}
- (void)resumeAfterForeground {
    [PyHost refreshListenersAfterForeground];
    if(!self.foregroundCheckNeeded)return;
    self.foregroundCheckNeeded=NO;
    BOOL interrupted=self.backgroundLoadInterrupted;self.backgroundLoadInterrupted=NO;
    self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;
    if(self.source && !MediaSourceUsesNativeCatalogAPI(self.source)){
        [self checkCurrentService];
        return;
    }
    if(interrupted&&self.isHomePageVisible){self.resumeCancelledMediaRequestOnAppear=NO;[self refreshMediaContent];}
    else [self updateHomeStatusCard];
}
- (void)checkCurrentService {
    if(self.restartInProgress||self.loading||!self.source)return;
    if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground){self.foregroundCheckNeeded=YES;return;}
    self.foregroundCheckNeeded=NO;if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"service_check";
    if(MediaSourceUsesNativeCatalogAPI(self.source)){if(self.client)[self loadHome];return;}
    [PyHost refreshListenersAfterForeground];
    if(![PyHost isRunningServiceIdentifier:self.source[@"id"]]){[self activate:self.source keepingHome:self.homeMode];return;}
    [self.readiness cancelWithReason:@"new_connection_check"];[self.client cancel];self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;NSUInteger generation=++self.generation;
    self.loading=YES;self.readinessStageLabel.text=@"运行会话活跃 · 正在重新检查 HTTP";
    [self showMessage:@"正在检查本机服务连接 · 保留当前内容" loading:YES];
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",self.source[@"port"]]];
    self.readiness=[[LocalServiceReadiness alloc] initWithURL:url timeout:4 requiresHealthJSON:YES];
    self.readiness.diagnosticContext=@{@"service_id":self.source[@"id"]?:@"",@"correlation_id":self.diagnosticTraceID?:@"",@"trigger":@"recheck"};
    __weak typeof(self) weakSelf=self;
    [self.readiness start:^(NSError *error,NSTimeInterval elapsed){MediaBrowserViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;
        owner.loading=NO;NSDictionary *probe=owner.readiness.diagnosticSummary;
        if(error&&[probe[@"last_observed_failure_kind"] isEqual:@"runtime_preparing"]){[owner activate:owner.source keepingHome:owner.homeMode];return;}
        if(error&&[probe[@"last_error_code"] integerValue]==NSURLErrorCannotConnectToHost&&!owner.restartInProgress&&owner.onRestartService){
            [owner restartCurrentService];
            return;
        }
        owner.serviceUnavailable=error!=nil;
        owner.readinessStageLabel.text=error?@"运行会话活跃 · HTTP 健康检查未通过":@"HTTP 健康检查通过";
        NSString *reason=[probe[@"last_error_code"] integerValue]==NSURLErrorCannotConnectToHost?@"本机端口拒绝连接":([probe[@"last_http_status"] integerValue]>0?[NSString stringWithFormat:@"服务返回 HTTP %@，健康检查未通过",probe[@"last_http_status"]]:@"本机服务连接超时或响应无效");
        [owner showMessage:error?[reason stringByAppendingString:@"。当前内容已保留，可重新检查或重启此服务。"]:@"" loading:NO];
        if(!error){
            if(![owner.source[@"capabilities"] count])[owner loadCapabilities];
            else if(owner.homeMode&&owner.items.count==0)[owner loadHome];
            else if(!owner.homeMode){[owner saveCurrentBrowseState];owner.pendingBrowseState=owner.browseStates[[owner stateKeyForSource:owner.source provider:owner.provider]];[owner restorePendingBrowseState];}
            else [owner updateHomeStatusCard];
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
    if([self selectedCatalog]){[self chooseCatalogProvider];return;}
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
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner||![choice[@"provider"] length]||[owner.provider isEqual:choice[@"provider"]])return;[owner saveCurrentBrowseState];owner.provider=choice[@"provider"];NSString *sourceID=owner.source[@"id"]?:@"";[NSUserDefaults.standardUserDefaults setObject:owner.provider forKey:[NSString stringWithFormat:@"mediaProvider.%@",sourceID]];NSString *providerName=[choice[@"name"] isKindOfClass:NSString.class]?choice[@"name"]:@"";if(providerName.length)[NSUserDefaults.standardUserDefaults setObject:providerName forKey:[NSString stringWithFormat:@"mediaProviderName.%@",sourceID]];owner.pendingBrowseState=owner.browseStates[[owner stateKeyForSource:owner.source provider:owner.provider]];owner.nextHomeLoadTrigger=@"site_selection";owner.homeMode=YES;owner.status.text=@"";[owner clearHomeResult];owner.homeCategories=@[];[owner.homeShelfAttempts removeAllObjects];[owner updateSelectionControls];[owner loadHome];};[self presentPicker:picker];
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
    [self activate:source keepingHome:YES];
}
- (void)activate:(NSDictionary *)source keepingHome:(BOOL)keepingHome {
    if(!MediaSourceUsesNativeCatalogAPI(source)&&[source[@"id"] isKindOfClass:NSString.class]){
        for(NSDictionary *stored in [ServiceStore services])if([stored[@"id"] isEqual:source[@"id"]]){NSMutableDictionary *merged=[stored mutableCopy];if(source[@"capabilities"]&&!merged[@"capabilities"])merged[@"capabilities"]=source[@"capabilities"];source=merged.copy;break;}
    }
    BOOL sourceChanged=![[self.source[@"id"] description] isEqual:[source[@"id"] description]];
    NSString *catalogID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");
    self.selectedCatalogID=catalogID;if(catalogID.length)[NSUserDefaults.standardUserDefaults setObject:catalogID forKey:@"selectedMediaCatalogID"];else[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];
    if([source[@"id"] isKindOfClass:NSString.class])[NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];
    if(keepingHome&&sourceChanged){[self saveHomeScrollOffset];self.pendingHomeOffsetRestore=nil;if(self.homeScroll)[self.homeScroll setContentOffset:CGPointMake(0,-self.homeScroll.adjustedContentInset.top) animated:NO];}
    if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"source_activation";
    self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;self.homeMode=keepingHome;self.title=@"";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.navigationItem.searchController=nil;self.navigationItem.hidesSearchBarWhenScrolling=NO;[self setBrowseControlsHidden:keepingHome];[self notifyDisplayModeChanged];
    if(self.pendingHomeDetail&&![self.pendingHomeDetail[@"source"][@"id"] isEqual:source[@"id"]])self.pendingHomeDetail=nil;
    self.detachedGeneration++;[self.detachedReadiness cancel];self.forceVisibleShelfRefresh=NO;[self.homeShelfAttempts removeAllObjects];self.sourceInvalidated=NO;self.serviceUnavailable=NO;self.capabilityReadinessRetryCount=0;self.capabilityReadinessStartedAt=CACurrentMediaTime();self.watchHistoryLookup=nil;[self saveCurrentBrowseState];self.generation++;NSUInteger generation=self.generation;self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaRequestAppend=NO;self.resumeCancelledMediaRequestOnAppear=NO;self.cancelledMediaOperation=nil;self.cancelledMediaRequestWasAppend=NO;self.source=source;[self clearHomeResult];self.homeCategories=@[];self.homeShelfGeneration=0;NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",source[@"id"]]];self.provider=nil;self.pendingBrowseState=self.browseStates[[self stateKeyForSource:source provider:preferredProvider]]?:self.browseStates[[self stateKeyForSource:source provider:nil]];if(sourceChanged&&!self.pendingBrowseState)[self.grid setContentOffset:CGPointMake(0,-self.grid.adjustedContentInset.top) animated:NO];self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.page=1;self.loading=YES;self.moreButton.hidden=YES;[self.grid reloadData];
    [self updateSelectionControls];
    self.widgetSeason=1;self.widgetEpisode=1;BOOL widget=[source[@"protocol"] isEqual:@"widget-extractor"];self.navigationItem.prompt=widget?@"第 1 季 · 第 1 集 · 工具栏筛选可修改":nil;self.search.searchBar.placeholder=widget?@"输入完整剧名，筛选中选择季 / 集":@"搜索当前影视来源";
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    [NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];
    NSString *cachedProvider=@"";NSDictionary *cachedHome=[self cachedHomeResultForSelectedProvider:&cachedProvider];if(cachedHome){self.provider=cachedProvider;[self applyHomeResult:cachedHome];}
    if(MediaSourceUsesNativeCatalogAPI(source)){
        self.client=[[MediaAPIClient alloc] initWithTVBoxSource:source];NSMutableDictionary *saved=[source mutableCopy];BOOL doubanIndex=[source[@"protocol"] isEqual:@"douban-index"],jarBridge=[source[@"protocol"] isEqual:@"jar-bridge"];saved[@"capabilities"]=doubanIndex?@[@"home",@"category",@"search"]:@[@"home",@"category",@"search",@"detail",@"play"];self.source=saved;self.provider=@"";self.providers=@[];self.readinessStageLabel.text=doubanIndex?@"豆瓣索引 · 仅提供影片信息，播放时跨点播源搜索":(jarBridge?@"Android/JAR 适配引擎 · iOS 原生执行":([source[@"protocol"] isEqual:@"maccms-api"]?@"MacCMS JSON/XML API · 按需连接，不启动插件运行时":@"TVBox JSON API · 不启动插件运行时"));self.loading=NO;[self updateSelectionControls];[self loadHome];NSDictionary *resume=self.pendingHistoryEntry;if(resume&&[resume[@"sourceID"] isEqual:self.source[@"id"]]){self.pendingHistoryEntry=nil;[self openHistoryDetail:resume source:self.source provider:@""];}return;
    }
    self.readinessStageLabel.text=@"准备启动已选资源";[self showMessage:[NSString stringWithFormat:@"正在启动 %@…",source[@"name"]] loading:YES];
    self.client=[[MediaAPIClient alloc] initWithPort:[source[@"port"] integerValue]];__weak typeof(self) weakSelf=self;
    void (^started)(NSError *)=^(NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner || owner.generation!=generation)return;
        if(error){owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=nil;owner.readinessStageLabel.text=@"启动失败 · HTTP 健康状态未知";[RuntimeDiagnostics.shared recordEvent:@"media_source_activation_failed" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"port":owner.source[@"port"]?:@0, @"engine":owner.source[@"engine"]?:@"unknown", @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@""}];owner.loading=NO;[owner updateSelectionControls];[owner showMessage:error.localizedDescription loading:NO];return;}
        NSDictionary *activeSource=source;
        for(NSDictionary *stored in [ServiceStore services])if([stored[@"id"] isEqual:source[@"id"]]){activeSource=stored;break;}
        if(![activeSource[@"port"] isEqual:owner.source[@"port"]]){owner.source=activeSource;[owner.client cancel];owner.client=[[MediaAPIClient alloc] initWithPort:[activeSource[@"port"] integerValue]];}
        owner.readinessStageLabel.text=@"启动请求已接受 · 等待 HTTP 健康检查";[owner showMessage:@"启动请求已接受 · 等待本机服务响应" loading:YES];[RuntimeDiagnostics.shared recordEvent:@"media_runtime_start_request_accepted" category:@"service" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"engine":owner.source[@"engine"]?:@"unknown"}];
        NSURL *health=[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%@/health",activeSource[@"port"]]];
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
            // 45 次重试按 0.5/1/2 秒退避约需一分钟，期间无总超时；超过 90 秒
            // 即停止重试走失败收尾，避免用户切走后后台仍在空转。
            NSTimeInterval readinessElapsed=self.capabilityReadinessStartedAt>0?CACurrentMediaTime()-self.capabilityReadinessStartedAt:0;
            if(retryable&&owner.capabilityReadinessRetryCount<45&&readinessElapsed<90){
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
        owner.capabilityReadinessRetryCount=0;owner.capabilityReadinessStartedAt=0;
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
    if(!self.homeMode){[self saveCurrentBrowseState];if(!self.pendingBrowseState)self.pendingBrowseState=self.browseStates[[self stateKeyForSource:self.source provider:self.provider]];self.homeMode=YES;[self notifyDisplayModeChanged];}
    NSString *trigger=self.nextHomeLoadTrigger.length?self.nextHomeLoadTrigger:@"unspecified";
    NSDictionary *requestedSource=[self.source copy]?:@{};
    NSString *requestedSourceID=[requestedSource[@"id"] isKindOfClass:NSString.class]?requestedSource[@"id"]:@"";
    NSString *requestedProvider=[self.provider isKindOfClass:NSString.class]?self.provider:@"";
    BOOL sameRequestInFlight=self.loading&&[self.activeMediaOperation isEqualToString:@"home"]&&[self.activeHomeRequestSourceID isEqualToString:requestedSourceID]&&[self.activeHomeRequestProviderID isEqualToString:requestedProvider];
    self.nextHomeLoadTrigger=nil;
    if(sameRequestInFlight){[RuntimeDiagnostics.shared recordEvent:@"media_home_duplicate_request_suppressed" category:@"media_api" fields:@{@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"trigger":trigger,@"reason":@"same_resource_site_request_in_flight"}];return;}
    NSUInteger generation=++self.generation;self.homeShelfGeneration=generation;[self.homeShelfAttempts removeAllObjects];
    self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaRequestAppend=NO;self.activeMediaOperation=@"home";
    self.activeHomeRequestSourceID=requestedSourceID;self.activeHomeRequestProviderID=requestedProvider;
    self.filters=@{};self.selectedFilters=[NSMutableDictionary dictionary];
    BOOL hasProviderDirectory=[self.source[@"capabilities"] containsObject:@"providers"];
    self.readinessStageLabel.text=hasProviderDirectory?@"站点目录已读取 · 正在加载影视内容":@"资源能力已读取 · 正在加载影视内容";
    if(hasProviderDirectory)[RuntimeDiagnostics.shared recordEvent:@"media_provider_list_readable" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.source[@"id"]?:@"",@"provider_count":@(self.providers.count)}];
    self.loading=YES;[self updateSelectionControls];self.keyword=@"";self.category=nil;self.page=1;self.hasMore=NO;self.moreButton.hidden=YES;
    NSDictionary *requestArguments=[self arguments:@{}];BOOL cacheStale=NO;id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:requestArguments maximumAge:6*3600 isStale:&cacheStale];NSUInteger cachedItemCount=[cached isKindOfClass:NSDictionary.class]&&[cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0;CFTimeInterval requestStartedAt=CACurrentMediaTime();[RuntimeDiagnostics.shared recordEvent:@"media_home_request_started" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"generation":@(generation),@"trigger":trigger,@"home_mode":@(self.homeMode),@"automatic_load_deferred":@(self.deferAutomaticLoading||self.homeLoadDeferred),@"port":self.source[@"port"]?:@0,@"cache_hit":@([cached isKindOfClass:NSDictionary.class]),@"cache_stale":@(cacheStale),@"cached_item_count":@(cachedItemCount)}];
    if([cached isKindOfClass:NSDictionary.class]){[self applyHomeResult:cached];[self showMessage:cacheStale?@"正在更新 · 暂用缓存推荐":@"正在校验 · 显示上次推荐" loading:YES];}
    else{self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载推荐与分类…" loading:YES];}
    __weak typeof(self) weakSelf=self;
    [self.client call:@"home" arguments:requestArguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;BOOL sameSource=[[owner.source[@"id"] description] isEqual:requestedSourceID];BOOL sameProvider=[(owner.provider?:@"") isEqual:requestedProvider];BOOL stillCurrentOperation=[owner.activeMediaOperation isEqualToString:@"home"];if(owner.generation!=generation||!sameSource||!sameProvider||!stillCurrentOperation){NSString *reason=owner.generation!=generation?@"superseded_generation":(!sameSource?@"source_changed":(!sameProvider?@"provider_changed":@"superseded_operation"));[RuntimeDiagnostics.shared recordEvent:@"media_home_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider":requestedProvider,@"generation":@(generation),@"current_generation":@(owner.generation),@"current_service_id":[owner.source[@"id"] description]?:@"",@"current_provider":owner.provider?:@"",@"current_operation":owner.activeMediaOperation?:@"",@"reason":reason}];return;}owner.activeMediaOperation=nil;owner.activeHomeRequestSourceID=nil;owner.activeHomeRequestProviderID=nil;owner.loading=NO;[owner updateSelectionControls];NSTimeInterval responseElapsed=MAX(0,CACurrentMediaTime()-requestStartedAt);[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil&&[result isKindOfClass:NSDictionary.class] elapsed:responseElapsed];[RuntimeDiagnostics.shared recordEvent:@"media_home_response_received" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider":requestedProvider,@"generation":@(generation),@"elapsed_ms":@((NSInteger)(responseElapsed*1000)),@"item_count":@(([result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class])?[result[@"items"] count]:0),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
        if(error||![result isKindOfClass:NSDictionary.class]){if([error.userInfo[@"plugin_error_code"] isEqual:@"STARTUP_FAILED"])owner.serviceUnavailable=YES;NSString *message=error.localizedDescription?:@"资源返回的首页数据格式无法识别";owner.readinessStageLabel.text=owner.items.count?@"内容接口失败 · 当前仍显示缓存内容":@"内容接口读取失败";[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存内容 · 更新失败：%@",message]:message loading:NO];[RuntimeDiagnostics.shared recordEvent:@"media_home_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"failure_stage":error?@"request_error":@"invalid_result_shape",@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":message}];return;}
        if(owner.keyword.length || owner.category.length){owner.page=1;[owner loadListing:NO];return;}
        [owner applyHomeResult:result];
        if(owner.homeResult)[[MediaMetadataCache shared] storeResult:owner.homeResult forSource:owner.source operation:@"home" arguments:requestArguments];
        if(owner.homeMode)[owner refreshHomeModules];
        owner.homeShelfGeneration=0;owner.homeShelfRequestInFlight=NO;
        BOOL recommendationsUnavailable=[result[@"recommendationsUnavailable"] isEqual:@YES];
        owner.readinessStageLabel.text=recommendationsUnavailable?@"分类已读取 · 推荐加载失败，可选择分类继续浏览":@"影视内容接口已读取 · 实际播放需以视频首帧确认";
        [RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(owner.items.count),@"operation":@"home"}];
        if(owner.pendingBrowseState){[owner restorePendingBrowseState];return;}
        [owner showMessage:owner.items.count?@"":(recommendationsUnavailable?@"推荐暂不可用，请选择分类或输入关键词搜索":@"选择分类或输入关键词搜索") loading:NO];
    }];
}
- (void)applyHomeResult:(NSDictionary *)result {
    self.watchHistoryLookup=nil;
    if(![result isKindOfClass:NSDictionary.class]){self.homeResult=nil;self.items=@[];self.homeCategories=@[];[self.grid reloadData];[self showMessage:@"首页数据格式无法识别，请重试或检查资源日志" loading:NO];return;}
    NSUInteger discardedItems=0;NSMutableDictionary *normalized=[result mutableCopy];NSArray *incoming=MediaBrowserDictionaryRows(result[@"items"],&discardedItems);NSArray *incomingCategories=MediaBrowserDictionaryRows(result[@"categories"],NULL);normalized[@"items"]=incoming;normalized[@"categories"]=incomingCategories;if(![normalized[@"filters"] isKindOfClass:NSDictionary.class])normalized[@"filters"]=@{};result=normalized;
    NSUInteger renderSerial=++self.diagnosticGridApplySerial;self.diagnosticGridConfiguredSerial=0;self.diagnosticGridVisibleSerial=0;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_data_apply_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"render_serial":@(renderSerial),@"item_count":@(incoming.count),@"category_count":@(incomingCategories.count),@"discarded_item_count":@(discardedItems),@"home_mode":@(self.homeMode)}];
    self.homeResult=[result isKindOfClass:NSDictionary.class]?[result copy]:nil;self.homeResultSourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:@"";self.homeResultProvider=self.provider?:@"";
    self.items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];
    self.homeCategories=[result[@"categories"] isKindOfClass:NSArray.class]?result[@"categories"]:@[];
    self.filters=[result[@"filters"] isKindOfClass:NSDictionary.class]?result[@"filters"]:@{};
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    NSMutableArray<NSDictionary *> *validCategories=[NSMutableArray array];for(NSDictionary *category in incomingCategories){if(![category isKindOfClass:NSDictionary.class])continue;NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";NSString *name=[category[@"name"] isKindOfClass:NSString.class]?category[@"name"]:@"";if(identifier.length&&name.length)[validCategories addObject:category];}
    self.homeCategories=validCategories;
    UIButton *featured=[UIButton buttonWithType:UIButtonTypeSystem];featured.accessibilityIdentifier=@"__featured__";featured.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];featured.contentEdgeInsets=UIEdgeInsetsMake(7,14,7,14);[featured setTitle:@"精选" forState:UIControlStateNormal];[featured addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[self.categories addArrangedSubview:featured];
    for(NSDictionary *category in validCategories){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:category[@"name"] forState:UIControlStateNormal];button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15] maximumPointSize:20];button.titleLabel.adjustsFontForContentSizeCategory=NO;button.contentEdgeInsets=UIEdgeInsetsMake(7,14,7,14);button.accessibilityIdentifier=[category[@"id"] description];button.accessibilityLabel=[NSString stringWithFormat:@"影视分类：%@",category[@"name"]];[button addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[self.categories addArrangedSubview:button];}
    BOOL hasCategories=self.categories.arrangedSubviews.count>0&&[MediaHomeEnabledModules() containsObject:@"catalog"];self.categoryScrollHeightConstraint.constant=hasCategories?44:0;self.categoryScroll.hidden=!hasCategories;
    for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:@"__featured__"]?!self.category.length:[button.accessibilityIdentifier isEqual:self.category];[button.heightAnchor constraintEqualToConstant:34].active=YES;HostStylePillButton(button,selected);MediaBrowserApplyScaledPillFont(button);button.layer.cornerRadius=17;[button setTitleColor:selected?HostOnAccent():HostSecondaryText() forState:UIControlStateNormal];if(selected){button.backgroundColor=HostAccent();HostSetLayerBorderColor(button,HostAccent());}}
    NSMutableArray<NSString *> *prefetchPosters=[NSMutableArray arrayWithCapacity:6];
    for(NSDictionary *row in self.items){if(prefetchPosters.count>=6)break;NSString *p=[row[@"poster"] isKindOfClass:NSString.class]?row[@"poster"]:([row[@"vod_pic"] isKindOfClass:NSString.class]?row[@"vod_pic"]:@"");if(p.length)[prefetchPosters addObject:p];}
    if(prefetchPosters.count)[HostImageLoader.shared prefetchPosterURLs:prefetchPosters];
    [self updateHomeGridLayout];
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_data_apply_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"render_serial":@(renderSerial),@"item_count":@(self.items.count),@"category_count":@(self.homeCategories.count),@"home_mode":@(self.homeMode)}];
}
- (void)selectCategory:(UIButton *)button {[self selectMediaCategory:[button.accessibilityIdentifier isEqual:@"__featured__"]?nil:button.accessibilityIdentifier];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *keyword=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *previousKeyword=self.keyword?:@"";
    if(!keyword.length && !previousKeyword.length && (!searchController.isActive || self.homeMode))return;
    self.keyword=keyword;if(keyword.length)self.homeMode=NO;
    NSUInteger generation=++self.searchGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner || owner.searchGeneration!=generation || !owner.source || owner.loading)return;owner.page=1;if(keyword.length)[owner loadListing:NO];else if(!owner.category.length && (!owner.homeMode || previousKeyword.length)){owner.nextHomeLoadTrigger=@"search_reset";[owner loadHome];}});
}
- (void)loadMore {if(!self.loading && self.hasMore){self.page++;[self loadListing:YES];}}
- (void)loadListing:(BOOL)append {
    if(!self.source)return;if(!self.keyword.length && !self.category.length){self.nextHomeLoadTrigger=@"listing_reset";[self loadHome];return;}if(!append&&!self.pendingRestoreOffset)[self.grid setContentOffset:CGPointMake(0,-self.grid.adjustedContentInset.top) animated:NO];NSUInteger generation=self.generation;NSString *requestedSourceID=[[self.source[@"id"] description] copy]?:@"";NSString *requestedProvider=[self.provider copy]?:@"";self.loading=YES;[self updateSelectionControls];NSString *operation=self.keyword.length?@"search":@"category";NSString *requestedKeyword=self.keyword?:@"",*requestedCategory=self.category?:@"";
    self.readinessStageLabel.text=self.keyword.length?@"资源运行中 · 正在搜索影视内容":@"资源运行中 · 正在加载分类内容";
    self.activeMediaOperation=operation;self.activeMediaRequestAppend=append;NSInteger requestedPage=self.page;
    NSMutableDictionary *args=[[self arguments:@{@"page":@(self.page)}] mutableCopy];if(self.keyword.length)args[@"keyword"]=self.keyword;else args[@"categoryId"]=self.category?:@"";
    NSInteger episode=self.widgetEpisode,season=self.widgetSeason;if([self.source[@"protocol"] isEqual:@"widget-extractor"]){args[@"episode"]=@(MAX(1,episode));args[@"season"]=@(MAX(1,season));}
    args[@"filters"]=self.selectedFilters?:@{};NSDictionary *requestedFilters=[self.selectedFilters copy]?:@{};
    BOOL hadCachedResult=NO;BOOL cacheStale=NO;NSUInteger cachedItemCount=0;
    if(!append){id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:operation arguments:args maximumAge:6*3600 isStale:&cacheStale];if([cached isKindOfClass:NSDictionary.class]){hadCachedResult=YES;self.items=MediaBrowserDictionaryRows(cached[@"items"],NULL);cachedItemCount=self.items.count;self.hasMore=MediaBrowserBoolean(cached[@"hasMore"]);self.moreButton.hidden=!self.hasMore;[self updateHomeGridLayout];[self showMessage:cacheStale?@"正在更新 · 暂用缓存结果":@"正在校验 · 显示上次结果" loading:YES];}}
    if(!append&&!hadCachedResult){self.items=@[];[self updateHomeGridLayout];[self showMessage:@"正在加载…" loading:YES];}self.moreButton.enabled=NO;
    CFTimeInterval requestStartedAt=CACurrentMediaTime();[RuntimeDiagnostics.shared recordEvent:@"media_listing_request_started" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"request_generation":@(generation),@"page":@(requestedPage),@"append":@(append),@"cache_hit":@(hadCachedResult),@"cache_stale":@(cacheStale),@"cached_item_count":@(cachedItemCount),@"search_term_length":@(requestedKeyword.length),@"has_category":@(requestedCategory.length>0),@"filter_count":@(requestedFilters.count)}];__weak typeof(self) weakSelf=self;
    [self.client call:operation arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;if(owner.generation!=generation||![[owner.source[@"id"] description] isEqual:requestedSourceID]||![(owner.provider?:@"") isEqual:requestedProvider]){[RuntimeDiagnostics.shared recordEvent:@"media_listing_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":owner.generation!=generation?@"superseded_generation":(![[owner.source[@"id"] description] isEqual:requestedSourceID]?@"source_changed":@"provider_changed")}];if(append&&requestedPage==owner.page)owner.page=MAX(1,owner.page-1);return;}if([owner.activeMediaOperation isEqualToString:operation])owner.activeMediaOperation=nil;owner.activeMediaRequestAppend=NO;owner.loading=NO;[owner updateSelectionControls];owner.moreButton.enabled=YES;BOOL validResultShape=[result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class];[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil&&validResultShape elapsed:MAX(0,CACurrentMediaTime()-requestStartedAt)];
        if(episode!=owner.widgetEpisode || season!=owner.widgetSeason || ![requestedKeyword isEqualToString:owner.keyword?:@""] || (!requestedKeyword.length && (![requestedCategory isEqualToString:owner.category?:@""] || ![requestedFilters isEqual:owner.selectedFilters?:@{}]))){[RuntimeDiagnostics.shared recordEvent:@"media_listing_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"operation":operation,@"request_generation":@(generation),@"requested_page":@(requestedPage),@"current_page":@(owner.page),@"reason":@"search_category_or_filter_changed"}];owner.page=1;[owner loadListing:NO];return;}
        NSInteger elapsedMS=(NSInteger)(MAX(0,CACurrentMediaTime()-requestStartedAt)*1000);
        if(error||![result isKindOfClass:NSDictionary.class]||![result[@"items"] isKindOfClass:NSArray.class]){NSString *message=error.localizedDescription?:@"资源返回的数据格式不完整";[RuntimeDiagnostics.shared recordEvent:@"media_listing_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"page":@(requestedPage),@"append":@(append),@"elapsed_ms":@(elapsedMS),@"retained_cached_items":@(owner.items.count),@"failure_stage":error?@"request_error":@"invalid_result_shape",@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":message}];owner.readinessStageLabel.text=owner.items.count?@"更新失败 · 当前仍显示可用影视内容":@"影视内容接口读取失败";[owner updateHomeGridLayout];if(append)owner.page=MAX(1,owner.page-1);[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存结果 · 更新失败：%@",message]:message loading:NO];return;}
        NSUInteger discardedRows=0;NSArray *incoming=MediaBrowserDictionaryRows(result[@"items"],&discardedRows);NSMutableDictionary *normalized=[result mutableCopy];normalized[@"items"]=incoming;if(![normalized[@"hasMore"] isKindOfClass:NSNumber.class])normalized[@"hasMore"]=@(MediaBrowserBoolean(normalized[@"hasMore"]));
        if(!append)[[MediaMetadataCache shared] storeResult:normalized forSource:owner.source operation:operation arguments:args];
        NSMutableArray *all=append?[owner.items mutableCopy]:[NSMutableArray array];NSMutableSet<NSString *> *identities=[NSMutableSet set];for(id rawItem in all)if([rawItem isKindOfClass:NSDictionary.class]){NSString *identity=MediaBrowserItemIdentity(rawItem);if(identity.length)[identities addObject:identity];}for(NSDictionary *item in incoming){NSString *identity=MediaBrowserItemIdentity(item);if(!identity.length||![identities containsObject:identity]){[all addObject:item];if(identity.length)[identities addObject:identity];}}
        owner.items=all;owner.readinessStageLabel.text=@"影视内容接口已读取 · 实际播放需以视频首帧确认";[RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(all.count),@"operation":operation}];[RuntimeDiagnostics.shared recordEvent:@"media_listing_result_applied" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"page":@(requestedPage),@"append":@(append),@"incoming_count":@(incoming.count),@"discarded_row_count":@(discardedRows),@"displayed_count":@(all.count),@"has_more":@(MediaBrowserBoolean(normalized[@"hasMore"])),@"elapsed_ms":@(elapsedMS)}];if(owner.pendingRestorePage>requestedPage && MediaBrowserBoolean(normalized[@"hasMore"]) && incoming.count && requestedPage<owner.pendingRestorePage){owner.page=requestedPage+1;[owner loadListing:YES];return;}if(owner.pendingRestorePage){owner.page=requestedPage;owner.pendingRestorePage=0;}owner.hasMore=MediaBrowserBoolean(normalized[@"hasMore"]);owner.moreButton.hidden=!owner.hasMore;[owner updateHomeGridLayout];[owner showMessage:all.count?@"":@"没有找到影片，请更换关键词或分类" loading:NO];
        if(owner.pendingRestoreOffset){CGFloat offset=owner.pendingRestoreOffset.doubleValue;owner.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[owner.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
    }];
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.backgroundColor=HostBackground();
    self.view.tintColor=HostAccent();
    self.grid.backgroundColor=HostBackground();
    self.status.textColor=HostSecondaryText();
    self.readinessStageLabel.textColor=HostSecondaryText();
    [self updateSelectionControls];
    for(UIButton *button in self.categories.arrangedSubviews){
        BOOL selected=[button.accessibilityIdentifier isEqual:@"__featured__"]?!self.category.length:[button.accessibilityIdentifier isEqual:self.category];
        HostStylePillButton(button,selected);
        MediaBrowserApplyScaledPillFont(button);
        [button setTitleColor:selected?HostOnAccent():HostSecondaryText() forState:UIControlStateNormal];
        if(selected){button.backgroundColor=HostAccent();HostSetLayerBorderColor(button,HostAccent());}
    }
    [self.grid reloadData];
}

@end
