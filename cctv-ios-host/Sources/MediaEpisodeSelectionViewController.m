#import "MediaEpisodeSelectionViewController.h"
#import "MediaAPIClient.h"
#import "HostTheme.h"
#import "HostImageLoader.h"
#import "MediaEpisodeLayout.h"
#import "RuntimeDiagnostics.h"
#import "TVBoxCatalogStore.h"

static UIColor *MediaSelectionBackground(void) { return HostBackground(); }
static UIColor *MediaSelectionSurface(void) { return [UIColor colorWithWhite:1 alpha:0.075]; }
static UIColor *MediaSelectionMuted(void) { return [UIColor colorWithWhite:1 alpha:0.68]; }

static NSArray<NSDictionary *> *MediaEpisodeSelectionDictionaryRows(id value) {
    if(![value isKindOfClass:NSArray.class])return @[];NSMutableArray *rows=[NSMutableArray array];for(id row in value)if([row isKindOfClass:NSDictionary.class])[rows addObject:row];return rows;
}
static NSArray<NSDictionary *> *MediaEpisodeSelectionLines(id value) {
    NSArray *rows=MediaEpisodeSelectionDictionaryRows(value);NSMutableArray *lines=[NSMutableArray arrayWithCapacity:rows.count];for(NSDictionary *rawLine in rows){NSMutableDictionary *line=[rawLine mutableCopy];line[@"episodes"]=MediaEpisodeSelectionDictionaryRows(line[@"episodes"]);[lines addObject:line];}return lines;
}
static NSDictionary *MediaEpisodeSelectionSanitizedDetail(id value) {
    if(![value isKindOfClass:NSDictionary.class])return nil;NSMutableDictionary *detail=[value mutableCopy];detail[@"lines"]=MediaEpisodeSelectionLines(detail[@"lines"]);id rawSeasons=detail[@"seasons"]?:detail[@"seasonList"]?:detail[@"season_list"];if([rawSeasons isKindOfClass:NSArray.class]){NSMutableArray *seasons=[NSMutableArray array];for(NSDictionary *rawSeason in MediaEpisodeSelectionDictionaryRows(rawSeasons)){NSMutableDictionary *season=[rawSeason mutableCopy];season[@"lines"]=MediaEpisodeSelectionLines(season[@"lines"]);season[@"episodes"]=MediaEpisodeSelectionDictionaryRows(season[@"episodes"]);[seasons addObject:season];}detail[@"seasons"]=seasons;}return detail;
}
static void MediaEpisodeSelectionLoadPoster(NSString *url, UIImageView *view, NSUInteger retriesRemaining);
static void MediaEpisodeSelectionLoadPoster(NSString *url, UIImageView *view, NSUInteger retriesRemaining) {
    if(!url.length||!view)return;__weak UIImageView *weakView=view;
    [HostImageLoader.shared loadPosterURL:url intoImageView:view completion:^(BOOL succeeded,NSTimeInterval retryAfter){if(succeeded||!retriesRemaining||retryAfter<=0)return;NSTimeInterval delay=MIN(120.0,MAX(1.0,retryAfter+0.25));dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{UIImageView *current=weakView;if(current&&current.window&&[current.accessibilityIdentifier isEqualToString:url])MediaEpisodeSelectionLoadPoster(url,current,retriesRemaining-1);});}];
}

// HostStylePillButton 会把标题字体写死为 14pt 固定字体；调用点再套一层按
// Dynamic Type 缩放的同字号字体，默认字号下外观不变。
static void MediaEpisodeApplyScaledPillFont(UIButton *button) {
    button.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];
    button.titleLabel.adjustsFontForContentSizeCategory=YES;
}

@interface MediaEpisodeSelectionViewController ()
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger refreshGeneration;
@property(nonatomic,strong) MediaAPIClient *refreshClient;
@property(nonatomic,strong) UIImageView *backdropImageView;
@property(nonatomic,strong) UIVisualEffectView *backdropBlurView;
@property(nonatomic,strong) UIView *backdropTintView;
@property(nonatomic,strong) CAGradientLayer *backdropGradient;
@property(nonatomic,strong) UIScrollView *scrollView;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UIStackView *routeButtons;
@property(nonatomic,strong) UIStackView *seasonButtons;
@property(nonatomic,strong) UIStackView *seasonSectionStack;
@property(nonatomic,strong) UIStackView *seasonHeadingStack;
@property(nonatomic,strong) UILabel *seasonCountLabel;
@property(nonatomic,strong) UIScrollView *seasonScrollView;
@property(nonatomic,strong) NSLayoutConstraint *seasonScrollHeightConstraint;
@property(nonatomic,strong) UIStackView *heroBadges;
@property(nonatomic,strong) UIScrollView *quickEpisodeScroll;
@property(nonatomic,strong) UIStackView *quickEpisodeStack;
@property(nonatomic,strong) UIStackView *episodeGrid;
@property(nonatomic,strong) NSMutableArray<UIButton *> *episodeButtons;
@property(nonatomic,strong) UILabel *pageLabel;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *headerTitle;
@property(nonatomic,strong) UILabel *heroTitle;
@property(nonatomic,strong) UILabel *heroMetadata;
@property(nonatomic,strong) UILabel *heroCredits;
@property(nonatomic,strong) UILabel *descriptionLabel;
@property(nonatomic,strong) UIButton *descriptionToggle;
@property(nonatomic,strong) UIButton *episodeDisclosureButton;
@property(nonatomic,strong) UILabel *episodeDisclosureLabel;
@property(nonatomic,strong) UILabel *episodeCountLabel;
@property(nonatomic,strong) UIImageView *episodeDisclosureIcon;
@property(nonatomic,strong) UIStackView *episodeDetails;
@property(nonatomic,strong) UIButton *continueButton;
@property(nonatomic,strong) UIButton *previousButton;
@property(nonatomic,strong) UIButton *nextButton;
@property(nonatomic,strong) UIButton *reverseButton;
@property(nonatomic,strong) UIButton *jumpEpisodeButton;
@property(nonatomic,strong) UIButton *refreshButton;
@property(nonatomic,strong) UIActivityIndicatorView *refreshSpinner;
@property(nonatomic,strong) UIActivityIndicatorView *playSpinner;
@property(nonatomic) NSInteger page;
@property(nonatomic) BOOL episodeOrderReversed;
@property(nonatomic) BOOL episodeExpanded;
@property(nonatomic) BOOL descriptionExpanded;
@property(nonatomic) BOOL originalNavigationBarHidden;
@property(nonatomic) BOOL savedNavigationBarVisibility;
- (void)selectRoute:(UIButton *)sender;
- (void)selectSeason:(UIButton *)sender;
- (void)selectEpisode:(UIButton *)sender;
@end

@implementation MediaEpisodeSelectionViewController

- (instancetype)init { return [super init]; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (NSArray *)seasonCollections {
    id value=self.detail[@"seasons"]?:self.detail[@"seasonList"]?:self.detail[@"season_list"];
    return [value isKindOfClass:NSArray.class]?value:@[];
}
- (NSDictionary *)currentSeason {
    NSArray *seasons=self.seasonCollections;
    return self.selectedSeasonIndex>=0&&self.selectedSeasonIndex<seasons.count&&[seasons[(NSUInteger)self.selectedSeasonIndex] isKindOfClass:NSDictionary.class]?seasons[(NSUInteger)self.selectedSeasonIndex]:@{};
}
- (NSArray *)lines {
    NSArray *seasonLines=[self.currentSeason[@"lines"] isKindOfClass:NSArray.class]?self.currentSeason[@"lines"]:@[];
    return seasonLines.count?seasonLines:([self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[]);
}
- (NSArray *)episodesForLine:(NSInteger)index {
    NSArray *lines=self.lines;
    if(index>=0&&index<lines.count){NSDictionary *line=[lines[(NSUInteger)index] isKindOfClass:NSDictionary.class]?lines[(NSUInteger)index]:@{};NSArray *lineEpisodes=[line[@"episodes"] isKindOfClass:NSArray.class]?line[@"episodes"]:@[];if(lineEpisodes.count){NSMutableArray *clean=[NSMutableArray arrayWithCapacity:lineEpisodes.count];for(id episode in lineEpisodes)[clean addObject:[episode isKindOfClass:NSDictionary.class]?episode:@{}];return clean;}}
    NSArray *seasonEpisodes=[self.currentSeason[@"episodes"] isKindOfClass:NSArray.class]?self.currentSeason[@"episodes"]:@[];
    NSMutableArray *clean=[NSMutableArray arrayWithCapacity:seasonEpisodes.count];for(id episode in seasonEpisodes)[clean addObject:[episode isKindOfClass:NSDictionary.class]?episode:@{}];return clean;
}
- (NSString *)currentParserID {
    NSString *sourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:([self.source[@"api"] isKindOfClass:NSString.class]?self.source[@"api"]:@"default");
    NSString *catalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");catalogID=[catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!catalogID.length)return @"";
    NSString *selected=self.parserID.length?self.parserID:([NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"cctv.media.parser.%@",sourceID]]?:@"");for(NSDictionary *parser in [TVBoxCatalogStore playbackParsersForCatalogID:catalogID])if([parser[@"id"] isEqual:selected])return selected;return @"";
}
- (NSString *)titleText {
    NSString *name=[self.detail[@"name"] isKindOfClass:NSString.class]?[self.detail[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    NSString *itemName=[self.item[@"name"] isKindOfClass:NSString.class]?[self.item[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
    NSString *itemID=[self.item[@"id"] description]?:([self.detail[@"id"] description]?:@"");
    BOOL nameOpaque=!name.length||(itemID.length&&[name caseInsensitiveCompare:itemID]==NSOrderedSame&&[name rangeOfString:@"^[A-Za-z0-9_.:/-]{6,128}$" options:NSRegularExpressionSearch].location!=NSNotFound)||([name rangeOfString:@"^[A-Za-z0-9_-]{8,64}$" options:NSRegularExpressionSearch].location!=NSNotFound&&[name rangeOfString:@"[0-9]" options:NSRegularExpressionSearch].location!=NSNotFound);
    if(nameOpaque&&itemName.length&&![itemName isEqualToString:itemID])name=itemName;
    if(nameOpaque){
        NSString *synopsis=[self.detail[@"description"] isKindOfClass:NSString.class]?self.detail[@"description"]:([self.detail[@"vod_content"] isKindOfClass:NSString.class]?self.detail[@"vod_content"]:@"");
        NSRange open=[synopsis rangeOfString:@"《"];
        if(open.location!=NSNotFound&&NSMaxRange(open)<synopsis.length){
            NSRange close=[synopsis rangeOfString:@"》" options:0 range:NSMakeRange(NSMaxRange(open),synopsis.length-NSMaxRange(open))];
            if(close.location!=NSNotFound&&close.location>NSMaxRange(open)&&close.location-NSMaxRange(open)<=48)name=[synopsis substringWithRange:NSMakeRange(NSMaxRange(open),close.location-NSMaxRange(open))];
        }
    }
    if(!name.length)name=itemName.length?itemName:@"影视选集";
    return name;
}
- (NSString *)posterURL {
    NSArray *keys=@[@"banner",@"vod_pic_slide",@"poster",@"pic",@"vod_pic",@"cover",@"cover_url",@"coverUrl",@"image",@"img",@"thumbnail",@"thumb",@"poster_url",@"posterUrl"];
    for(NSDictionary *candidate in @[self.detail?:@{},self.item?:@{}])for(NSString *key in keys){
        id value=candidate[key];if(![value isKindOfClass:NSString.class])continue;
        NSURLComponents *parts=[NSURLComponents componentsWithString:[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        if([@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length&&!parts.user.length&&!parts.password.length)return parts.string;
    }
    return @"";
}
- (NSInteger)totalEpisodeCount {
    NSInteger total=0;NSArray *lines=self.lines;
    for(NSInteger index=0;index<lines.count;index++)total+=((NSArray *)[self episodesForLine:index]).count;
    if(total==0)total=[self episodesForLine:self.selectedLineIndex].count;
    return total;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.detail=MediaEpisodeSelectionSanitizedDetail(self.detail)?:@{};
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.backgroundColor=MediaSelectionBackground();
    self.title=self.titleText;
    self.selectedLineIndex=MAX(0,self.selectedLineIndex);
    self.selectedEpisodeIndex=MAX(0,self.selectedEpisodeIndex);
    if(self.selectedSeasonIndex<0||self.selectedSeasonIndex>=self.seasonCollections.count)self.selectedSeasonIndex=0;
    self.episodeButtons=[NSMutableArray array];
    if(!self.correlationID.length)self.correlationID=NSUUID.UUID.UUIDString.lowercaseString;
    NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,[self episodesForLine:self.selectedLineIndex].count,self.episodeOrderReversed);self.page=episodeGroup==NSNotFound?0:episodeGroup;
    if(!self.client){
        NSString *catalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");self.client=MediaSourceUsesNativeCatalogAPI(self.source)?[[MediaAPIClient alloc] initWithTVBoxSource:self.source?:@{}]:[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue] catalogID:catalogID];
    }
    self.refreshClient=MediaSourceUsesNativeCatalogAPI(self.source)?[[MediaAPIClient alloc] initWithTVBoxSource:self.source?:@{}]:[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue]];
    [self buildLayout];
    [self rebuildSelection];
    [self refreshBackdrop];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if(!self.savedNavigationBarVisibility){self.originalNavigationBarHidden=self.navigationController.navigationBarHidden;self.savedNavigationBarVisibility=YES;}
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self setNeedsStatusBarAppearanceUpdate];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if(self.isMovingFromParentViewController)[self.navigationController setNavigationBarHidden:self.originalNavigationBarHidden animated:animated];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if(self.isMovingFromParentViewController){self.generation++;self.refreshGeneration++;[self.client cancel];[self.refreshClient cancel];}
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.backdropGradient.frame=self.backdropTintView.bounds;
    [CATransaction commit];
}
- (void)dealloc { [self.client cancel];[self.refreshClient cancel]; }
- (void)goBack { [self.navigationController popViewControllerAnimated:YES]; }
- (UIButton *)iconButton:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;
    UIImageSymbolConfiguration *configuration=[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration] forState:UIControlStateNormal];button.tintColor=UIColor.whiteColor;button.accessibilityLabel=label;button.accessibilityTraits|=UIAccessibilityTraitButton;
    button.backgroundColor=[UIColor colorWithWhite:0 alpha:.28];button.layer.cornerRadius=15;button.layer.cornerCurve=kCACornerCurveContinuous;button.layer.borderWidth=.7;button.layer.borderColor=[UIColor colorWithWhite:1 alpha:.14].CGColor;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(button);return button;
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label=[UILabel new];label.text=text;label.font=HostMonospacedDigitFont(size,weight,UIFontTextStyleBody);label.textColor=color;label.adjustsFontForContentSizeCategory=YES;return label;
}
- (UIView *)badgeWithText:(NSString *)text prominent:(BOOL)prominent {
    UILabel *label=[self label:text size:11 weight:UIFontWeightSemibold color:prominent?UIColor.whiteColor:MediaSelectionMuted()];label.textAlignment=NSTextAlignmentCenter;label.lineBreakMode=NSLineBreakByTruncatingTail;label.numberOfLines=1;label.adjustsFontSizeToFitWidth=YES;label.minimumScaleFactor=.78;label.translatesAutoresizingMaskIntoConstraints=NO;
    UIView *badge=[UIView new];badge.translatesAutoresizingMaskIntoConstraints=NO;badge.backgroundColor=prominent?[HostAccent() colorWithAlphaComponent:.76]:[UIColor colorWithWhite:1 alpha:.10];badge.layer.cornerRadius=8;badge.layer.cornerCurve=kCACornerCurveContinuous;badge.clipsToBounds=YES;[badge addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor constant:8],[label.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:-8],[label.topAnchor constraintEqualToAnchor:badge.topAnchor constant:4],[label.bottomAnchor constraintEqualToAnchor:badge.bottomAnchor constant:-4],[badge.heightAnchor constraintGreaterThanOrEqualToConstant:24]]];return badge;
}
- (void)buildLayout {
    self.backdropImageView=[UIImageView new];self.backdropImageView.translatesAutoresizingMaskIntoConstraints=NO;self.backdropImageView.contentMode=UIViewContentModeScaleAspectFill;self.backdropImageView.clipsToBounds=YES;self.backdropImageView.alpha=.48;[self.view addSubview:self.backdropImageView];
    self.backdropBlurView=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];self.backdropBlurView.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.backdropBlurView];
    self.backdropTintView=[UIView new];self.backdropTintView.translatesAutoresizingMaskIntoConstraints=NO;self.backdropGradient=[CAGradientLayer layer];self.backdropGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:.22].CGColor,(id)[UIColor colorWithWhite:0 alpha:.78].CGColor,(id)MediaSelectionBackground().CGColor];self.backdropGradient.locations=@[@0.0,@0.43,@1.0];[self.backdropTintView.layer addSublayer:self.backdropGradient];[self.view addSubview:self.backdropTintView];
    [NSLayoutConstraint activateConstraints:@[[self.backdropImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.backdropImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.backdropImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.backdropImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.backdropBlurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.backdropBlurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.backdropBlurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.backdropBlurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.backdropTintView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.backdropTintView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.backdropTintView.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.backdropTintView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];

    UIStackView *header=[UIStackView new];header.translatesAutoresizingMaskIntoConstraints=NO;header.axis=UILayoutConstraintAxisHorizontal;header.alignment=UIStackViewAlignmentCenter;header.spacing=10;[self.view addSubview:header];
    UIButton *back=[self iconButton:@"chevron.left" label:@"返回" action:@selector(goBack)];[back setImage:nil forState:UIControlStateNormal];[back setTitle:@"‹" forState:UIControlStateNormal];back.titleLabel.font=[UIFont systemFontOfSize:32 weight:UIFontWeightMedium];back.titleEdgeInsets=UIEdgeInsetsMake(-4,0,0,0);[header addArrangedSubview:back];[back.widthAnchor constraintEqualToConstant:42].active=YES;[back.heightAnchor constraintEqualToConstant:42].active=YES;
    self.headerTitle=[self label:self.titleText size:17 weight:UIFontWeightBold color:UIColor.whiteColor];self.headerTitle.numberOfLines=1;self.headerTitle.lineBreakMode=NSLineBreakByTruncatingTail;self.headerTitle.accessibilityIdentifier=@"media-episode-header-title";[header addArrangedSubview:self.headerTitle];
    self.jumpEpisodeButton=[self iconButton:@"number" label:@"跳集定位" action:@selector(promptJumpToEpisode)];self.jumpEpisodeButton.accessibilityIdentifier=@"media-episode-jump";[header addArrangedSubview:self.jumpEpisodeButton];[self.jumpEpisodeButton.widthAnchor constraintEqualToConstant:42].active=YES;[self.jumpEpisodeButton.heightAnchor constraintEqualToConstant:42].active=YES;
    self.refreshButton=[self iconButton:@"arrow.clockwise" label:@"刷新影片分集" action:@selector(refreshDetail)];self.refreshButton.accessibilityIdentifier=@"media-episode-refresh";[header addArrangedSubview:self.refreshButton];[self.refreshButton.widthAnchor constraintEqualToConstant:42].active=YES;[self.refreshButton.heightAnchor constraintEqualToConstant:42].active=YES;
    self.refreshSpinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.refreshSpinner.translatesAutoresizingMaskIntoConstraints=NO;self.refreshSpinner.color=UIColor.whiteColor;self.refreshSpinner.hidesWhenStopped=YES;[self.refreshButton addSubview:self.refreshSpinner];[NSLayoutConstraint activateConstraints:@[[self.refreshSpinner.centerXAnchor constraintEqualToAnchor:self.refreshButton.centerXAnchor],[self.refreshSpinner.centerYAnchor constraintEqualToAnchor:self.refreshButton.centerYAnchor]]];

    self.scrollView=[UIScrollView new];self.scrollView.translatesAutoresizingMaskIntoConstraints=NO;self.scrollView.alwaysBounceVertical=YES;self.scrollView.showsVerticalScrollIndicator=NO;self.scrollView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;[self.view addSubview:self.scrollView];
    self.contentStack=[UIStackView new];self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=15;self.contentStack.layoutMargins=UIEdgeInsetsMake(8,16,24,16);self.contentStack.layoutMarginsRelativeArrangement=YES;[self.scrollView addSubview:self.contentStack];

    UIView *playBar=[UIView new];playBar.translatesAutoresizingMaskIntoConstraints=NO;playBar.backgroundColor=[UIColor colorWithRed:.035 green:.039 blue:.052 alpha:.97];playBar.layer.borderColor=[UIColor colorWithWhite:1 alpha:.10].CGColor;playBar.layer.borderWidth=.6;[self.view addSubview:playBar];
    self.continueButton=[UIButton buttonWithType:UIButtonTypeSystem];self.continueButton.translatesAutoresizingMaskIntoConstraints=NO;self.continueButton.backgroundColor=HostAccent();self.continueButton.layer.cornerRadius=27;self.continueButton.layer.cornerCurve=kCACornerCurveContinuous;self.continueButton.tintColor=UIColor.whiteColor;self.continueButton.titleLabel.font=HostRoundedFont(16,UIFontWeightBold,UIFontTextStyleHeadline);self.continueButton.titleLabel.adjustsFontForContentSizeCategory=YES;self.continueButton.titleLabel.adjustsFontSizeToFitWidth=YES;self.continueButton.titleLabel.minimumScaleFactor=.8;self.continueButton.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.continueButton.accessibilityIdentifier=@"media-episode-continue";[self.continueButton setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];self.continueButton.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,8);self.continueButton.contentEdgeInsets=UIEdgeInsetsMake(0,16,0,16);[self.continueButton addTarget:self action:@selector(playSelectedEpisode) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(self.continueButton);[playBar addSubview:self.continueButton];self.playSpinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.playSpinner.translatesAutoresizingMaskIntoConstraints=NO;self.playSpinner.color=UIColor.whiteColor;self.playSpinner.hidesWhenStopped=YES;[playBar addSubview:self.playSpinner];
    [NSLayoutConstraint activateConstraints:@[[header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],[header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[header.heightAnchor constraintEqualToConstant:44],[self.headerTitle.heightAnchor constraintGreaterThanOrEqualToConstant:32],[self.scrollView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],[self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.scrollView.bottomAnchor constraintEqualToAnchor:playBar.topAnchor],[self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],[self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],[self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor],[self.contentStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor],[playBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[playBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[playBar.topAnchor constraintEqualToAnchor:self.continueButton.topAnchor constant:-14],[playBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],[self.continueButton.leadingAnchor constraintEqualToAnchor:playBar.leadingAnchor constant:20],[self.continueButton.trailingAnchor constraintEqualToAnchor:playBar.trailingAnchor constant:-20],[self.continueButton.heightAnchor constraintEqualToConstant:54],[self.continueButton.bottomAnchor constraintEqualToAnchor:playBar.bottomAnchor constant:-10],[self.playSpinner.centerXAnchor constraintEqualToAnchor:self.continueButton.centerXAnchor],[self.playSpinner.centerYAnchor constraintEqualToAnchor:self.continueButton.centerYAnchor]]];

    UIStackView *hero=[UIStackView new];hero.translatesAutoresizingMaskIntoConstraints=NO;hero.axis=UILayoutConstraintAxisHorizontal;hero.alignment=UIStackViewAlignmentTop;hero.spacing=14;hero.accessibilityIdentifier=@"media-episode-hero";hero.layoutMarginsRelativeArrangement=YES;hero.layoutMargins=UIEdgeInsetsMake(4,4,4,4);[self.contentStack addArrangedSubview:hero];
    UIImageView *poster=[UIImageView new];poster.translatesAutoresizingMaskIntoConstraints=NO;poster.contentMode=UIViewContentModeScaleAspectFill;poster.clipsToBounds=YES;poster.backgroundColor=MediaSelectionSurface();poster.layer.cornerRadius=15;poster.layer.cornerCurve=kCACornerCurveContinuous;poster.layer.borderWidth=.7;poster.layer.borderColor=[UIColor colorWithWhite:1 alpha:.16].CGColor;poster.accessibilityLabel=@"影片海报";poster.accessibilityIdentifier=@"media-episode-poster";poster.tag=4101;[hero addArrangedSubview:poster];[poster.widthAnchor constraintEqualToConstant:88].active=YES;[poster.heightAnchor constraintEqualToAnchor:poster.widthAnchor multiplier:1.42].active=YES;
    UIStackView *heroInfo=[UIStackView new];heroInfo.axis=UILayoutConstraintAxisVertical;heroInfo.alignment=UIStackViewAlignmentFill;heroInfo.spacing=7;[hero addArrangedSubview:heroInfo];
    self.heroTitle=[self label:self.titleText size:18 weight:UIFontWeightBold color:UIColor.whiteColor];self.heroTitle.numberOfLines=3;self.heroTitle.accessibilityIdentifier=@"media-episode-title";[heroInfo addArrangedSubview:self.heroTitle];
    self.heroBadges=[UIStackView new];self.heroBadges.axis=UILayoutConstraintAxisHorizontal;self.heroBadges.alignment=UIStackViewAlignmentCenter;self.heroBadges.spacing=5;self.heroBadges.accessibilityIdentifier=@"media-episode-badges";[heroInfo addArrangedSubview:self.heroBadges];
    self.heroMetadata=[self label:@"" size:12 weight:UIFontWeightMedium color:MediaSelectionMuted()];self.heroMetadata.numberOfLines=2;[heroInfo addArrangedSubview:self.heroMetadata];
    self.heroCredits=[self label:@"" size:12 weight:UIFontWeightRegular color:MediaSelectionMuted()];self.heroCredits.numberOfLines=2;[heroInfo addArrangedSubview:self.heroCredits];

    UIView *descriptionCard=[UIView new];descriptionCard.translatesAutoresizingMaskIntoConstraints=NO;descriptionCard.backgroundColor=MediaSelectionSurface();descriptionCard.layer.cornerRadius=15;descriptionCard.layer.cornerCurve=kCACornerCurveContinuous;descriptionCard.layer.borderWidth=.6;descriptionCard.layer.borderColor=[UIColor colorWithWhite:1 alpha:.08].CGColor;[self.contentStack addArrangedSubview:descriptionCard];
    self.descriptionLabel=[self label:@"暂无简介" size:14 weight:UIFontWeightRegular color:[UIColor colorWithWhite:.91 alpha:1]];self.descriptionLabel.numberOfLines=4;self.descriptionLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.descriptionLabel.accessibilityIdentifier=@"media-episode-description";[descriptionCard addSubview:self.descriptionLabel];
    self.descriptionToggle=[UIButton buttonWithType:UIButtonTypeSystem];self.descriptionToggle.translatesAutoresizingMaskIntoConstraints=NO;self.descriptionToggle.contentHorizontalAlignment=UIControlContentHorizontalAlignmentRight;self.descriptionToggle.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];[self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];[self.descriptionToggle setTitle:@"展开简介" forState:UIControlStateNormal];self.descriptionToggle.accessibilityIdentifier=@"media-episode-description-toggle";[self.descriptionToggle addTarget:self action:@selector(toggleDescription) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(self.descriptionToggle);[descriptionCard addSubview:self.descriptionToggle];
    [NSLayoutConstraint activateConstraints:@[[self.descriptionLabel.leadingAnchor constraintEqualToAnchor:descriptionCard.leadingAnchor constant:14],[self.descriptionLabel.trailingAnchor constraintEqualToAnchor:descriptionCard.trailingAnchor constant:-14],[self.descriptionLabel.topAnchor constraintEqualToAnchor:descriptionCard.topAnchor constant:13],[self.descriptionToggle.topAnchor constraintEqualToAnchor:self.descriptionLabel.bottomAnchor constant:3],[self.descriptionToggle.trailingAnchor constraintEqualToAnchor:descriptionCard.trailingAnchor constant:-12],[self.descriptionToggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:descriptionCard.leadingAnchor constant:12],[self.descriptionToggle.bottomAnchor constraintEqualToAnchor:descriptionCard.bottomAnchor constant:-8],[self.descriptionToggle.heightAnchor constraintGreaterThanOrEqualToConstant:28]]];

    self.seasonSectionStack=[UIStackView new];self.seasonSectionStack.axis=UILayoutConstraintAxisVertical;self.seasonSectionStack.spacing=7;[self.contentStack addArrangedSubview:self.seasonSectionStack];self.seasonHeadingStack=[UIStackView new];self.seasonHeadingStack.axis=UILayoutConstraintAxisHorizontal;self.seasonHeadingStack.alignment=UIStackViewAlignmentCenter;UILabel *seasonHeading=[self label:@"系列多季" size:16 weight:UIFontWeightBold color:UIColor.whiteColor];[self.seasonHeadingStack addArrangedSubview:seasonHeading];UIView *seasonSpacer=[UIView new];[self.seasonHeadingStack addArrangedSubview:seasonSpacer];self.seasonCountLabel=[self label:@"" size:11 weight:UIFontWeightMedium color:MediaSelectionMuted()];[self.seasonHeadingStack addArrangedSubview:self.seasonCountLabel];[self.seasonSectionStack addArrangedSubview:self.seasonHeadingStack];self.seasonButtons=[UIStackView new];self.seasonButtons.translatesAutoresizingMaskIntoConstraints=NO;self.seasonButtons.axis=UILayoutConstraintAxisHorizontal;self.seasonButtons.alignment=UIStackViewAlignmentCenter;self.seasonButtons.spacing=8;self.seasonScrollView=[UIScrollView new];self.seasonScrollView.translatesAutoresizingMaskIntoConstraints=NO;self.seasonScrollView.showsHorizontalScrollIndicator=NO;self.seasonScrollView.accessibilityIdentifier=@"media-episode-season-scroll";[self.seasonScrollView addSubview:self.seasonButtons];[self.seasonSectionStack addArrangedSubview:self.seasonScrollView];self.seasonScrollHeightConstraint=[self.seasonScrollView.heightAnchor constraintEqualToConstant:0];self.seasonScrollHeightConstraint.active=YES;[NSLayoutConstraint activateConstraints:@[[self.seasonButtons.leadingAnchor constraintEqualToAnchor:self.seasonScrollView.contentLayoutGuide.leadingAnchor],[self.seasonButtons.trailingAnchor constraintEqualToAnchor:self.seasonScrollView.contentLayoutGuide.trailingAnchor],[self.seasonButtons.topAnchor constraintEqualToAnchor:self.seasonScrollView.contentLayoutGuide.topAnchor],[self.seasonButtons.bottomAnchor constraintEqualToAnchor:self.seasonScrollView.contentLayoutGuide.bottomAnchor],[self.seasonButtons.heightAnchor constraintEqualToAnchor:self.seasonScrollView.frameLayoutGuide.heightAnchor]]];self.seasonHeadingStack.hidden=YES;self.seasonScrollView.accessibilityElementsHidden=YES;self.seasonScrollView.userInteractionEnabled=NO;

    UIStackView *routeSection=[UIStackView new];routeSection.axis=UILayoutConstraintAxisVertical;routeSection.spacing=8;[self.contentStack addArrangedSubview:routeSection];
    UIStackView *routeHeading=[UIStackView new];routeHeading.axis=UILayoutConstraintAxisHorizontal;routeHeading.alignment=UIStackViewAlignmentCenter;UILabel *routeTitle=[self label:@"播放线路" size:16 weight:UIFontWeightBold color:UIColor.whiteColor];[routeHeading addArrangedSubview:routeTitle];UIView *routeSpacer=[UIView new];[routeHeading addArrangedSubview:routeSpacer];UILabel *routeHint=[self label:@"选择稳定线路" size:11 weight:UIFontWeightMedium color:MediaSelectionMuted()];[routeHeading addArrangedSubview:routeHint];[routeSection addArrangedSubview:routeHeading];
    UIScrollView *routeScroll=[UIScrollView new];routeScroll.translatesAutoresizingMaskIntoConstraints=NO;routeScroll.showsHorizontalScrollIndicator=NO;routeScroll.accessibilityIdentifier=@"media-episode-route-scroll";[routeSection addArrangedSubview:routeScroll];self.routeButtons=[UIStackView new];self.routeButtons.translatesAutoresizingMaskIntoConstraints=NO;self.routeButtons.axis=UILayoutConstraintAxisHorizontal;self.routeButtons.alignment=UIStackViewAlignmentCenter;self.routeButtons.spacing=8;[routeScroll addSubview:self.routeButtons];[NSLayoutConstraint activateConstraints:@[[routeScroll.heightAnchor constraintEqualToConstant:44],[self.routeButtons.leadingAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.leadingAnchor],[self.routeButtons.trailingAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.trailingAnchor],[self.routeButtons.topAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.topAnchor],[self.routeButtons.bottomAnchor constraintEqualToAnchor:routeScroll.contentLayoutGuide.bottomAnchor],[self.routeButtons.heightAnchor constraintEqualToAnchor:routeScroll.frameLayoutGuide.heightAnchor]]];

    UIView *episodeCard=[UIView new];episodeCard.translatesAutoresizingMaskIntoConstraints=NO;episodeCard.backgroundColor=[UIColor colorWithRed:.075 green:.080 blue:.104 alpha:.94];episodeCard.layer.cornerRadius=17;episodeCard.layer.cornerCurve=kCACornerCurveContinuous;episodeCard.layer.borderWidth=.7;episodeCard.layer.borderColor=[UIColor colorWithWhite:1 alpha:.09].CGColor;episodeCard.clipsToBounds=YES;episodeCard.accessibilityIdentifier=@"media-episode-card";[self.contentStack addArrangedSubview:episodeCard];
    UIStackView *episodeCardStack=[UIStackView new];episodeCardStack.translatesAutoresizingMaskIntoConstraints=NO;episodeCardStack.axis=UILayoutConstraintAxisVertical;episodeCardStack.spacing=0;[episodeCard addSubview:episodeCardStack];[NSLayoutConstraint activateConstraints:@[[episodeCardStack.leadingAnchor constraintEqualToAnchor:episodeCard.leadingAnchor constant:12],[episodeCardStack.trailingAnchor constraintEqualToAnchor:episodeCard.trailingAnchor constant:-12],[episodeCardStack.topAnchor constraintEqualToAnchor:episodeCard.topAnchor constant:4],[episodeCardStack.bottomAnchor constraintEqualToAnchor:episodeCard.bottomAnchor constant:-8]]];
    self.quickEpisodeScroll=[UIScrollView new];self.quickEpisodeScroll.translatesAutoresizingMaskIntoConstraints=NO;self.quickEpisodeScroll.showsHorizontalScrollIndicator=NO;self.quickEpisodeScroll.accessibilityIdentifier=@"media-episode-quick-scroll";[episodeCardStack addArrangedSubview:self.quickEpisodeScroll];
    self.quickEpisodeStack=[UIStackView new];self.quickEpisodeStack.translatesAutoresizingMaskIntoConstraints=NO;self.quickEpisodeStack.axis=UILayoutConstraintAxisHorizontal;self.quickEpisodeStack.alignment=UIStackViewAlignmentCenter;self.quickEpisodeStack.spacing=8;[self.quickEpisodeScroll addSubview:self.quickEpisodeStack];
    [NSLayoutConstraint activateConstraints:@[[self.quickEpisodeScroll.heightAnchor constraintEqualToConstant:44],[self.quickEpisodeStack.leadingAnchor constraintEqualToAnchor:self.quickEpisodeScroll.contentLayoutGuide.leadingAnchor],[self.quickEpisodeStack.trailingAnchor constraintEqualToAnchor:self.quickEpisodeScroll.contentLayoutGuide.trailingAnchor],[self.quickEpisodeStack.topAnchor constraintEqualToAnchor:self.quickEpisodeScroll.contentLayoutGuide.topAnchor],[self.quickEpisodeStack.bottomAnchor constraintEqualToAnchor:self.quickEpisodeScroll.contentLayoutGuide.bottomAnchor],[self.quickEpisodeStack.heightAnchor constraintEqualToAnchor:self.quickEpisodeScroll.frameLayoutGuide.heightAnchor]]];
    self.episodeDisclosureButton=[UIButton buttonWithType:UIButtonTypeSystem];self.episodeDisclosureButton.translatesAutoresizingMaskIntoConstraints=NO;self.episodeDisclosureButton.accessibilityIdentifier=@"media-episode-disclosure";self.episodeDisclosureButton.accessibilityHint=@"展开或收起可播放分集";self.episodeDisclosureButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentFill;[self.episodeDisclosureButton addTarget:self action:@selector(toggleEpisodeGrid) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(self.episodeDisclosureButton);[episodeCardStack addArrangedSubview:self.episodeDisclosureButton];[self.episodeDisclosureButton.heightAnchor constraintEqualToConstant:50].active=YES;
    UIStackView *disclosureRow=[UIStackView new];disclosureRow.translatesAutoresizingMaskIntoConstraints=NO;disclosureRow.axis=UILayoutConstraintAxisHorizontal;disclosureRow.alignment=UIStackViewAlignmentCenter;disclosureRow.spacing=9;disclosureRow.userInteractionEnabled=NO;[self.episodeDisclosureButton addSubview:disclosureRow];UIImageView *gridIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"]];gridIcon.tintColor=HostAccent();[disclosureRow addArrangedSubview:gridIcon];[gridIcon.widthAnchor constraintEqualToConstant:19].active=YES;UILabel *episodeHeading=[self label:@"选集" size:15 weight:UIFontWeightBold color:UIColor.whiteColor];[disclosureRow addArrangedSubview:episodeHeading];self.episodeCountLabel=[self label:@"" size:12 weight:UIFontWeightMedium color:MediaSelectionMuted()];[disclosureRow addArrangedSubview:self.episodeCountLabel];UIView *disclosureSpacer=[UIView new];[disclosureRow addArrangedSubview:disclosureSpacer];self.episodeDisclosureLabel=[self label:@"展开" size:12 weight:UIFontWeightSemibold color:MediaSelectionMuted()];[disclosureRow addArrangedSubview:self.episodeDisclosureLabel];self.episodeDisclosureIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];self.episodeDisclosureIcon.tintColor=MediaSelectionMuted();[disclosureRow addArrangedSubview:self.episodeDisclosureIcon];[self.episodeDisclosureIcon.widthAnchor constraintEqualToConstant:14].active=YES;[NSLayoutConstraint activateConstraints:@[[disclosureRow.leadingAnchor constraintEqualToAnchor:self.episodeDisclosureButton.leadingAnchor],[disclosureRow.trailingAnchor constraintEqualToAnchor:self.episodeDisclosureButton.trailingAnchor],[disclosureRow.topAnchor constraintEqualToAnchor:self.episodeDisclosureButton.topAnchor],[disclosureRow.bottomAnchor constraintEqualToAnchor:self.episodeDisclosureButton.bottomAnchor]]];
    self.episodeDetails=[UIStackView new];self.episodeDetails.axis=UILayoutConstraintAxisVertical;self.episodeDetails.spacing=9;self.episodeDetails.hidden=YES;[episodeCardStack addArrangedSubview:self.episodeDetails];
    self.pageLabel=[self label:@"" size:11 weight:UIFontWeightMedium color:MediaSelectionMuted()];self.pageLabel.numberOfLines=1;self.pageLabel.textAlignment=NSTextAlignmentCenter;self.pageLabel.accessibilityIdentifier=@"media-episode-page-label";[self.episodeDetails addArrangedSubview:self.pageLabel];
    UIStackView *paging=[UIStackView new];paging.axis=UILayoutConstraintAxisHorizontal;paging.alignment=UIStackViewAlignmentCenter;paging.distribution=UIStackViewDistributionFillEqually;paging.spacing=7;self.reverseButton=[UIButton buttonWithType:UIButtonTypeSystem];self.previousButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextButton=[UIButton buttonWithType:UIButtonTypeSystem];self.reverseButton.accessibilityIdentifier=@"media-episode-reverse";self.previousButton.accessibilityIdentifier=@"media-episode-previous";self.nextButton.accessibilityIdentifier=@"media-episode-next";[self.reverseButton addTarget:self action:@selector(toggleEpisodeOrder) forControlEvents:UIControlEventTouchUpInside];[self.previousButton addTarget:self action:@selector(previousPage) forControlEvents:UIControlEventTouchUpInside];[self.nextButton addTarget:self action:@selector(nextPage) forControlEvents:UIControlEventTouchUpInside];for(UIButton *button in @[self.reverseButton,self.previousButton,self.nextButton]){button.backgroundColor=[UIColor colorWithWhite:1 alpha:.08];button.layer.cornerRadius=11;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];MediaEpisodeApplyScaledPillFont(button);[button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];[button setTitleColor:MediaSelectionMuted() forState:UIControlStateDisabled];button.contentEdgeInsets=UIEdgeInsetsMake(8,7,8,7);HostInstallPressFeedback(button);[paging addArrangedSubview:button];}[self.episodeDetails addArrangedSubview:paging];[paging.heightAnchor constraintGreaterThanOrEqualToConstant:38].active=YES;
    self.episodeGrid=[UIStackView new];self.episodeGrid.axis=UILayoutConstraintAxisVertical;self.episodeGrid.spacing=7;self.episodeGrid.distribution=UIStackViewDistributionFillEqually;self.episodeGrid.accessibilityIdentifier=@"media-episode-grid";[self.episodeDetails addArrangedSubview:self.episodeGrid];
    self.statusLabel=[self label:@"" size:12 weight:UIFontWeightMedium color:MediaSelectionMuted()];self.statusLabel.numberOfLines=0;self.statusLabel.hidden=YES;self.statusLabel.accessibilityIdentifier=@"media-episode-status";[self.contentStack addArrangedSubview:self.statusLabel];
    [self updateDescription];
}
- (void)refreshBackdrop {
    NSString *url=[self posterURL];
    UIImageView *poster=[self.view viewWithTag:4101];
    if(url.length){MediaEpisodeSelectionLoadPoster(url,self.backdropImageView,1);if(poster)MediaEpisodeSelectionLoadPoster(url,poster,1);}
    else{self.backdropImageView.image=nil;self.backdropImageView.accessibilityIdentifier=nil;if(poster){poster.image=[UIImage systemImageNamed:@"film"];poster.accessibilityIdentifier=nil;poster.contentMode=UIViewContentModeCenter;}}
}
- (void)updateDescription {
    NSString *synopsis=[self.detail[@"description"] isKindOfClass:NSString.class]?self.detail[@"description"]:@"";
    if(!synopsis.length)synopsis=[self.detail[@"vod_content"] isKindOfClass:NSString.class]?self.detail[@"vod_content"]:@"暂无简介，选择分集后即可开始播放。";
    if(synopsis.length>1800)synopsis=[[synopsis substringToIndex:1800] stringByAppendingString:@"…"];
    self.descriptionLabel.text=synopsis;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:4;self.descriptionToggle.hidden=synopsis.length<100;[self.descriptionToggle setTitle:self.descriptionExpanded?@"收起简介":@"展开简介" forState:UIControlStateNormal];
}
- (void)rebuildHeroBadges {
    UIStackView *badges=self.heroBadges;
    self.title=self.titleText;self.heroTitle.text=self.titleText;self.headerTitle.text=self.titleText;
    if(!badges)return;
    for(UIView *view in badges.arrangedSubviews.copy){[badges removeArrangedSubview:view];[view removeFromSuperview];}
    NSSet<NSString *> *ignoredTokens=[NSSet setWithArray:@[@"url",@"http",@"https",@"null",@"nil",@"none",@"unknown",@"default",@"undefined",@"n/a",@"nan",@"0",@"未知",@"其它",@"其他",@"[object object]",@"[object array]",@"{}",@"[]"]];
    NSMutableArray *values=[NSMutableArray array];for(NSString *key in @[@"year",@"type",@"vod_class",@"remarks"]){id rawVal=self.detail[key];if(![rawVal isKindOfClass:NSString.class])continue;NSString *value=[(NSString *)rawVal stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!value.length||value.length>24||[value containsString:@"。"]||[value containsString:@"，"]||[ignoredTokens containsObject:value.lowercaseString])continue;if(![values containsObject:value])[values addObject:value];}
    if(self.seasonCollections.count>1)[values insertObject:[NSString stringWithFormat:@"共 %lu 季",(unsigned long)self.seasonCollections.count] atIndex:0];
    NSUInteger lineCount=self.lines.count;if(lineCount)[values addObject:[NSString stringWithFormat:@"%lu 条线路",(unsigned long)lineCount]];
    if(!values.count)[values addObject:self.source[@"name"]?:@"影视资源"];
    for(NSUInteger index=0;index<MIN(values.count,3);index++)[badges addArrangedSubview:[self badgeWithText:values[index] prominent:index==0]];
    NSMutableArray *metadata=[NSMutableArray array];for(NSString *key in @[@"area",@"lang"]){NSString *value=[self.detail[key] isKindOfClass:NSString.class]?self.detail[key]:@"";if(value.length)[metadata addObject:value];}self.heroMetadata.text=metadata.count?[metadata componentsJoinedByString:@" · "]:@"精选影视 · 选择线路后播放";
    NSMutableArray *credits=[NSMutableArray array];for(NSString *key in @[@"actor",@"director"]){NSString *value=[self.detail[key] isKindOfClass:NSString.class]?self.detail[key]:@"";if(value.length)[credits addObject:[NSString stringWithFormat:@"%@ %@",[key isEqual:@"actor"]?@"主演":@"导演",value]];}
    self.heroCredits.text=credits.count?[credits componentsJoinedByString:@"\n"]:@"";self.heroCredits.hidden=!credits.count;
}
- (void)refreshDetail {
    if(!self.refreshClient||self.refreshSpinner.isAnimating)return;
    NSUInteger generation=++self.refreshGeneration;[self.refreshSpinner startAnimating];self.refreshButton.tintColor=UIColor.clearColor;
    NSMutableDictionary *args=[@{@"id":self.item[@"id"]?:self.detail[@"id"]?:@""} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;
    __weak typeof(self) weakSelf=self;
    [self.refreshClient call:@"detail" arguments:args correlationID:self.correlationID completion:^(id result,NSError *error){
        MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner||owner.refreshGeneration!=generation)return;[owner.refreshSpinner stopAnimating];owner.refreshButton.tintColor=UIColor.whiteColor;
        NSDictionary *sanitized=MediaEpisodeSelectionSanitizedDetail(result);if(error||!sanitized){owner.statusLabel.text=[NSString stringWithFormat:@"刷新失败，保留当前分集：%@",error.localizedDescription?:@"来源未返回详情"];owner.statusLabel.hidden=NO;return;}
        owner.generation++;[owner.client cancel];[owner.playSpinner stopAnimating];owner.playSpinner.hidden=YES;owner.continueButton.enabled=YES;
        NSDictionary *oldSeason=owner.currentSeason;NSString *seasonID=[oldSeason[@"id"] description]?:@"",*seasonName=[oldSeason[@"name"] description]?:@"";
        NSArray *oldLines=owner.lines;NSDictionary *oldLine=owner.selectedLineIndex<oldLines.count?oldLines[(NSUInteger)owner.selectedLineIndex]:@{};NSString *lineID=[oldLine[@"id"] description]?:@"",*lineName=[oldLine[@"name"] description]?:@"";
        NSArray *oldEpisodes=[owner episodesForLine:owner.selectedLineIndex];NSDictionary *oldEpisode=owner.selectedEpisodeIndex<oldEpisodes.count?oldEpisodes[(NSUInteger)owner.selectedEpisodeIndex]:@{};NSString *episodeID=[oldEpisode[@"id"] description]?:@"",*episodeName=[oldEpisode[@"name"] description]?:@"";NSInteger oldSeasonIndex=owner.selectedSeasonIndex,oldLineIndex=owner.selectedLineIndex,oldEpisodeIndex=owner.selectedEpisodeIndex;
        owner.detail=sanitized;NSArray *newSeasons=owner.seasonCollections;owner.selectedSeasonIndex=newSeasons.count?MIN(MAX(0,oldSeasonIndex),(NSInteger)newSeasons.count-1):0;BOOL seasonMatched=NO;
        if(seasonID.length){for(NSUInteger index=0;index<newSeasons.count;index++){NSDictionary *candidate=newSeasons[index];if([[candidate[@"id"] description] isEqual:seasonID]){owner.selectedSeasonIndex=(NSInteger)index;seasonMatched=YES;break;}}}
        if(!seasonMatched&&seasonName.length){for(NSUInteger index=0;index<newSeasons.count;index++){NSDictionary *candidate=newSeasons[index];if([[candidate[@"name"] description] localizedCaseInsensitiveCompare:seasonName]==NSOrderedSame){owner.selectedSeasonIndex=(NSInteger)index;seasonMatched=YES;break;}}}
        NSArray *newLines=owner.lines;owner.selectedLineIndex=newLines.count?MIN(MAX(0,oldLineIndex),(NSInteger)newLines.count-1):0;
        BOOL lineMatched=NO;if(lineID.length){for(NSUInteger index=0;index<newLines.count;index++){NSDictionary *candidate=newLines[index];if([[candidate[@"id"] description] isEqual:lineID]){owner.selectedLineIndex=(NSInteger)index;lineMatched=YES;break;}}}
        if(!lineMatched&&lineName.length){for(NSUInteger index=0;index<newLines.count;index++){NSDictionary *candidate=newLines[index];if([[candidate[@"name"] description] localizedCaseInsensitiveCompare:lineName]==NSOrderedSame){owner.selectedLineIndex=(NSInteger)index;lineMatched=YES;break;}}}
        NSArray *newEpisodes=[owner episodesForLine:owner.selectedLineIndex];owner.selectedEpisodeIndex=newEpisodes.count?MIN(MAX(0,oldEpisodeIndex),(NSInteger)newEpisodes.count-1):0;
        BOOL episodeMatched=NO;if(episodeID.length){for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *candidate=newEpisodes[index];if([[candidate[@"id"] description] isEqual:episodeID]){owner.selectedEpisodeIndex=(NSInteger)index;episodeMatched=YES;break;}}}
        if(!episodeMatched&&episodeName.length){for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *candidate=newEpisodes[index];if([[candidate[@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame){owner.selectedEpisodeIndex=(NSInteger)index;episodeMatched=YES;break;}}}
        owner.page=CCTVEpisodeGroupForSourceIndex((NSUInteger)MAX(0,owner.selectedEpisodeIndex),newEpisodes.count,owner.episodeOrderReversed);
        owner.statusLabel.hidden=YES;[owner refreshBackdrop];[owner updateDescription];[owner rebuildSelection];
    }];
}
- (void)buildSeasons {
    NSArray *seasons=self.seasonCollections;BOOL hasSeasons=seasons.count>1;self.seasonHeadingStack.hidden=!hasSeasons;self.seasonCountLabel.text=hasSeasons?[NSString stringWithFormat:@"共 %lu 季 · 快速切季",(unsigned long)seasons.count]:@"";self.seasonSectionStack.spacing=hasSeasons?7:0;self.seasonScrollHeightConstraint.constant=hasSeasons?46:0;self.seasonScrollView.accessibilityElementsHidden=!hasSeasons;self.seasonScrollView.userInteractionEnabled=hasSeasons;
    for(UIView *view in self.seasonButtons.arrangedSubviews.copy){[self.seasonButtons removeArrangedSubview:view];[view removeFromSuperview];}
    for(NSUInteger index=0;index<seasons.count;index++){
        NSDictionary *season=[seasons[index] isKindOfClass:NSDictionary.class]?seasons[index]:@{};NSString *name=[season[@"name"] isKindOfClass:NSString.class]?season[@"name"]:[season[@"title"] isKindOfClass:NSString.class]?season[@"title"]:[NSString stringWithFormat:@"第 %lu 季",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-season-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];button.contentEdgeInsets=UIEdgeInsetsMake(8,14,8,14);button.layer.cornerRadius=15;button.layer.cornerCurve=kCACornerCurveContinuous;BOOL selected=index==(NSUInteger)self.selectedSeasonIndex;button.backgroundColor=selected?HostAccent():[UIColor colorWithWhite:1 alpha:.10];[button setTitleColor:selected?UIColor.whiteColor:MediaSelectionMuted() forState:UIControlStateNormal];[button addTarget:self action:@selector(selectSeason:) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(button);[self.seasonButtons addArrangedSubview:button];
    }
}
- (void)rebuildSelection {
    if(self.selectedSeasonIndex>=self.seasonCollections.count)self.selectedSeasonIndex=0;
    if(self.selectedLineIndex>=self.lines.count)self.selectedLineIndex=0;
    [self rebuildHeroBadges];[self buildSeasons];
    for(UIView *button in self.routeButtons.arrangedSubviews.copy){[self.routeButtons removeArrangedSubview:button];[button removeFromSuperview];}
    for(NSUInteger index=0;index<self.lines.count;index++){
        NSDictionary *line=[self.lines[index] isKindOfClass:NSDictionary.class]?self.lines[index]:@{};NSString *name=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)index+1];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-route-%lu",(unsigned long)index];[button setTitle:name forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];MediaEpisodeApplyScaledPillFont(button);button.contentEdgeInsets=UIEdgeInsetsMake(8,13,8,13);button.layer.cornerRadius=15;button.layer.cornerCurve=kCACornerCurveContinuous;BOOL selected=index==(NSUInteger)self.selectedLineIndex;button.backgroundColor=selected?HostAccent():[UIColor colorWithWhite:1 alpha:.10];[button setTitleColor:selected?UIColor.whiteColor:MediaSelectionMuted() forState:UIControlStateNormal];[button addTarget:self action:@selector(selectRoute:) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(button);[self.routeButtons addArrangedSubview:button];
    }
    NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;NSUInteger pages=MAX(1,(episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup);self.page=MIN(MAX(0,self.page),(NSInteger)pages-1);NSUInteger start=(NSUInteger)self.page*CCTVEpisodesPerGroup,end=MIN(start+CCTVEpisodesPerGroup,episodes.count);
    NSUInteger firstSource=end>start?CCTVEpisodeSourceIndex(start,episodes.count,self.episodeOrderReversed):0,lastSource=end>start?CCTVEpisodeSourceIndex(end-1,episodes.count,self.episodeOrderReversed):0;
    self.pageLabel.text=episodes.count?[NSString stringWithFormat:@"第 %ld/%lu 组 · 第 %lu–%lu 集 · %@",(long)self.page+1,(unsigned long)pages,(unsigned long)firstSource+1,(unsigned long)lastSource+1,self.episodeOrderReversed?@"倒序":@"正序"]:@"当前线路没有可选分集";
    self.episodeCountLabel.text=episodes.count?[NSString stringWithFormat:@"· %lu 集 · 当前第 %lu 集",(unsigned long)episodes.count,(unsigned long)self.selectedEpisodeIndex+1]:@"· 暂无分集";
    if(!self.lines.count)self.statusLabel.text=@"此影片没有可用分集，请返回详情页重新加载或更换来源。";else if(!episodes.count)self.statusLabel.text=@"当前线路没有可选分集，请切换其他线路。";else self.statusLabel.text=@"";
    self.statusLabel.hidden=!self.statusLabel.text.length;
    BOOL expanded=self.episodeExpanded;self.episodeDisclosureLabel.text=expanded?@"收起":@"展开";self.episodeDisclosureIcon.image=[UIImage systemImageNamed:expanded?@"chevron.up":@"chevron.down"];self.episodeDetails.hidden=!expanded;self.episodeDisclosureButton.accessibilityValue=expanded?@"已展开":@"已收起";
    [self.reverseButton setTitle:self.episodeOrderReversed?@"正序排列":@"倒序排列" forState:UIControlStateNormal];self.reverseButton.accessibilityLabel=self.episodeOrderReversed?@"按正序排列分集，当前为倒序":@"按倒序排列分集，当前为正序";self.reverseButton.hidden=episodes.count<2;
    self.previousButton.hidden=pages<=1;self.nextButton.hidden=pages<=1;self.previousButton.enabled=self.page>0;self.nextButton.enabled=self.page+1<pages;[self.previousButton setTitle:@"‹ 上一组" forState:UIControlStateNormal];[self.nextButton setTitle:@"下一组 ›" forState:UIControlStateNormal];
    for(UIView *chip in self.quickEpisodeStack.arrangedSubviews.copy){[self.quickEpisodeStack removeArrangedSubview:chip];[chip removeFromSuperview];}
    self.quickEpisodeScroll.hidden=episodes.count==0;
    for(NSUInteger quickIdx=0;quickIdx<MIN((NSUInteger)24,episodes.count);quickIdx++){NSDictionary *ep=episodes[quickIdx];NSString *epName=[ep[@"name"] isKindOfClass:NSString.class]&&[ep[@"name"] length]?ep[@"name"]:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)quickIdx+1];UIButton *chip=[UIButton buttonWithType:UIButtonTypeSystem];chip.tag=(NSInteger)quickIdx;[chip setTitle:epName forState:UIControlStateNormal];HostStylePillButton(chip,(NSInteger)quickIdx==self.selectedEpisodeIndex);chip.layer.cornerRadius=12;chip.contentEdgeInsets=UIEdgeInsetsMake(6,12,6,12);[chip addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.quickEpisodeStack addArrangedSubview:chip];}
    for(UIView *row in self.episodeGrid.arrangedSubviews.copy){[self.episodeGrid removeArrangedSubview:row];[row removeFromSuperview];}[self.episodeButtons removeAllObjects];
    NSUInteger columns=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?3:4;
    for(NSUInteger rowIndex=0;rowIndex*columns<end-start;rowIndex++){
        UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=7;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<columns;col++){
            NSUInteger displayIndex=start+rowIndex*columns+col;UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.layer.cornerRadius=14;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;button.accessibilityTraits|=UIAccessibilityTraitButton;
            if(displayIndex<end){NSUInteger index=CCTVEpisodeSourceIndex(displayIndex,episodes.count,self.episodeOrderReversed);NSDictionary *episode=episodes[index];NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];[button setTitle:name forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-episode-item-%lu",(unsigned long)index];button.accessibilityLabel=[NSString stringWithFormat:@"%@，第 %lu 集",name,(unsigned long)index+1];BOOL selected=self.selectionUpdatesPlayer&&(NSInteger)index==self.selectedEpisodeIndex;button.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:.78]:[UIColor colorWithWhite:1 alpha:.08];[button setTitleColor:selected?UIColor.whiteColor:MediaSelectionMuted() forState:UIControlStateNormal];button.layer.borderWidth=selected?0:.6;button.layer.borderColor=[UIColor colorWithWhite:1 alpha:.09].CGColor;[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(button);[self.episodeButtons addObject:button];}else{button.hidden=YES;button.accessibilityElementsHidden=YES;}
            [row addArrangedSubview:button];
        }
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
    if(!self.statusLabel.text.length)self.statusLabel.hidden=YES;
    NSString *episodeName=episodes.count?[episodes[(NSUInteger)self.selectedEpisodeIndex][@"name"] description]:@"暂无可播放分集";if(!episodeName.length)episodeName=[NSString stringWithFormat:@"第 %ld 集",(long)self.selectedEpisodeIndex+1];
    [self.continueButton setTitle:episodes.count?[NSString stringWithFormat:@"继续播放  ·  %@",episodeName]:episodeName forState:UIControlStateNormal];self.continueButton.accessibilityValue=episodes.count?[NSString stringWithFormat:@"当前选择 %@",episodeName]:@"没有可播放分集";self.continueButton.enabled=episodes.count>0;self.continueButton.alpha=episodes.count?1:.56;
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner)return;
        if(owner.selectedLineIndex>=0&&(NSUInteger)owner.selectedLineIndex<owner.routeButtons.arrangedSubviews.count&&[owner.routeButtons.superview isKindOfClass:UIScrollView.class]){
            UIView *activeRoute=owner.routeButtons.arrangedSubviews[(NSUInteger)owner.selectedLineIndex];
            [(UIScrollView *)owner.routeButtons.superview scrollRectToVisible:[activeRoute convertRect:activeRoute.bounds toView:owner.routeButtons.superview] animated:YES];
        }
        if(owner.selectedEpisodeIndex>=0&&(NSUInteger)owner.selectedEpisodeIndex<owner.quickEpisodeStack.arrangedSubviews.count&&owner.quickEpisodeScroll){
            UIView *activeChip=owner.quickEpisodeStack.arrangedSubviews[(NSUInteger)owner.selectedEpisodeIndex];
            [owner.quickEpisodeScroll scrollRectToVisible:[activeChip convertRect:activeChip.bounds toView:owner.quickEpisodeScroll] animated:YES];
        }
    });
}
- (void)selectRoute:(UIButton *)sender {
    NSArray *oldEpisodes=[self episodesForLine:self.selectedLineIndex];NSDictionary *oldEpisode=self.selectedEpisodeIndex>=0&&self.selectedEpisodeIndex<oldEpisodes.count?oldEpisodes[(NSUInteger)self.selectedEpisodeIndex]:@{};NSString *episodeID=[oldEpisode[@"id"] description]?:@"",*episodeName=[oldEpisode[@"name"] description]?:@"";NSInteger oldIndex=self.selectedEpisodeIndex;
    self.generation++;[self.client cancel];[self.playSpinner stopAnimating];self.playSpinner.hidden=YES;NSInteger line=MAX(0,sender.tag);if(self.lines.count)line=MIN(line,(NSInteger)self.lines.count-1);self.selectedLineIndex=line;NSArray *newEpisodes=[self episodesForLine:self.selectedLineIndex];NSInteger match=-1;
    if(episodeID.length){for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *episode=newEpisodes[index];if([[episode[@"id"] description] isEqual:episodeID]){match=(NSInteger)index;break;}}}
    if(match<0&&episodeName.length){for(NSUInteger index=0;index<newEpisodes.count;index++){NSDictionary *episode=newEpisodes[index];if([[episode[@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame){match=(NSInteger)index;break;}}}
    self.selectedEpisodeIndex=newEpisodes.count?(match>=0?match:MIN(MAX(0,oldIndex),(NSInteger)newEpisodes.count-1)):0;self.page=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,newEpisodes.count,self.episodeOrderReversed);self.statusLabel.text=@"";self.statusLabel.hidden=YES;[self rebuildSelection];
}
- (void)selectSeason:(UIButton *)sender {
    self.generation++;[self.client cancel];[self.playSpinner stopAnimating];self.playSpinner.hidden=YES;self.selectedSeasonIndex=sender.tag;self.selectedEpisodeIndex=0;self.page=0;self.statusLabel.text=@"";self.statusLabel.hidden=YES;[self rebuildSelection];
}
- (void)toggleEpisodeGrid {
    self.episodeExpanded=!self.episodeExpanded;[self rebuildSelection];if(!UIAccessibilityIsReduceMotionEnabled())[UIView animateWithDuration:.22 animations:^{[self.view layoutIfNeeded];}];
}
- (void)toggleDescription {
    self.descriptionExpanded=!self.descriptionExpanded;[self updateDescription];if(!UIAccessibilityIsReduceMotionEnabled())[UIView animateWithDuration:.22 animations:^{[self.view layoutIfNeeded];}];
}
- (void)toggleEpisodeOrder {
    NSArray *episodes=[self episodesForLine:self.selectedLineIndex];self.episodeOrderReversed=!self.episodeOrderReversed;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)MAX(0,self.selectedEpisodeIndex),episodes.count,self.episodeOrderReversed);self.page=episodeGroup==NSNotFound?0:episodeGroup;
    [RuntimeDiagnostics.shared recordEvent:@"media_episode_order_changed" category:@"playback" fields:@{@"correlation_id":self.correlationID?:@"",@"line_index":@(self.selectedLineIndex),@"episode_count":@(episodes.count),@"selected_episode_index":@(self.selectedEpisodeIndex),@"reversed":@(self.episodeOrderReversed)}];[self rebuildSelection];
}
- (void)promptJumpToEpisode {
    NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(!episodes.count)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"快速跳集" message:[NSString stringWithFormat:@"共 %lu 集，输入集数编号（1–%lu）或分集名称直接定位",(unsigned long)episodes.count,(unsigned long)episodes.count] preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"例如：12 或 第12集";field.keyboardType=UIKeyboardTypeNumbersAndPunctuation;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"定位并展开" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner)return;
        NSString *query=[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!query.length)return;
        NSArray *currentEpisodes=[owner episodesForLine:owner.selectedLineIndex];if(!currentEpisodes.count)return;
        NSInteger targetIndex=-1;NSInteger numeric=[query integerValue];
        if(numeric>=1&&numeric<=(NSInteger)currentEpisodes.count)targetIndex=numeric-1;
        else{for(NSUInteger i=0;i<currentEpisodes.count;i++){NSString *name=[currentEpisodes[i][@"name"] description]?:@"";if([name localizedCaseInsensitiveContainsString:query]){targetIndex=(NSInteger)i;break;}}}
        if(targetIndex>=0&&targetIndex<(NSInteger)currentEpisodes.count){
            owner.selectedEpisodeIndex=targetIndex;owner.episodeExpanded=YES;
            NSInteger group=CCTVEpisodeGroupForSourceIndex((NSUInteger)targetIndex,currentEpisodes.count,owner.episodeOrderReversed);
            owner.page=group==NSNotFound?0:group;[owner rebuildSelection];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)previousPage {if(self.page>0){self.page--;[self rebuildSelection];}}
- (void)nextPage {NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(self.page+1<(NSInteger)((episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup)){self.page++;[self rebuildSelection];}}
- (void)playSelectedEpisode {if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=[self episodesForLine:self.selectedLineIndex].count)return;UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];button.tag=self.selectedEpisodeIndex;[self selectEpisode:button];}
- (void)selectEpisode:(UIButton *)sender {
    if(self.selectedLineIndex<0||self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=[self episodesForLine:self.selectedLineIndex];if(sender.tag<0||sender.tag>=episodes.count)return;
    NSDictionary *episode=episodes[sender.tag];NSString *episodeID=[episode[@"id"] description]?:@"",*episodeName=[episode[@"name"] description]?:@"当前分集",*episodeLineID=[episode[@"lineId"] description]?:@"";NSInteger selectedIndex=sender.tag;
    if(episodeLineID.length){for(NSUInteger index=0;index<self.lines.count;index++){NSDictionary *routeLine=[self.lines[index] isKindOfClass:NSDictionary.class]?self.lines[index]:@{};NSString *lineID=[routeLine[@"id"] description]?:@"",*lineName=[routeLine[@"name"] description]?:@"";if([episodeLineID isEqual:lineID]||[episodeLineID isEqual:lineName]){NSArray *routeEpisodes=[self episodesForLine:(NSInteger)index];NSInteger match=-1;for(NSUInteger candidate=0;candidate<routeEpisodes.count;candidate++){NSDictionary *row=routeEpisodes[candidate];if((episodeID.length&&[[row[@"id"] description] isEqual:episodeID])||[[row[@"name"] description] isEqual:episodeName]){match=(NSInteger)candidate;break;}}if(match<0&&sender.tag<routeEpisodes.count)match=sender.tag;if(match>=0){self.selectedLineIndex=(NSInteger)index;selectedIndex=match;}break;}}}
    episodes=[self episodesForLine:self.selectedLineIndex];if(selectedIndex<0||selectedIndex>=episodes.count)return;episode=episodes[(NSUInteger)selectedIndex];NSDictionary *line=self.selectedLineIndex<self.lines.count?([self.lines[self.selectedLineIndex] isKindOfClass:NSDictionary.class]?self.lines[self.selectedLineIndex]:@{}):@{};
    self.selectedEpisodeIndex=selectedIndex;NSInteger capturedLineIndex=self.selectedLineIndex,capturedEpisodeIndex=selectedIndex;NSInteger episodeGroup=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,episodes.count,self.episodeOrderReversed);self.page=episodeGroup==NSNotFound?0:episodeGroup;self.episodeExpanded=YES;[self rebuildSelection];[self.client cancel];NSUInteger generation=++self.generation;episodeName=[episode[@"name"] description]?:@"当前分集";self.statusLabel.text=[NSString stringWithFormat:@"正在解析 %@…",episodeName];self.statusLabel.hidden=NO;self.continueButton.enabled=NO;self.playSpinner.hidden=NO;[self.playSpinner startAnimating];
    [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.correlationID?:@"",@"request_generation":@(generation),@"line_index":@(capturedLineIndex),@"episode_index":@(capturedEpisodeIndex)}];
    NSString *parserID=[self currentParserID];NSString *vodTitle=[self titleText];NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@"",@"parserID":parserID,@"vodName":vodTitle,@"episodeName":episodeName?:@"",@"episodeIndex":@(capturedEpisodeIndex)} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    if(!self.client){[self.playSpinner stopAnimating];self.playSpinner.hidden=YES;self.continueButton.enabled=YES;self.statusLabel.text=@"无法解析 · 播放服务不可用，请返回重试";self.statusLabel.hidden=NO;return;}
    [self.client call:@"play" arguments:args correlationID:self.correlationID completion:^(id result,NSError *error){
        MediaEpisodeSelectionViewController *owner=weakSelf;if(!owner||owner.generation!=generation)return;[owner.playSpinner stopAnimating];owner.playSpinner.hidden=YES;owner.continueButton.enabled=YES;owner.statusLabel.text=@"";owner.statusLabel.hidden=YES;
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.correlationID?:@"",@"request_generation":@(generation),@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":error.localizedDescription?:@""}];owner.statusLabel.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];owner.statusLabel.hidden=NO;return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.correlationID?:@"",@"request_generation":@(generation)}];NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"seasonIndex":@(owner.selectedSeasonIndex),@"lineIndex":@(capturedLineIndex),@"episodeIndex":@(capturedEpisodeIndex),@"parserID":parserID,@"correlationID":owner.correlationID?:@""};
        if(owner.onSelectEpisode)owner.onSelectEpisode(result,context);if(owner.selectionUpdatesPlayer&&owner.navigationController.topViewController==owner)[owner.navigationController popViewControllerAnimated:YES];
    }];
}
- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    if(!self.isViewLoaded)return;
    self.view.backgroundColor=MediaSelectionBackground();
    self.backdropGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:.22].CGColor,(id)[UIColor colorWithWhite:0 alpha:.78].CGColor,(id)MediaSelectionBackground().CGColor];
    self.continueButton.backgroundColor=HostAccent();
    [self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];
    [self rebuildSelection];
}
@end
