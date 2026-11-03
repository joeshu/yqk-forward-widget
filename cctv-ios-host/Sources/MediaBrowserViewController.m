#import "MediaBrowserViewController.h"
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

static NSDictionary *MediaBrowserSanitizedDetail(id rawDetail, NSUInteger *discardedLines, NSUInteger *discardedEpisodes) {
    if(discardedLines)*discardedLines=0;if(discardedEpisodes)*discardedEpisodes=0;
    if(![rawDetail isKindOfClass:NSDictionary.class])return nil;
    NSMutableDictionary *detail=[rawDetail mutableCopy];NSUInteger droppedLines=0,droppedEpisodes=0;
    NSArray *rawLines=[detail[@"lines"] isKindOfClass:NSArray.class]?detail[@"lines"]:@[];NSMutableArray *lines=[NSMutableArray arrayWithCapacity:rawLines.count];
    for(id rawLine in rawLines){
        if(![rawLine isKindOfClass:NSDictionary.class]){droppedLines++;continue;}
        NSMutableDictionary *line=[rawLine mutableCopy];NSUInteger dropped=0;line[@"episodes"]=MediaBrowserDictionaryRows(line[@"episodes"],&dropped);droppedEpisodes+=dropped;[lines addObject:line];
    }
    detail[@"lines"]=lines;if(discardedLines)*discardedLines=droppedLines;if(discardedEpisodes)*discardedEpisodes=droppedEpisodes;
    return detail;
}

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

@interface MediaHomeCarouselView : UIControl
@property(nonatomic,copy) NSArray<NSDictionary *> *items;
@property(nonatomic,copy) void (^onSelectItem)(NSDictionary *item);
@property(nonatomic,strong) UIImageView *imageView;
@property(nonatomic,strong) UILabel *eyebrowLabel;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UIPageControl *pageControl;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) NSUInteger currentIndex;
- (void)configureWithItems:(NSArray<NSDictionary *> *)items;
@end

@implementation MediaHomeCarouselView
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.translatesAutoresizingMaskIntoConstraints=NO;
        self.clipsToBounds=YES;
        self.layer.cornerRadius=18;
        self.layer.cornerCurve=kCACornerCurveContinuous;
        self.backgroundColor=HostNeutralSurface();
        self.accessibilityIdentifier=@"media-home-banner";
        self.accessibilityTraits|=UIAccessibilityTraitButton;
        self.imageView=[UIImageView new];self.imageView.translatesAutoresizingMaskIntoConstraints=NO;self.imageView.contentMode=UIViewContentModeScaleAspectFill;self.imageView.clipsToBounds=YES;self.imageView.backgroundColor=HostNeutralSurface();[self addSubview:self.imageView];
        MediaHomePosterFade *fade=[MediaHomePosterFade new];fade.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:fade];
        self.eyebrowLabel=[UILabel new];self.eyebrowLabel.translatesAutoresizingMaskIntoConstraints=NO;self.eyebrowLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];self.eyebrowLabel.textColor=[UIColor.whiteColor colorWithAlphaComponent:.78];self.eyebrowLabel.numberOfLines=1;[self addSubview:self.eyebrowLabel];
        self.titleLabel=[UILabel new];self.titleLabel.translatesAutoresizingMaskIntoConstraints=NO;self.titleLabel.font=[UIFont systemFontOfSize:24 weight:UIFontWeightBold];self.titleLabel.adjustsFontForContentSizeCategory=YES;self.titleLabel.textColor=UIColor.whiteColor;self.titleLabel.numberOfLines=2;[self addSubview:self.titleLabel];
        self.detailLabel=[UILabel new];self.detailLabel.translatesAutoresizingMaskIntoConstraints=NO;self.detailLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];self.detailLabel.adjustsFontForContentSizeCategory=YES;self.detailLabel.textColor=[UIColor.whiteColor colorWithAlphaComponent:.84];self.detailLabel.numberOfLines=1;self.detailLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self addSubview:self.detailLabel];
        self.pageControl=[UIPageControl new];self.pageControl.translatesAutoresizingMaskIntoConstraints=NO;self.pageControl.currentPageIndicatorTintColor=HostAccent();self.pageControl.pageIndicatorTintColor=[UIColor.whiteColor colorWithAlphaComponent:.40];self.pageControl.hidesForSinglePage=YES;self.pageControl.accessibilityLabel=@"首页轮播页码";[self.pageControl addTarget:self action:@selector(pageControlChanged) forControlEvents:UIControlEventValueChanged];[self addSubview:self.pageControl];
        [NSLayoutConstraint activateConstraints:@[
            [self.imageView.topAnchor constraintEqualToAnchor:self.topAnchor],[self.imageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[self.imageView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[self.imageView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [fade.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[fade.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[fade.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],[fade.heightAnchor constraintGreaterThanOrEqualToConstant:130],
            [self.eyebrowLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],[self.eyebrowLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],[self.eyebrowLabel.bottomAnchor constraintEqualToAnchor:self.titleLabel.topAnchor constant:-5],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],[self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],[self.titleLabel.bottomAnchor constraintEqualToAnchor:self.detailLabel.topAnchor constant:-5],
            [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],[self.detailLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],[self.detailLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-27],
            [self.pageControl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-9],[self.pageControl.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-1],[self.pageControl.heightAnchor constraintEqualToConstant:20]
        ]];
        [self addTarget:self action:@selector(didSelectCurrentItem) forControlEvents:UIControlEventTouchUpInside];
        UISwipeGestureRecognizer *left=[[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(nextPage)];left.direction=UISwipeGestureRecognizerDirectionLeft;[self addGestureRecognizer:left];
        UISwipeGestureRecognizer *right=[[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(previousPage)];right.direction=UISwipeGestureRecognizerDirectionRight;[self addGestureRecognizer:right];
    }
    return self;
}
- (void)dealloc {[self.timer invalidate];}
- (void)configureWithItems:(NSArray<NSDictionary *> *)items {
    self.items=[items isKindOfClass:NSArray.class]?items:@[];self.currentIndex=0;self.pageControl.numberOfPages=self.items.count;self.pageControl.currentPage=0;[self applyCurrentItemAnimated:NO];[self.timer invalidate];self.timer=nil;
    if(self.items.count>1){__weak typeof(self) weakSelf=self;self.timer=[NSTimer timerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer){MediaHomeCarouselView *owner=weakSelf;if(owner.window&&owner.items.count>1)[owner nextPage];}];[[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];}
}
- (void)pageControlChanged {if(!self.items.count)return;self.currentIndex=(NSUInteger)MAX(0,MIN(self.pageControl.currentPage,(NSInteger)self.items.count-1));[self applyCurrentItemAnimated:YES];}
- (void)nextPage {if(self.items.count<2)return;self.currentIndex=(self.currentIndex+1)%self.items.count;[self applyCurrentItemAnimated:YES];}
- (void)previousPage {if(self.items.count<2)return;self.currentIndex=(self.currentIndex+self.items.count-1)%self.items.count;[self applyCurrentItemAnimated:YES];}
- (void)applyCurrentItemAnimated:(BOOL)animated {
    NSDictionary *item=self.items.count?self.items[MIN(self.currentIndex,self.items.count-1)]:@{};
    NSString *poster=[item[@"banner"] isKindOfClass:NSString.class]?item[@"banner"]:([item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"");
    void (^updateLabels)(void)=^{
        self.eyebrowLabel.text=@"热门推荐";
        if(self.items.count){NSMutableArray *metadata=[NSMutableArray array];for(NSString *key in @[@"year",@"area",@"type"]){id value=item[key];if([value isKindOfClass:NSString.class]&&[value length])[metadata addObject:value];}if(metadata.count)self.eyebrowLabel.text=[metadata componentsJoinedByString:@" · "];}
        self.titleLabel.text=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"影视精选";
        self.detailLabel.text=[item[@"remarks"] isKindOfClass:NSString.class]&&[item[@"remarks"] length]?item[@"remarks"]:(self.items.count?@"点按查看影片详情":@"选择资源后加载首页内容");
        self.pageControl.numberOfPages=self.items.count;self.pageControl.currentPage=(NSInteger)self.currentIndex;
        self.accessibilityLabel=[NSString stringWithFormat:@"%@，%@%@",self.titleLabel.text,self.detailLabel.text,self.items.count?[NSString stringWithFormat:@"，第 %lu 页，共 %lu 页",(unsigned long)self.currentIndex+1,(unsigned long)self.items.count]:@""];
    };
    if(animated)[UIView transitionWithView:self duration:0.22 options:UIViewAnimationOptionTransitionCrossDissolve|UIViewAnimationOptionAllowAnimatedContent animations:updateLabels completion:nil];else updateLabels();
    if(animated){self.imageView.transform=CGAffineTransformMakeScale(1.055,1.055);[UIView animateWithDuration:3.0 delay:0 options:UIViewAnimationOptionCurveEaseOut|UIViewAnimationOptionBeginFromCurrentState animations:^{self.imageView.transform=CGAffineTransformIdentity;} completion:nil];}else self.imageView.transform=CGAffineTransformIdentity;
    self.imageView.accessibilityIdentifier=poster;
    if(poster.length){self.imageView.contentMode=UIViewContentModeScaleAspectFill;MediaLoadPosterWithRetry(poster,self.imageView,1);}else{self.imageView.image=[UIImage systemImageNamed:@"film"];self.imageView.contentMode=UIViewContentModeScaleAspectFit;}
}
- (void)didSelectCurrentItem {if(!self.items.count)return;NSDictionary *item=self.items[MIN(self.currentIndex,self.items.count-1)];if(self.onSelectItem)self.onSelectItem(item);}
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
        HostStyleGlassCard(self.contentView,15);
        self.posterView=[UIImageView new];self.posterView.backgroundColor=HostNeutralSurface();self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;[self.contentView addSubview:self.posterView];
        self.posterView.layer.cornerRadius=12;self.posterView.layer.cornerCurve=kCACornerCurveContinuous;
        self.nameLabel=[UILabel new];self.nameLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]];self.nameLabel.adjustsFontForContentSizeCategory=YES;self.nameLabel.textColor=HostText();self.nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.nameLabel];
        self.nameLabel.numberOfLines=2;
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
    if(poster.length)MediaLoadPosterWithRetry(poster,self.posterView,1);else{self.posterView.image=[UIImage systemImageNamed:@"film"];self.posterView.contentMode=UIViewContentModeCenter;self.posterView.tintColor=HostSecondaryText();self.posterView.accessibilityIdentifier=nil;}
    self.nameLabel.text=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"";
    self.remarksLabel.text=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"";
    self.accessibilityLabel=[NSString stringWithFormat:@"%@，%@",self.nameLabel.text,self.remarksLabel.text];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width=CGRectGetWidth(self.contentView.bounds),posterHeight=width*1.43;
    CGFloat nameHeight=ceil(self.nameLabel.font.lineHeight)*2,remarksHeight=ceil(self.remarksLabel.font.lineHeight);
    self.posterView.frame=CGRectMake(0,0,width,posterHeight);
    self.nameLabel.frame=CGRectMake(7,posterHeight+7,MAX(0,width-14),nameHeight);
    self.remarksLabel.frame=CGRectMake(7,CGRectGetMaxY(self.nameLabel.frame)+1,MAX(0,width-14),remarksHeight);
}
@end

@interface MediaDiscoveryCell : UICollectionViewCell
@property(nonatomic,strong) UIImageView *posterView;
@property(nonatomic,strong) MediaHomePosterFade *posterFade;
@property(nonatomic,strong) UILabel *posterStatusLabel;
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *kindLabel;
@property(nonatomic,copy) NSString *posterURL;
@property(nonatomic) BOOL posterLoaded;
@property(nonatomic) NSUInteger posterGeneration;
@property(nonatomic) NSUInteger posterRetryCount;
- (void)configureWithItem:(NSDictionary *)item;
- (void)loadPosterIfNeeded;
@end

@implementation MediaDiscoveryCell
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.contentView.backgroundColor=UIColor.clearColor;
        self.posterView=[UIImageView new];self.posterView.contentMode=UIViewContentModeScaleAspectFill;self.posterView.clipsToBounds=YES;self.posterView.backgroundColor=HostNeutralSurface();self.posterView.layer.cornerRadius=15;self.posterView.layer.cornerCurve=kCACornerCurveContinuous;[self.contentView addSubview:self.posterView];
        self.posterFade=[MediaHomePosterFade new];self.posterFade.userInteractionEnabled=NO;[self.posterView addSubview:self.posterFade];
        self.posterStatusLabel=[UILabel new];self.posterStatusLabel.font=[UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];self.posterStatusLabel.adjustsFontForContentSizeCategory=YES;self.posterStatusLabel.textColor=UIColor.whiteColor;self.posterStatusLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.posterStatusLabel.numberOfLines=1;self.posterStatusLabel.layer.shadowColor=UIColor.blackColor.CGColor;self.posterStatusLabel.layer.shadowOpacity=.85;self.posterStatusLabel.layer.shadowRadius=2;self.posterStatusLabel.layer.shadowOffset=CGSizeMake(0,1);[self.posterView addSubview:self.posterStatusLabel];
        self.nameLabel=[UILabel new];self.nameLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];self.nameLabel.adjustsFontForContentSizeCategory=YES;self.nameLabel.textColor=HostText();self.nameLabel.numberOfLines=2;self.nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.nameLabel];
        self.kindLabel=[UILabel new];self.kindLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightRegular];self.kindLabel.adjustsFontForContentSizeCategory=YES;self.kindLabel.textColor=HostSecondaryText();self.kindLabel.numberOfLines=1;self.kindLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.kindLabel];
        self.isAccessibilityElement=NO;self.posterView.isAccessibilityElement=YES;self.posterView.accessibilityTraits=UIAccessibilityTraitButton;
    }
    return self;
}
- (void)prepareForReuse {[super prepareForReuse];self.posterGeneration++;self.posterRetryCount=0;self.posterURL=@"";self.posterLoaded=NO;self.posterView.image=nil;self.posterView.accessibilityIdentifier=nil;self.posterView.accessibilityLabel=nil;self.posterStatusLabel.text=@"";self.nameLabel.text=@"";self.kindLabel.text=@"";}
- (void)configureWithItem:(NSDictionary *)item {
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";self.posterURL=poster;self.posterGeneration++;self.posterRetryCount=0;self.posterLoaded=NO;self.posterView.image=[UIImage systemImageNamed:@"film"];self.posterView.contentMode=UIViewContentModeCenter;self.posterView.tintColor=HostSecondaryText();self.posterView.accessibilityIdentifier=poster.length?poster:nil;
    self.nameLabel.text=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"影视内容";
    NSString *kind=[item[@"type"] isKindOfClass:NSString.class]?item[@"type"]:([item[@"type_name"] isKindOfClass:NSString.class]?item[@"type_name"]:([item[@"class"] isKindOfClass:NSString.class]?item[@"class"]:@"短剧"));self.kindLabel.text=kind.length?kind:@"短剧";
    NSString *status=[item[@"__homePosterStatus"] isKindOfClass:NSString.class]?item[@"__homePosterStatus"]:([item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:([item[@"episode"] isKindOfClass:NSString.class]?item[@"episode"]:@""));self.posterStatusLabel.text=status.length?status:@"点按播放";
    NSString *accessibleTitle=[NSString stringWithFormat:@"%@，%@，%@",self.nameLabel.text,self.kindLabel.text,self.posterStatusLabel.text];self.posterView.accessibilityLabel=accessibleTitle;self.posterView.accessibilityHint=@"打开影片详情并选择播放线路";
}
- (void)loadPosterIfNeeded {
    if(self.posterLoaded||!self.posterURL.length)return;
    self.posterLoaded=YES;self.posterView.contentMode=UIViewContentModeScaleAspectFill;NSUInteger generation=self.posterGeneration;NSString *url=self.posterURL;__weak typeof(self) weakSelf=self;
    [HostImageLoader.shared loadPosterURL:url intoImageView:self.posterView completion:^(BOOL succeeded,NSTimeInterval retryAfter){
        MediaDiscoveryCell *cell=weakSelf;if(!cell||cell.posterGeneration!=generation||![cell.posterURL isEqualToString:url])return;
        if(succeeded){cell.posterLoaded=YES;cell.posterRetryCount=0;return;}
        cell.posterLoaded=NO;if(cell.posterRetryCount>0||retryAfter<=0)return;cell.posterRetryCount++;
        NSTimeInterval delay=MIN(120.0,MAX(1.0,retryAfter+0.25));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            MediaDiscoveryCell *current=weakSelf;if(!current||current.posterGeneration!=generation||![current.posterURL isEqualToString:url])return;
            if(!current.window){current.posterRetryCount=0;return;}
            current.posterLoaded=NO;[current loadPosterIfNeeded];
        });
    }];
}
- (void)layoutSubviews {
    [super layoutSubviews];CGFloat width=CGRectGetWidth(self.contentView.bounds),posterHeight=floor(width*1.5);self.posterView.frame=CGRectMake(0,0,width,posterHeight);self.posterFade.frame=CGRectMake(0,MAX(0,posterHeight-50),width,50);self.posterStatusLabel.frame=CGRectMake(8,posterHeight-23,MAX(0,width-16),16);self.nameLabel.frame=CGRectMake(2,posterHeight+7,MAX(0,width-4),ceil(self.nameLabel.font.lineHeight)*2);self.kindLabel.frame=CGRectMake(2,CGRectGetMaxY(self.nameLabel.frame)+2,MAX(0,width-4),ceil(self.kindLabel.font.lineHeight));
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
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.title=self.screenTitle?:@"影视资源";self.shown=self.choices?:@[];self.selectedScope=@"*";self.tableView.backgroundColor=HostBackground();self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;self.tableView.tableFooterView=[UIView new];
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
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"source"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"source"];NSDictionary *choice=self.shown[index.row];cell.backgroundColor=HostCard();cell.textLabel.text=choice[@"name"];cell.textLabel.textColor=HostText();cell.textLabel.numberOfLines=0;NSMutableArray *details=[NSMutableArray array];if([choice[@"subtitle"] length])[details addObject:choice[@"subtitle"]];if([choice[@"url"] length])[details addObject:choice[@"url"]];cell.detailTextLabel.text=[details componentsJoinedByString:@"\n"];cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=0;cell.tintColor=HostAccent();BOOL selected=[choice[@"selected"] boolValue];cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryDisclosureIndicator;return cell;}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {NSString *query=controller.searchBar.text?:@"";self.shown=[self.choices filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *choice,NSDictionary *bindings){NSString *scope=[choice[@"scope"] isKindOfClass:NSString.class]?choice[@"scope"]:@"";if(![self.selectedScope isEqual:@"*"]&&![scope isEqual:self.selectedScope])return NO;BOOL matches=![query length];for(NSString *key in @[@"name",@"subtitle",@"url"]){NSString *value=[choice[key] isKindOfClass:NSString.class]?choice[key]:@"";if(query.length&&[value rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location!=NSNotFound)matches=YES;}return matches;}]];if(!self.shown.count){UILabel *empty=[UILabel new];empty.text=query.length?@"没有匹配的选项，请修改或清除搜索词":@"当前分组暂无选项，请切换到全部";empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];empty.adjustsFontForContentSizeCategory=YES;empty.textColor=HostSecondaryText();empty.accessibilityIdentifier=@"media-picker-empty";self.tableView.backgroundView=empty;}else self.tableView.backgroundView=nil;[self.tableView reloadData];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {NSDictionary *choice=self.shown[index.row];void(^onSelect)(NSDictionary *)=self.onSelect;[self.navigationController dismissViewControllerAnimated:YES completion:^{if(onSelect)onSelect(choice);}];}
@end


@interface MediaDetailViewController : UIViewController <UIScrollViewDelegate>
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
@property(nonatomic,strong) UIView *stickyPlayBar;
@property(nonatomic) BOOL episodeOrderReversed;
@property(nonatomic,strong) MediaPlaybackViewController *inlinePlaybackController;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic) NSInteger selectedLineIndex;
@property(nonatomic) NSInteger selectedEpisodeIndex;
@property(nonatomic) NSInteger episodePage;
@property(nonatomic) BOOL descriptionExpanded;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,copy) NSString *diagnosticTraceID;
- (void)loadDetail;
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
- (void)updateInlinePlaybackFloatingPosition;
- (NSString *)posterURL;
- (void)restoreSelectionFromDetail:(NSDictionary *)previousDetail;
- (void)showInlinePlaybackResult:(NSDictionary *)result context:(NSDictionary *)context;
@end
@implementation MediaDetailViewController
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskPortrait;}
- (instancetype)init {return [super initWithNibName:nil bundle:nil];}
- (NSArray *)lines {return [self.detail[@"lines"] isKindOfClass:NSArray.class]?self.detail[@"lines"]:@[];}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationBar *bar=self.navigationController.navigationBar;
    if(!bar)return;
    NSDictionary *titleAttributes=@{NSForegroundColorAttributeName:UIColor.whiteColor,NSFontAttributeName:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    UINavigationBarAppearance *scrolled=[UINavigationBarAppearance new];[scrolled configureWithDefaultBackground];scrolled.backgroundEffect=HostGlassBlur();scrolled.backgroundColor=HostGlassTint();scrolled.titleTextAttributes=titleAttributes;scrolled.largeTitleTextAttributes=titleAttributes;scrolled.shadowColor=UIColor.clearColor;
    UINavigationBarAppearance *edge=[UINavigationBarAppearance new];[edge configureWithTransparentBackground];edge.titleTextAttributes=titleAttributes;edge.largeTitleTextAttributes=titleAttributes;edge.backgroundColor=[UIColor colorWithWhite:0 alpha:0.12];edge.shadowColor=UIColor.clearColor;
    bar.standardAppearance=scrolled;bar.scrollEdgeAppearance=edge;bar.compactAppearance=scrolled;if(@available(iOS 15.0,*))bar.compactScrollEdgeAppearance=edge;bar.translucent=YES;bar.tintColor=HostAccent();bar.prefersLargeTitles=NO;
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if(!self.isMovingFromParentViewController)return;
    UINavigationController *navigation=self.navigationController;id<UIViewControllerTransitionCoordinator> transition=self.transitionCoordinator;
    if(transition)[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){if(!context.isCancelled)HostStyleNavigation(navigation);}];
    else HostStyleNavigation(navigation);
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.title=@"";self.view.backgroundColor=HostBackground();self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.selectedLineIndex=0;self.selectedEpisodeIndex=0;self.episodePage=0;self.episodeButtons=[NSMutableArray array];self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;
    UIButton *back=[UIButton buttonWithType:UIButtonTypeSystem];back.frame=CGRectMake(0,0,44,44);[back setTitle:@"‹" forState:UIControlStateNormal];back.titleLabel.font=[UIFont systemFontOfSize:32 weight:UIFontWeightMedium];back.titleLabel.adjustsFontForContentSizeCategory=NO;back.titleEdgeInsets=UIEdgeInsetsMake(-3,0,0,0);back.tintColor=HostAccent();HostStyleGlassCard(back,14);HostInstallPressFeedback(back);back.accessibilityLabel=@"返回";back.accessibilityIdentifier=@"media-detail-back";[back addTarget:self action:@selector(goBack) forControlEvents:UIControlEventTouchUpInside];self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:back];
    __weak typeof(self) weakSelf=self;self.navigationItem.rightBarButtonItems=@[HostToolbar(@[@{@"icon":@"ellipsis",@"title":@"更多影片操作",@"menu":[UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"返回影视首页" image:[UIImage systemImageNamed:@"house"] identifier:nil handler:^(UIAction *action){if(weakSelf.onReturnHome)weakSelf.onReturnHome();}],[UIAction actionWithTitle:@"重新加载详情" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action){[weakSelf loadDetail];}],[UIAction actionWithTitle:@"复制片名" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action){[weakSelf copyTitle];}],[UIAction actionWithTitle:@"分享影片信息" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action){[weakSelf shareTitle];}]]]}])];
    NSString *catalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");self.client=MediaSourceUsesNativeCatalogAPI(self.source)?[[MediaAPIClient alloc] initWithTVBoxSource:self.source]:[[MediaAPIClient alloc] initWithPort:[self.source[@"port"] integerValue] catalogID:catalogID];[self buildDetailLayout];[self loadDetail];
}
- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label=[UILabel new];label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];label.adjustsFontForContentSizeCategory=YES;label.textColor=HostText();label.text=text;return label;
}
- (UIButton *)actionButton:(NSString *)title identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;
    button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;
    HostStylePillButton(button,YES);button.layer.cornerRadius=17;button.contentEdgeInsets=UIEdgeInsetsMake(11,16,11,16);
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];[button setTitle:title forState:UIControlStateNormal];return button;
}
- (UIButton *)detailActionButton:(NSString *)title symbol:(NSString *)symbol label:(NSString *)label identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;button.accessibilityLabel=label;button.accessibilityTraits|=UIAccessibilityTraitButton;
    HostStylePillButton(button,NO);HostStyleGlassCard(button,14);HostInstallPressFeedback(button);button.layer.borderWidth=0.6;HostSetLayerBorderColor(button,HostBorder());
    UIImageSymbolConfiguration *symbolConfig=[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];UIImage *image=[UIImage systemImageNamed:symbol withConfiguration:symbolConfig];if(image)[button setImage:image forState:UIControlStateNormal];[button setTitle:title forState:UIControlStateNormal];button.tintColor=HostAccent();button.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.82;button.contentEdgeInsets=UIEdgeInsetsMake(8,7,8,7);button.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,4);button.imageView.contentMode=UIViewContentModeScaleAspectFit;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:40].active=YES;[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)buildDetailLayout {
    self.scrollView=[UIScrollView new];self.scrollView.translatesAutoresizingMaskIntoConstraints=NO;self.scrollView.alwaysBounceVertical=YES;self.scrollView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.scrollView.accessibilityIdentifier=@"media-detail-scroll";self.scrollView.delegate=self;[self.view addSubview:self.scrollView];
    self.contentStack=[UIStackView new];self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=9;
    self.contentStack.layoutMargins=UIEdgeInsetsMake(0,14,20,14);self.contentStack.layoutMarginsRelativeArrangement=YES;[self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[[self.scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
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
    self.heroBlurView=[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];self.heroBlurView.translatesAutoresizingMaskIntoConstraints=NO;self.heroBlurView.userInteractionEnabled=NO;self.heroBlurView.hidden=YES;[hero addSubview:self.heroBlurView];
    UIView *shade=[UIView new];shade.translatesAutoresizingMaskIntoConstraints=NO;shade.backgroundColor=UIColor.clearColor;shade.userInteractionEnabled=NO;[hero addSubview:shade];
    self.heroGradient=[CAGradientLayer layer];self.heroGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:0.78].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.68].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.16].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.10].CGColor,(id)[UIColor colorWithWhite:0 alpha:0.82].CGColor];self.heroGradient.locations=@[@0.0,@0.18,@0.46,@0.66,@1.0];self.heroGradient.startPoint=CGPointMake(0.5,0);self.heroGradient.endPoint=CGPointMake(0.5,1);[hero.layer addSublayer:self.heroGradient];
    self.posterThumbnailView=[UIImageView new];self.posterThumbnailView.translatesAutoresizingMaskIntoConstraints=NO;self.posterThumbnailView.contentMode=UIViewContentModeScaleAspectFill;self.posterThumbnailView.clipsToBounds=YES;self.posterThumbnailView.layer.cornerRadius=10;self.posterThumbnailView.layer.cornerCurve=kCACornerCurveContinuous;self.posterThumbnailView.backgroundColor=HostNeutralSurface();self.posterThumbnailView.hidden=YES;self.posterThumbnailView.isAccessibilityElement=NO;[hero addSubview:self.posterThumbnailView];
    self.heroTitle=[UILabel new];self.heroTitle.translatesAutoresizingMaskIntoConstraints=NO;self.heroTitle.font=[UIFont systemFontOfSize:21 weight:UIFontWeightBold];self.heroTitle.adjustsFontForContentSizeCategory=YES;self.heroTitle.textColor=UIColor.whiteColor;self.heroTitle.numberOfLines=2;
    self.heroMetadata=[UILabel new];self.heroMetadata.translatesAutoresizingMaskIntoConstraints=NO;self.heroMetadata.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.heroMetadata.adjustsFontForContentSizeCategory=YES;self.heroMetadata.textColor=[UIColor.whiteColor colorWithAlphaComponent:0.85];self.heroMetadata.numberOfLines=1;self.heroMetadata.lineBreakMode=NSLineBreakByTruncatingTail;
    [hero addSubview:self.status];[hero addSubview:self.heroTitle];[hero addSubview:self.heroMetadata];[self.scrollView insertSubview:hero belowSubview:self.contentStack];self.heroSpacer=[UIView new];self.heroSpacer.translatesAutoresizingMaskIntoConstraints=NO;self.heroSpacer.isAccessibilityElement=NO;[self.contentStack addArrangedSubview:self.heroSpacer];
    [NSLayoutConstraint activateConstraints:@[[hero.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor],[hero.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor],[hero.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor],[hero.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.62],[self.heroSpacer.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.62],
        [self.posterPlaceholder.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.posterPlaceholder.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.posterPlaceholder.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.posterPlaceholder.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [placeholderIcon.centerXAnchor constraintEqualToAnchor:self.posterPlaceholder.centerXAnchor],[placeholderIcon.centerYAnchor constraintEqualToAnchor:self.posterPlaceholder.centerYAnchor],[placeholderIcon.widthAnchor constraintEqualToConstant:42],[placeholderIcon.heightAnchor constraintEqualToConstant:42],
        [self.posterView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.posterView.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.posterView.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.posterView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [self.heroBlurView.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[self.heroBlurView.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[self.heroBlurView.topAnchor constraintEqualToAnchor:hero.topAnchor],[self.heroBlurView.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
        [shade.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor],[shade.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor],[shade.topAnchor constraintEqualToAnchor:hero.topAnchor],[shade.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
    [self.status.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],[self.status.centerYAnchor constraintEqualToAnchor:hero.centerYAnchor],[self.status.leadingAnchor constraintGreaterThanOrEqualToAnchor:hero.leadingAnchor constant:24],[self.status.trailingAnchor constraintLessThanOrEqualToAnchor:hero.trailingAnchor constant:-24],[self.status.widthAnchor constraintLessThanOrEqualToAnchor:hero.widthAnchor constant:-48],
        [self.heroTitle.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:18],[self.heroTitle.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-18],[self.heroTitle.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor constant:-53],
        [self.heroMetadata.leadingAnchor constraintEqualToAnchor:self.heroTitle.leadingAnchor],[self.heroMetadata.trailingAnchor constraintEqualToAnchor:self.heroTitle.trailingAnchor],
        [self.heroMetadata.topAnchor constraintEqualToAnchor:self.heroTitle.bottomAnchor constant:7],[self.heroMetadata.bottomAnchor constraintLessThanOrEqualToAnchor:hero.bottomAnchor constant:-20]]];
    UIView *infoCard=[UIView new];infoCard.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(infoCard,17);
    UIStackView *infoStack=[UIStackView new];infoStack.translatesAutoresizingMaskIntoConstraints=NO;infoStack.axis=UILayoutConstraintAxisVertical;infoStack.spacing=4;infoStack.layoutMargins=UIEdgeInsetsMake(10,12,10,12);infoStack.layoutMarginsRelativeArrangement=YES;[infoCard addSubview:infoStack];
    [NSLayoutConstraint activateConstraints:@[[infoStack.leadingAnchor constraintEqualToAnchor:infoCard.leadingAnchor],[infoStack.trailingAnchor constraintEqualToAnchor:infoCard.trailingAnchor],[infoStack.topAnchor constraintEqualToAnchor:infoCard.topAnchor],[infoStack.bottomAnchor constraintEqualToAnchor:infoCard.bottomAnchor]]];
    self.metadataLabel=[UILabel new];self.metadataLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.metadataLabel.adjustsFontForContentSizeCategory=YES;self.metadataLabel.textColor=HostSecondaryText();self.metadataLabel.numberOfLines=2;[infoStack addArrangedSubview:self.metadataLabel];
    self.descriptionLabel=[UILabel new];self.descriptionLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.descriptionLabel.adjustsFontForContentSizeCategory=YES;self.descriptionLabel.textColor=HostSecondaryText();self.descriptionLabel.numberOfLines=3;[infoStack addArrangedSubview:self.descriptionLabel];
    self.descriptionToggle=[UIButton buttonWithType:UIButtonTypeSystem];self.descriptionToggle.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;[self.descriptionToggle setTitle:@"展开简介" forState:UIControlStateNormal];[self.descriptionToggle setTitleColor:HostAccent() forState:UIControlStateNormal];self.descriptionToggle.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.descriptionToggle.titleLabel.adjustsFontForContentSizeCategory=YES;[self.descriptionToggle addTarget:self action:@selector(toggleDescription) forControlEvents:UIControlEventTouchUpInside];self.descriptionToggle.hidden=YES;[infoStack addArrangedSubview:self.descriptionToggle];
    [self.contentStack addArrangedSubview:infoCard];
    self.playButton=[self actionButton:@"▶︎  播放" identifier:@"media-detail-play" action:@selector(playCurrentEpisode)];self.playButton.accessibilityHint=@"播放当前线路和分集；上次播放过时会继续上次进度";[self.playButton.heightAnchor constraintGreaterThanOrEqualToConstant:50].active=YES;
    self.stickyPlayBar=[UIView new];self.stickyPlayBar.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(self.stickyPlayBar,18);[self.view addSubview:self.stickyPlayBar];[self.stickyPlayBar addSubview:self.playButton];
    [NSLayoutConstraint activateConstraints:@[[self.playButton.leadingAnchor constraintEqualToAnchor:self.stickyPlayBar.leadingAnchor constant:10],[self.playButton.trailingAnchor constraintEqualToAnchor:self.stickyPlayBar.trailingAnchor constant:-10],[self.playButton.topAnchor constraintEqualToAnchor:self.stickyPlayBar.topAnchor constant:8],[self.playButton.bottomAnchor constraintEqualToAnchor:self.stickyPlayBar.bottomAnchor constant:-8],[self.stickyPlayBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:14],[self.stickyPlayBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14],[self.stickyPlayBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6],[self.stickyPlayBar.heightAnchor constraintGreaterThanOrEqualToConstant:66],[self.scrollView.bottomAnchor constraintEqualToAnchor:self.stickyPlayBar.topAnchor constant:-8]]];
    UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisHorizontal;actions.alignment=UIStackViewAlignmentFill;actions.distribution=UIStackViewDistributionFillEqually;actions.spacing=6;actions.layoutMargins=UIEdgeInsetsMake(0,2,0,2);actions.layoutMarginsRelativeArrangement=YES;
    UIButton *copyButton=[self detailActionButton:@"复制" symbol:@"doc.on.doc" label:@"复制片名" identifier:@"media-detail-copy-title" action:@selector(copyTitle)];UIButton *shareButton=[self detailActionButton:@"分享" symbol:@"square.and.arrow.up" label:@"分享影片信息" identifier:@"media-detail-share" action:@selector(shareTitle)];self.favoriteButton=[self detailActionButton:@"收藏" symbol:@"heart" label:@"收藏影片" identifier:@"media-detail-favorite" action:@selector(toggleFavorite)];UIButton *episodesButton=[self detailActionButton:@"选集" symbol:@"list.number" label:@"查看选集" identifier:@"media-detail-jump-episodes" action:@selector(scrollToEpisodes)];
    [actions addArrangedSubview:copyButton];[actions addArrangedSubview:shareButton];[actions addArrangedSubview:self.favoriteButton];[actions addArrangedSubview:episodesButton];[self.contentStack addArrangedSubview:actions];
    UIView *sourceCard=[UIView new];sourceCard.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(sourceCard,17);
    UIStackView *sourceStack=[UIStackView new];sourceStack.translatesAutoresizingMaskIntoConstraints=NO;sourceStack.axis=UILayoutConstraintAxisVertical;sourceStack.spacing=7;sourceStack.layoutMargins=UIEdgeInsetsMake(11,11,11,11);sourceStack.layoutMarginsRelativeArrangement=YES;[sourceCard addSubview:sourceStack];
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
    self.parserButton=[UIButton buttonWithType:UIButtonTypeSystem];self.parserButton.accessibilityIdentifier=@"media-detail-parser-selector";self.parserButton.accessibilityLabel=@"选择解析接口";self.parserButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.parserButton.titleLabel.adjustsFontForContentSizeCategory=YES;HostStylePillButton(self.parserButton,NO);self.parserButton.contentEdgeInsets=UIEdgeInsetsMake(8,13,8,13);[self.parserButton addTarget:self action:@selector(selectParser) forControlEvents:UIControlEventTouchUpInside];[self.parserRow addArrangedSubview:self.parserButton];[sourceStack addArrangedSubview:self.parserRow];
    self.episodeTitle=[self sectionLabel:@"选集"];[sourceStack addArrangedSubview:self.episodeTitle];
    UIStackView *paging=[UIStackView new];paging.axis=UILayoutConstraintAxisHorizontal;paging.alignment=UIStackViewAlignmentCenter;paging.spacing=6;self.pageLabel=[UILabel new];self.pageLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.pageLabel.adjustsFontForContentSizeCategory=YES;self.pageLabel.textColor=HostSecondaryText();self.pageLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.pageLabel.accessibilityIdentifier=@"media-detail-page-status";[self.pageLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[self.pageLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[paging addArrangedSubview:self.pageLabel];
    self.previousPageButton=[UIButton buttonWithType:UIButtonTypeSystem];self.nextPageButton=[UIButton buttonWithType:UIButtonTypeSystem];self.episodeReverseButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.previousPageButton setImage:[UIImage systemImageNamed:@"chevron.left"] forState:UIControlStateNormal];[self.nextPageButton setImage:[UIImage systemImageNamed:@"chevron.right"] forState:UIControlStateNormal];self.previousPageButton.accessibilityLabel=@"上一页";self.nextPageButton.accessibilityLabel=@"下一页";HostStylePillButton(self.previousPageButton,NO);HostStylePillButton(self.nextPageButton,NO);self.previousPageButton.contentEdgeInsets=UIEdgeInsetsMake(4,9,4,9);self.nextPageButton.contentEdgeInsets=UIEdgeInsetsMake(4,9,4,9);self.previousPageButton.tintColor=HostText();self.nextPageButton.tintColor=HostText();
    [self.previousPageButton addTarget:self action:@selector(previousEpisodePage) forControlEvents:UIControlEventTouchUpInside];[self.nextPageButton addTarget:self action:@selector(nextEpisodePage) forControlEvents:UIControlEventTouchUpInside];
    self.episodeReverseButton.accessibilityLabel=@"切换选集正序或倒序";[self.episodeReverseButton setTitle:@"正序" forState:UIControlStateNormal];self.episodeReverseButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];HostStylePillButton(self.episodeReverseButton,NO);[self.episodeReverseButton addTarget:self action:@selector(toggleEpisodeOrder) forControlEvents:UIControlEventTouchUpInside];[paging addArrangedSubview:self.episodeReverseButton];
    [paging addArrangedSubview:self.previousPageButton];[paging addArrangedSubview:self.nextPageButton];self.previousPageButton.hidden=YES;self.nextPageButton.hidden=YES;[self.previousPageButton.heightAnchor constraintGreaterThanOrEqualToConstant:38].active=YES;[self.nextPageButton.heightAnchor constraintGreaterThanOrEqualToConstant:38].active=YES;[self.episodeReverseButton.heightAnchor constraintGreaterThanOrEqualToConstant:38].active=YES;[sourceStack addArrangedSubview:paging];
    self.episodeGrid=[UIStackView new];self.episodeGrid.axis=UILayoutConstraintAxisVertical;self.episodeGrid.spacing=5;self.episodeGrid.distribution=UIStackViewDistributionFillEqually;self.episodeGrid.accessibilityIdentifier=@"media-detail-episode-grid";[sourceStack addArrangedSubview:self.episodeGrid];
    [self.contentStack addArrangedSubview:sourceCard];
    [self updateParserSelectionButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.hidesWhenStopped=YES;self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[[self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)dealloc {[self.client cancel];}
- (void)goBack {[self.navigationController popViewControllerAnimated:YES];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController){self.generation++;[self.client cancel];}}
- (void)scrollToEpisodes {CGRect rect=[self.episodeTitle convertRect:self.episodeTitle.bounds toView:self.scrollView];CGFloat y=MAX(-self.scrollView.adjustedContentInset.top,rect.origin.y-12);[self.scrollView setContentOffset:CGPointMake(0,y) animated:YES];}
- (void)copyTitle {NSString *name=[self.detail[@"name"] isKindOfClass:NSString.class]?self.detail[@"name"]:([self.item[@"name"] isKindOfClass:NSString.class]?self.item[@"name"]:@"");if(!name.length)return;UIPasteboard.generalPasteboard.string=name;self.status.text=@"片名已复制";self.status.hidden=NO;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if([self.status.text isEqualToString:@"片名已复制"])self.status.hidden=YES;});}
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
    if(self.inlinePlaybackController){[self.inlinePlaybackController playInlineResult:result context:context];self.heroView.hidden=YES;return;}
    MediaPlaybackViewController *player=[MediaPlaybackViewController new];player.embeddedMode=YES;player.onPlaybackWillStart=self.onPlaybackWillStart;player.result=result;player.context=context;self.inlinePlaybackController=player;
    __weak typeof(self) weakSelf=self;player.onEpisodeSelectionChanged=^(NSDictionary *updatedContext){MediaDetailViewController *owner=weakSelf;if(!owner)return;NSArray *lines=owner.lines;NSInteger lineIndex=[updatedContext[@"lineIndex"] integerValue],episodeIndex=[updatedContext[@"episodeIndex"] integerValue];NSString *episodeID=[updatedContext[@"episodeID"] description]?:@"",*episodeName=[updatedContext[@"episodeName"] description]?:@"";BOOL matched=NO;
        if(lineIndex>=0&&lineIndex<lines.count){NSArray *episodes=[lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[(NSUInteger)lineIndex][@"episodes"]:@[];if(episodeIndex>=0&&episodeIndex<episodes.count){NSDictionary *candidate=episodes[(NSUInteger)episodeIndex];matched=!episodeID.length&&!episodeName.length||(episodeID.length&&[[candidate[@"id"] description] isEqual:episodeID])||(!episodeID.length&&episodeName.length&&[[candidate[@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame);}}
        if(!matched&&(episodeID.length||episodeName.length)){for(NSUInteger line=0;line<lines.count&&!matched;line++){NSArray *episodes=[lines[line][@"episodes"] isKindOfClass:NSArray.class]?lines[line][@"episodes"]:@[];for(NSUInteger episode=0;episode<episodes.count;episode++){NSDictionary *candidate=episodes[episode];if((episodeID.length&&[[candidate[@"id"] description] isEqual:episodeID])||(!episodeID.length&&episodeName.length&&[[candidate[@"name"] description] localizedCaseInsensitiveCompare:episodeName]==NSOrderedSame)){lineIndex=(NSInteger)line;episodeIndex=(NSInteger)episode;matched=YES;break;}}}}
        if(!matched||lineIndex<0||lineIndex>=lines.count)return;NSArray *episodes=[lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?lines[(NSUInteger)lineIndex][@"episodes"]:@[];if(episodeIndex<0||episodeIndex>=episodes.count)return;owner.selectedLineIndex=lineIndex;owner.selectedEpisodeIndex=episodeIndex;owner.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)episodeIndex,episodes.count,owner.episodeOrderReversed);owner.resumeEntry=nil;[owner updateRouteAndEpisodeViews];};
    if(self.heroSpacer){[self.contentStack removeArrangedSubview:self.heroSpacer];[self.heroSpacer removeFromSuperview];self.heroSpacer=nil;}
    [self addChildViewController:player];player.view.translatesAutoresizingMaskIntoConstraints=NO;
    [self.contentStack insertArrangedSubview:player.view atIndex:0];
    NSLayoutConstraint *inlineHeight=[player.view.heightAnchor constraintEqualToAnchor:player.view.widthAnchor multiplier:0.5625 constant:88];inlineHeight.priority=UILayoutPriorityDefaultHigh;inlineHeight.identifier=@"media-detail-inline-player-compact-height";inlineHeight.active=YES;
    [player didMoveToParentViewController:self];self.heroView.hidden=YES;[player playInlineResult:result context:context];[self.scrollView setContentOffset:CGPointMake(0,-self.scrollView.adjustedContentInset.top) animated:YES];
    [RuntimeDiagnostics.shared recordEvent:@"inline_playback_attached" category:@"playback" fields:@{@"correlation_id":context[@"correlationID"]?:@"",@"service_id":context[@"source"][@"id"]?:@"",@"line_index":context[@"lineIndex"]?:@0,@"episode_index":context[@"episodeIndex"]?:@0}];
}
- (void)loadDetail {
    NSUInteger generation=++self.generation;
    [self.client cancel];
    self.status.text=@"正在加载影片详情…";
    self.status.hidden=NO;
    [self.spinner startAnimating];
    NSString *requestedItemID=([self.item[@"id"] isKindOfClass:NSString.class]||[self.item[@"id"] isKindOfClass:NSNumber.class])?[self.item[@"id"] description]:@"";NSMutableDictionary *args=[@{@"id":requestedItemID} mutableCopy];
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
        NSUInteger discardedLines=0,discardedEpisodes=0;NSDictionary *sanitizedDetail=MediaBrowserSanitizedDetail(result,&discardedLines,&discardedEpisodes);if(!sanitizedDetail){owner.status.text=@"来源返回的影片详情格式无法识别";owner.status.hidden=NO;return;}
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
    NSInteger lineIndex=[entry[@"lineIndex"] integerValue],episodeIndex=[entry[@"episodeIndex"] integerValue];NSString *lineID=entry[@"lineID"]?:@"",*episodeID=entry[@"episodeID"]?:@"";BOOL lineFound=NO;
    for(NSUInteger index=0;index<self.lines.count;index++)if(lineID.length&&[[self.lines[index][@"id"] description] isEqual:lineID]){lineIndex=(NSInteger)index;lineFound=YES;break;}
    if(lineID.length&&!lineFound){self.resumeEntry=nil;return;}if(!lineFound&&(lineIndex<0||lineIndex>=self.lines.count))lineIndex=0;
    NSArray *episodes=lineIndex>=0&&lineIndex<self.lines.count&&[self.lines[(NSUInteger)lineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[(NSUInteger)lineIndex][@"episodes"]:@[];BOOL episodeFound=NO;
    for(NSUInteger index=0;index<episodes.count;index++)if(episodeID.length&&[[episodes[index][@"id"] description] isEqual:episodeID]){episodeIndex=(NSInteger)index;episodeFound=YES;break;}
    if((episodeID.length&&!episodeFound)||(!episodeFound&&(episodeIndex<0||episodeIndex>=episodes.count))){self.resumeEntry=nil;return;}
    self.selectedLineIndex=lineIndex;self.selectedEpisodeIndex=episodeIndex;self.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)episodeIndex,episodes.count,self.episodeOrderReversed);
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
    NSMutableArray *parts=[NSMutableArray array];for(NSString *key in @[@"year",@"area",@"lang",@"type",@"remarks"]){id value=self.detail[key];if([value isKindOfClass:NSString.class]&&[value length])[parts addObject:value];}
    return parts.count?[parts componentsJoinedByString:@" · "]:@"";
}
- (void)refreshDetailHeader {
    NSString *poster=[self posterURL];self.posterView.accessibilityLabel=poster.length?@"影片背景海报":@"暂无海报，显示影片占位图";self.posterThumbnailView.accessibilityLabel=poster.length?@"影片海报":@"暂无海报";self.posterPlaceholder.hidden=poster.length>0;if(poster.length){MediaLoadPosterWithRetry(poster,self.posterView,1);MediaLoadPosterWithRetry(poster,self.posterThumbnailView,1);}else{self.posterView.image=nil;self.posterView.accessibilityIdentifier=nil;self.posterThumbnailView.image=nil;self.posterThumbnailView.accessibilityIdentifier=nil;}
    NSString *detailName=[self.detail[@"name"] isKindOfClass:NSString.class]?self.detail[@"name"]:@"";NSString *itemName=[self.item[@"name"] isKindOfClass:NSString.class]?self.item[@"name"]:@"";NSString *name=detailName.length?detailName:(itemName.length?itemName:@"影片详情");self.title=name;self.heroTitle.text=name;self.heroMetadata.text=[self metadataSummary];
    NSMutableArray *info=[NSMutableArray array];NSString *metadata=[self metadataSummary];if(metadata.length)[info addObject:metadata];NSString *director=[self.detail[@"director"] isKindOfClass:NSString.class]?self.detail[@"director"]:@"";
    if(director.length)[info addObject:[NSString stringWithFormat:@"导演：%@",director]];self.metadataLabel.text=[info componentsJoinedByString:@"\n"];
    NSString *synopsis=[self.detail[@"description"] isKindOfClass:NSString.class]?self.detail[@"description"]:@"";if(synopsis.length>1200)synopsis=[[synopsis substringToIndex:1200] stringByAppendingString:@"…"];self.descriptionLabel.text=synopsis.length?synopsis:@"暂无简介";self.descriptionToggle.hidden=synopsis.length<220;self.descriptionLabel.numberOfLines=self.descriptionExpanded?0:3;[self updateFavoriteButton];
}
- (NSString *)favoriteKey {NSString *sourceID=[self.source[@"id"] description]?:@"",*provider=self.provider?:@"",*itemID=[self.item[@"id"] description]?:@"";return [NSString stringWithFormat:@"%lu:%@%lu:%@%lu:%@",(unsigned long)sourceID.length,sourceID,(unsigned long)provider.length,provider,(unsigned long)itemID.length,itemID];}
- (void)updateFavoriteButton {
    NSDictionary *favorites=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};BOOL favorite=favorites[[self favoriteKey]]!=nil;UIImageSymbolConfiguration *configuration=[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];UIImage *image=[UIImage systemImageNamed:favorite?@"heart.fill":@"heart" withConfiguration:configuration];if(image)[self.favoriteButton setImage:image forState:UIControlStateNormal];self.favoriteButton.tintColor=HostAccent();[self.favoriteButton setTitleColor:HostText() forState:UIControlStateNormal];self.favoriteButton.accessibilityLabel=favorite?@"取消收藏影片":@"收藏影片";
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
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker];navigation.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;HostStyleNavigation(navigation);navigation.navigationBar.prefersLargeTitles=NO;navigation.modalPresentationStyle=UIModalPresentationPageSheet;UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;}[self presentViewController:navigation animated:YES completion:nil];
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
    self.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)MAX(0,self.selectedEpisodeIndex),episodes.count,self.episodeOrderReversed);
    [RuntimeDiagnostics.shared recordEvent:@"media_episode_order_changed" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.source[@"id"]?:@"",@"provider_id":self.provider?:@"",@"reversed":@(self.episodeOrderReversed),@"episode_count":@(episodes.count),@"selected_episode_index":@(self.selectedEpisodeIndex)}];
    [self updateRouteAndEpisodeViews];
}
- (void)updateRouteAndEpisodeViews {
    for(UIView *view in self.routeButtons.arrangedSubviews.copy){[self.routeButtons removeArrangedSubview:view];[view removeFromSuperview];}if(self.selectedLineIndex>=self.lines.count)self.selectedLineIndex=0;
    for(NSUInteger index=0;index<self.lines.count;index++){NSDictionary *line=self.lines[index];UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=index;NSString *name=[line[@"name"] isKindOfClass:NSString.class]?line[@"name"]:[NSString stringWithFormat:@"线路 %lu",(unsigned long)index+1];
        [button setTitle:name forState:UIControlStateNormal];button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-route-%lu",(unsigned long)index];HostStylePillButton(button,index==self.selectedLineIndex);[button addTarget:self action:@selector(selectRoute:) forControlEvents:UIControlEventTouchUpInside];[self.routeButtons addArrangedSubview:button];}
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];self.selectedEpisodeIndex=episodes.count?MIN(MAX(0,self.selectedEpisodeIndex),(NSInteger)episodes.count-1):0;self.episodeTitle.text=[NSString stringWithFormat:@"选集 · %lu 集",(unsigned long)episodes.count];
    NSUInteger pageCount=MAX(1,(episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup);self.episodePage=MIN(self.episodePage,(NSInteger)pageCount-1);NSUInteger start=(NSUInteger)self.episodePage*CCTVEpisodesPerGroup,end=MIN(start+CCTVEpisodesPerGroup,episodes.count);
    NSUInteger firstSource=end>start?CCTVEpisodeSourceIndex(start,episodes.count,self.episodeOrderReversed):0,lastSource=end>start?CCTVEpisodeSourceIndex(end-1,episodes.count,self.episodeOrderReversed):0;
    self.pageLabel.text=episodes.count?[NSString stringWithFormat:@"第 %ld/%lu 组 · 第 %lu–%lu 集 · %@",(long)self.episodePage+1,(unsigned long)pageCount,(unsigned long)firstSource+1,(unsigned long)lastSource+1,self.episodeOrderReversed?@"倒序":@"正序"]:@"此线路没有可选分集";
    [self.episodeReverseButton setTitle:self.episodeOrderReversed?@"正序":@"倒序" forState:UIControlStateNormal];self.episodeReverseButton.accessibilityLabel=self.episodeOrderReversed?@"按正序排列分集，当前为倒序":@"按倒序排列分集，当前为正序";self.episodeReverseButton.hidden=episodes.count<2;
    self.previousPageButton.hidden=pageCount<=1;self.nextPageButton.hidden=pageCount<=1;self.previousPageButton.enabled=self.episodePage>0;self.nextPageButton.enabled=self.episodePage+1<pageCount;self.playButton.enabled=episodes.count>0;self.playButton.alpha=episodes.count?1.0:0.55;
    NSDictionary *selectedLine=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex]:@{};NSDictionary *selectedEpisode=self.selectedEpisodeIndex<episodes.count?episodes[self.selectedEpisodeIndex]:@{};NSString *resumeLineID=self.resumeEntry[@"lineID"]?:@"",*resumeEpisodeID=self.resumeEntry[@"episodeID"]?:@"";BOOL lineMatches=resumeLineID.length?[[selectedLine[@"id"] description] isEqual:resumeLineID]:self.selectedLineIndex==[self.resumeEntry[@"lineIndex"] integerValue];BOOL episodeMatches=resumeEpisodeID.length?[[selectedEpisode[@"id"] description] isEqual:resumeEpisodeID]:self.selectedEpisodeIndex==[self.resumeEntry[@"episodeIndex"] integerValue];BOOL resumeSelected=self.resumeEntry&&lineMatches&&episodeMatches;
    if(resumeSelected){NSString *verb=[self.resumeEntry[@"completed"] boolValue]?@"重新播放":@"继续观看";[self.playButton setTitle:[NSString stringWithFormat:@"▶︎  %@ · %@",verb,self.resumeEntry[@"episodeName"]?:@"上次分集"] forState:UIControlStateNormal];}else [self.playButton setTitle:@"▶︎  播放" forState:UIControlStateNormal];
    for(UIView *row in self.episodeGrid.arrangedSubviews.copy){[self.episodeGrid removeArrangedSubview:row];[row removeFromSuperview];}[self.episodeButtons removeAllObjects];if(!episodes.count)return;
    NSUInteger columnCount=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?3:4;NSUInteger visibleCount=end>start?end-start:0;NSUInteger rowCount=(visibleCount+columnCount-1)/columnCount;for(NSUInteger rowIndex=0;rowIndex<rowCount;rowIndex++){UIStackView *row=[UIStackView new];row.axis=UILayoutConstraintAxisHorizontal;row.spacing=6;row.distribution=UIStackViewDistributionFillEqually;
        for(NSUInteger col=0;col<columnCount;col++){NSUInteger displayIndex=start+rowIndex*columnCount+col;if(displayIndex<end){NSUInteger index=CCTVEpisodeSourceIndex(displayIndex,episodes.count,self.episodeOrderReversed);UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.layer.cornerRadius=14;button.layer.cornerCurve=kCACornerCurveContinuous;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;NSDictionary *episode=episodes[index];NSString *name=[episode[@"name"] isKindOfClass:NSString.class]?episode[@"name"]:[NSString stringWithFormat:@"第 %lu 集",(unsigned long)index+1];[button setTitle:name forState:UIControlStateNormal];button.tag=index;button.accessibilityIdentifier=[NSString stringWithFormat:@"media-detail-episode-%lu",(unsigned long)index];HostStylePillButton(button,(NSInteger)index==self.selectedEpisodeIndex);button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.78;[button addTarget:self action:@selector(selectEpisode:) forControlEvents:UIControlEventTouchUpInside];[self.episodeButtons addObject:button];[row addArrangedSubview:button];}else{UIView *spacer=[UIView new];spacer.isAccessibilityElement=NO;[row addArrangedSubview:spacer];}}
        [self.episodeGrid addArrangedSubview:row];[row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active=YES;
    }
}
- (void)selectRoute:(UIButton *)sender {
    if(sender.tag>=self.lines.count||sender.tag==self.selectedLineIndex)return;
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
    NSInteger matchedEpisode=-1;if(previousEpisodeID.length)for(NSUInteger index=0;index<episodes.count;index++)if([[episodes[index][@"id"] description] isEqual:previousEpisodeID]){matchedEpisode=(NSInteger)index;break;}if(matchedEpisode<0&&previousEpisodeName.length)for(NSUInteger index=0;index<episodes.count;index++)if([[episodes[index][@"name"] description] localizedCaseInsensitiveCompare:previousEpisodeName]==NSOrderedSame){matchedEpisode=(NSInteger)index;break;}self.selectedEpisodeIndex=episodes.count?(matchedEpisode>=0?matchedEpisode:MIN(MAX(0,previousEpisodeIndex),(NSInteger)episodes.count-1)):0;self.episodePage=CCTVEpisodeGroupForSourceIndex((NSUInteger)self.selectedEpisodeIndex,episodes.count,self.episodeOrderReversed);
    [self updateRouteAndEpisodeViews];
    if(self.inlinePlaybackController&&episodes.count)[self resolveAndPlaySelectedEpisode];
}
- (void)previousEpisodePage {if(self.episodePage>0){self.episodePage--;[self updateRouteAndEpisodeViews];}}
- (void)nextEpisodePage {NSArray *episodes=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(self.episodePage+1<(NSInteger)((episodes.count+CCTVEpisodesPerGroup-1)/CCTVEpisodesPerGroup)){self.episodePage++;[self updateRouteAndEpisodeViews];}}
- (void)selectEpisode:(UIButton *)sender {
    NSArray *episodes=self.selectedLineIndex<self.lines.count&&[self.lines[self.selectedLineIndex][@"episodes"] isKindOfClass:NSArray.class]?self.lines[self.selectedLineIndex][@"episodes"]:@[];
    if(sender.tag>=episodes.count)return;
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
- (void)playCurrentEpisode {NSArray *episodes=self.selectedLineIndex<self.lines.count?self.lines[self.selectedLineIndex][@"episodes"]:@[];if(!episodes.count)return;if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)self.selectedEpisodeIndex=0;[self resolveAndPlaySelectedEpisode];}
- (void)resolveAndPlaySelectedEpisode {
    if(self.selectedLineIndex>=self.lines.count)return;NSArray *episodes=self.lines[self.selectedLineIndex][@"episodes"];if(self.selectedEpisodeIndex<0||self.selectedEpisodeIndex>=episodes.count)return;
    NSDictionary *line=self.lines[self.selectedLineIndex],*episode=episodes[self.selectedEpisodeIndex];NSUInteger generation=++self.generation;[self.client cancel];self.status.hidden=NO;self.status.text=[NSString stringWithFormat:@"正在解析 %@…",episode[@"name"]?:@"当前分集"];[self.spinner startAnimating];[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_requested" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"", @"service_id":self.source[@"id"]?:@"", @"provider_id":self.provider?:@"", @"request_generation":@(generation), @"line_index":@(self.selectedLineIndex), @"episode_index":@(self.selectedEpisodeIndex), @"line_count":@(self.lines.count), @"episode_count":@(episodes.count), @"episode_has_id":@([episode[@"id"] description].length>0), @"line_has_id":@([line[@"id"] description].length>0)}];
    NSString *parserID=[self selectedPlaybackParserID];NSMutableDictionary *args=[@{@"id":episode[@"id"]?:@"",@"lineId":line[@"id"]?:@"",@"parserID":parserID} mutableCopy];if(self.provider.length)args[@"provider"]=self.provider;__weak typeof(self) weakSelf=self;
    [self.client call:@"play" arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){MediaDetailViewController *owner=weakSelf;if(!owner)return;if(owner.generation!=generation){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"request_generation":@(generation), @"current_generation":@(owner.generation), @"reason":@"superseded_selection"}];return;}[owner.spinner stopAnimating];owner.status.hidden=NO;
        if(error||![result isKindOfClass:NSDictionary.class]){[RuntimeDiagnostics.shared recordEvent:@"episode_resolve_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"line_index":@(owner.selectedLineIndex), @"episode_index":@(owner.selectedEpisodeIndex), @"error_domain":error.domain?:@"", @"error_code":@(error.code), @"error_message":error.localizedDescription?:@"", @"result_received":@([result isKindOfClass:NSDictionary.class])}];owner.status.text=[NSString stringWithFormat:@"解析失败：%@",error.localizedDescription?:@"来源没有返回可播放结果"];[owner updateRouteAndEpisodeViews];return;}
        [RuntimeDiagnostics.shared recordEvent:@"episode_resolve_succeeded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"", @"service_id":owner.source[@"id"]?:@"", @"provider_id":owner.provider?:@"", @"request_generation":@(generation), @"line_index":@(owner.selectedLineIndex), @"episode_index":@(owner.selectedEpisodeIndex), @"result_has_media_url":@([result[@"url"] isKindOfClass:NSString.class]&&[result[@"url"] length]>0), @"result_parse_mode":@([result[@"parse"] respondsToSelector:@selector(integerValue)]?[result[@"parse"] integerValue]:0), @"result_alternate_count":@([result[@"alternates"] isKindOfClass:NSArray.class]?[result[@"alternates"] count]:0)}];owner.status.hidden=YES;NSDictionary *context=@{@"source":owner.source?:@{},@"provider":owner.provider?:@"",@"item":owner.item?:@{},@"detail":owner.detail?:@{},@"episodeID":[episode[@"id"] description]?:@"",@"episodeName":[episode[@"name"] description]?:@"",@"lineIndex":@(owner.selectedLineIndex),@"episodeIndex":@(owner.selectedEpisodeIndex),@"parserID":parserID,@"correlationID":owner.diagnosticTraceID?:@""};if(owner.onPlay)owner.onPlay(result,context);
    }];
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];self.heroGradient.frame=self.heroView.bounds;[self updateInlinePlaybackFloatingPosition]; }
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView!=self.scrollView)return;[self updateInlinePlaybackFloatingPosition];
}
- (void)updateInlinePlaybackFloatingPosition {
    if(!self.inlinePlaybackController||!self.scrollView)return;
    UIView *playerView=self.inlinePlaybackController.view;playerView.transform=CGAffineTransformIdentity;
    CGRect scrollFrame=[self.scrollView convertRect:self.scrollView.bounds toView:self.view];CGFloat pinTop=MAX(CGRectGetMinY(scrollFrame),self.view.safeAreaInsets.top);
    UINavigationBar *bar=self.navigationController.navigationBar;if(bar&&!bar.hidden)pinTop=MAX(pinTop,CGRectGetMaxY([bar convertRect:bar.bounds toView:self.view]));
    CGRect playerFrame=[playerView convertRect:playerView.bounds toView:self.view];CGFloat pinOffset=MAX(0,pinTop-CGRectGetMinY(playerFrame));playerView.transform=CGAffineTransformMakeTranslation(0,pinOffset);playerView.layer.zPosition=pinOffset>0?10:0;
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
    NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";if(poster.length)MediaLoadPosterWithRetry(poster,cell.imageView,1);else{cell.imageView.image=[UIImage systemImageNamed:@"film"];cell.imageView.accessibilityIdentifier=nil;cell.imageView.contentMode=UIViewContentModeCenter;cell.imageView.tintColor=HostSecondaryText();}return cell;
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
static CGFloat MediaHomeCardWidth(CGFloat viewWidth) {CGFloat available=MAX(1,viewWidth-32);return MAX(112,floor((available-16)/2.5));}
static NSArray<NSDictionary *> *MediaHomeModuleDefinitions(void) {
    return @[@{@"id":@"recommendations",@"title":@"来源推荐",@"detail":@"显示所选来源已有的推荐缓存；不会在首页自动启动服务"},
             @{@"id":@"catalog",@"title":@"首页分类筛选",@"detail":@"使用来源提供的分类筛选短剧海报网格"},
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
    [super viewDidLoad];self.title=@"首页配置";self.view.backgroundColor=HostBackground();self.tableView.backgroundColor=HostBackground();self.modules=[MediaHomeEnabledModules() mutableCopy];self.pinnedSources=[MediaHomePinnedSources() mutableCopy];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
}
- (void)close {[self dismissViewControllerAnimated:YES completion:self.onChange];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 3;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return section==0?MediaHomeModuleDefinitions().count:(section==1?2:self.sources.count);}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {return section==0?@"显示模块":(section==1?@"海报网格列数":@"固定的影视来源");}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return section==0?@"首页内容来自本机观看记录、影视收藏和已导入资源。关闭模块只会隐藏首页入口，不会删除数据。":(section==1?@"3 列卡片更大；4 列布局更紧凑。此设置只影响影视首页海报卡片，影视库固定为 3 列。":(self.sources.count?@"固定来源只会显示在首页。点按来源后才会启动对应服务。":@"导入影视资源后，可以在这里固定常用来源。"));}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"media-home-setting"];if(!cell)cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media-home-setting"];cell.backgroundColor=HostCard();cell.textLabel.textColor=HostText();cell.detailTextLabel.textColor=HostSecondaryText();cell.detailTextLabel.numberOfLines=2;cell.accessoryType=UITableViewCellAccessoryNone;
    if(indexPath.section==1){NSInteger columns=indexPath.row==0?3:4;cell.accessoryView=nil;cell.selectionStyle=UITableViewCellSelectionStyleDefault;cell.textLabel.text=[NSString stringWithFormat:@"%ld 列%@",(long)columns,columns==3?@" · 标准":@" · 紧凑"];cell.detailTextLabel.text=columns==3?@"海报和标题更大，浏览更舒适。":@"单屏展示更多影片，海报更紧凑。";cell.accessoryType=MediaBrowserGridColumns()==columns?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;cell.accessibilityIdentifier=[NSString stringWithFormat:@"media-home-grid-columns-%ld",(long)columns];return cell;}
    NSString *identifier=nil;BOOL enabled=NO;if(indexPath.section==0){NSDictionary *row=MediaHomeModuleDefinitions()[indexPath.row];identifier=row[@"id"];cell.textLabel.text=row[@"title"];cell.detailTextLabel.text=row[@"detail"];enabled=[self.modules containsObject:identifier];}else{NSDictionary *source=self.sources[indexPath.row];identifier=source[@"id"]?:@"";cell.textLabel.text=source[@"name"]?:@"影视资源";NSString *engine=source[@"engine"]?:@"未知运行引擎";cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · 点按卡片时才启动",engine];enabled=[self.pinnedSources containsObject:identifier];}
    UISwitch *toggle=[UISwitch new];toggle.on=enabled;toggle.accessibilityIdentifier=[NSString stringWithFormat:@"%@:%@",indexPath.section==0?@"module":@"source",identifier];[toggle addTarget:self action:@selector(toggleSetting:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {if(indexPath.section!=1){[tableView deselectRowAtIndexPath:indexPath animated:YES];return;}[NSUserDefaults.standardUserDefaults setInteger:indexPath.row==0?3:4 forKey:MediaBrowserGridColumnsDefaultsKey];[tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];if(self.onChange)self.onChange();}
- (void)toggleSetting:(UISwitch *)sender {
    NSArray *parts=[sender.accessibilityIdentifier componentsSeparatedByString:@":"];if(parts.count!=2)return;NSString *kind=parts[0],*identifier=parts[1];NSMutableSet *set=[kind isEqual:@"module"]?self.modules:self.pinnedSources;if(sender.isOn)[set addObject:identifier];else[set removeObject:identifier];NSString *key=[kind isEqual:@"module"]?MediaHomeModulesDefaultsKey:MediaHomePinnedSourcesDefaultsKey;[NSUserDefaults.standardUserDefaults setObject:[[set allObjects] sortedArrayUsingSelector:@selector(compare:)] forKey:key];if([kind isEqual:@"module"])[NSUserDefaults.standardUserDefaults setInteger:3 forKey:MediaHomeModulesSchemaKey];if(self.onChange)self.onChange();
}
@end

@interface MediaBrowserViewController () <UICollectionViewDataSource,UICollectionViewDelegateFlowLayout,UISearchResultsUpdating,UIScrollViewDelegate>
@property(nonatomic, strong) UICollectionView *grid;
@property(nonatomic,strong) UICollectionView *homeGrid;
@property(nonatomic,strong) MediaHomeCarouselView *homeCarousel;
@property(nonatomic,strong) UIButton *floatingHomeSearchButton;
@property(nonatomic,strong) NSLayoutConstraint *homeGridHeightConstraint;
@property(nonatomic,strong) UIButton *homeGridMoreButton;
@property(nonatomic,strong) NSLayoutConstraint *categoryScrollHeightConstraint;
@property(nonatomic) CGFloat homeGridLayoutWidth;
@property(nonatomic) CGFloat lastHomePosterVisibilityOffset;
@property(nonatomic) BOOL homePosterVisibilityInitialized;
@property(nonatomic,copy) NSString *homeDiscoveryVisibleStateKey;
@property(nonatomic, strong) UISearchController *search;
@property(nonatomic,strong) UIScrollView *homeScroll;
@property(nonatomic,strong) UIStackView *homeStack;
@property(nonatomic,strong) NSLayoutConstraint *homeScrollTopConstraint;
@property(nonatomic,strong) NSLayoutConstraint *homeStackTopConstraint;
@property(nonatomic,strong) UIView *homeTopImmersiveScrim;
@property(nonatomic,strong) CAGradientLayer *homeTopImmersiveGradient;
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
@property(nonatomic,strong) UIButton *homeModeButton;
@property(nonatomic,strong) UIButton *homeSearchButton;
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
- (NSArray<NSDictionary *> *)homeGridItems;
- (void)updateHomeGridLayout;
- (void)updateVisibleHomePosters;
- (void)loadVisibleHomeShelves;
- (void)addHomeSkeletonModules;
- (void)addHomeSkeletonShelf:(NSString *)title identifier:(NSString *)identifier;
- (UIButton *)homeSkeletonPosterCard;
- (UIView *)homeSkeletonBarWithWidth:(CGFloat)width height:(CGFloat)height;
- (void)toggleHomeFavoriteItem:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider;
- (void)openGlobalSearch;
- (void)openGlobalSearchForKeyword:(nullable NSString *)keyword excludingIndexSources:(BOOL)excludeIndexSources;
- (BOOL)openMetadataSearchForItem:(NSDictionary *)item;
- (void)loadHomeShelves:(NSArray<NSDictionary *> *)categories index:(NSUInteger)index generation:(NSUInteger)generation sourceID:(NSString *)sourceID provider:(NSString *)provider;
- (void)addHomeFeatureGrid:(NSArray<NSDictionary *> *)items;
- (void)loadHome;
@end
@implementation MediaBrowserViewController
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf=self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){MediaBrowserViewController *owner=weakSelf;if(owner.homeMode)[owner refreshHomeModules];}];
}

- (void)searchHistorySettingChanged:(NSNotification *)notification {if([notification.userInfo[@"enabled"] boolValue])return;for(NSString *key in self.browseStates.allKeys.copy){NSMutableDictionary *state=[self.browseStates[key] mutableCopy];if(state){state[@"keyword"]=@"";self.browseStates[key]=state;}}if(self.pendingBrowseState){NSMutableDictionary *pending=[self.pendingBrowseState mutableCopy];pending[@"keyword"]=@"";self.pendingBrowseState=pending;}}
- (NSString *)homeScrollOffsetKeyForSource:(NSDictionary *)source {NSString *sourceID=[[source[@"id"] description] isKindOfClass:NSString.class]?[source[@"id"] description]:@"";return [NSString stringWithFormat:@"cctv.mediaHome.scrollOffset.v2.%lu:%@",(unsigned long)sourceID.length,sourceID];}
- (void)saveHomeScrollOffset {if(!self.homeScroll||!self.source)return;[NSUserDefaults.standardUserDefaults setDouble:self.homeScroll.contentOffset.y forKey:[self homeScrollOffsetKeyForSource:self.source]];}
- (void)restoreHomeScrollOffsetIfNeeded {if(!self.pendingHomeOffsetRestore||self.homeScroll.bounds.size.height<=0)return;CGFloat minimum=-self.homeScroll.adjustedContentInset.top;CGFloat maximum=MAX(minimum,self.homeScroll.contentSize.height-self.homeScroll.bounds.size.height+self.homeScroll.adjustedContentInset.bottom);self.homeScroll.contentOffset=CGPointMake(self.homeScroll.contentOffset.x,MIN(MAX(self.pendingHomeOffsetRestore.doubleValue,minimum),maximum));self.pendingHomeOffsetRestore=nil;}
- (void)saveSessionState {if(self.homeMode)[self saveHomeScrollOffset];else[self saveCurrentBrowseState];}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];if(self.homeMode)[self saveHomeScrollOffset];else[self saveCurrentBrowseState];
    if(self.loading||self.homeShelfRequestInFlight||self.activeMediaOperation.length){
        NSString *operation=self.activeMediaOperation.length?self.activeMediaOperation:(self.homeShelfRequestInFlight?@"home_shelf":@"readiness");self.cancelledMediaOperation=operation;self.cancelledMediaRequestWasAppend=self.activeMediaRequestAppend;self.resumeCancelledMediaRequestOnAppear=YES;self.generation++;self.homeShelfGeneration=0;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaRequestAppend=NO;self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;[self.readiness cancel];[self.client cancel];
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
        if(self.homeMode) {self.cancelledMediaRequestWasAppend=NO;self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeLoadDeferred=YES;[RuntimeDiagnostics.shared recordEvent:@"media_request_resume_skipped" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"",@"operation":operation,@"reason":@"home_content_requires_explicit_resource_refresh",@"correlation_id":self.diagnosticTraceID?:@""}];[self showMessage:self.homeResult?@"已保留首页内容；需要更新请到资源页手动刷新":@"首页加载已暂停；请到资源页手动加载" loading:NO];return;}
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
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated];HostStyleNavigation(self.navigationController); }
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
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat overlayBottom=CGRectGetMaxY(self.categoryScroll.frame)+6;
    if(self.homeStackTopConstraint.constant!=overlayBottom)self.homeStackTopConstraint.constant=MAX(0,overlayBottom);
    self.homeTopImmersiveScrim.frame=CGRectMake(0,0,CGRectGetWidth(self.view.bounds),MAX(overlayBottom+12,self.view.safeAreaInsets.top+48));
    self.homeTopImmersiveGradient.frame=self.homeTopImmersiveScrim.bounds;
    CGFloat width=CGRectGetWidth(self.homeGrid.bounds);
    if(self.homeMode&&width>0&&fabs(width-self.homeGridLayoutWidth)>0.5)[self updateHomeGridLayout];
    [self updateVisibleHomePosters];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.title=@"";self.view.backgroundColor=HostBackground();self.items=@[];self.keyword=@"";self.homeMode=YES;self.homeCategoryLoadsInFlight=[NSMutableSet set];NSDictionary *savedBrowse=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"media.browseStates.v1"];self.browseStates=[savedBrowse isKindOfClass:NSDictionary.class]?[savedBrowse mutableCopy]:[NSMutableDictionary dictionary];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(searchHistorySettingChanged:) name:@"MediaGlobalSearchHistoryDidChange" object:nil];self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"搜索当前影视来源";self.search.searchBar.autocapitalizationType=UITextAutocapitalizationTypeNone;self.definesPresentationContext=YES;
    self.navigationItem.rightBarButtonItems=@[HostToolbar(@[
        @{@"icon":@"ellipsis",@"title":@"更多影视操作",@"menu":[self homeActionsMenu]}
    ])];
    self.homeScroll=[UIScrollView new];self.homeScroll.translatesAutoresizingMaskIntoConstraints=NO;self.homeScroll.alwaysBounceVertical=YES;self.homeScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.homeScroll.delegate=self;self.homeScroll.accessibilityIdentifier=@"media-home-scroll";[self.view addSubview:self.homeScroll];
    self.homeTopImmersiveScrim=[UIView new];self.homeTopImmersiveScrim.userInteractionEnabled=NO;self.homeTopImmersiveGradient=[CAGradientLayer layer];self.homeTopImmersiveGradient.colors=@[(id)[UIColor colorWithWhite:0 alpha:.84].CGColor,(id)[UIColor colorWithWhite:0 alpha:.52].CGColor,(id)UIColor.clearColor.CGColor];self.homeTopImmersiveGradient.locations=@[@0,@0.68,@1];self.homeTopImmersiveGradient.startPoint=CGPointMake(.5,0);self.homeTopImmersiveGradient.endPoint=CGPointMake(.5,1);[self.homeTopImmersiveScrim.layer addSublayer:self.homeTopImmersiveGradient];[self.view addSubview:self.homeTopImmersiveScrim];
    self.homeStack=[UIStackView new];self.homeStack.translatesAutoresizingMaskIntoConstraints=NO;self.homeStack.axis=UILayoutConstraintAxisVertical;self.homeStack.spacing=12;self.homeStack.layoutMargins=UIEdgeInsetsMake(8,16,24,16);self.homeStack.layoutMarginsRelativeArrangement=YES;[self.homeScroll addSubview:self.homeStack];
    self.selectionRow=[UIStackView new];self.selectionRow.translatesAutoresizingMaskIntoConstraints=NO;self.selectionRow.axis=UILayoutConstraintAxisHorizontal;self.selectionRow.alignment=UIStackViewAlignmentCenter;self.selectionRow.distribution=UIStackViewDistributionFill;self.selectionRow.spacing=10;[self.view addSubview:self.selectionRow];
    self.sourceSelectButton=[self selectionButtonWithSymbol:@"square.stack.3d.up" identifier:@"media-source-selector" action:@selector(chooseResource)];
    self.providerSelectButton=[self selectionButtonWithSymbol:@"globe" identifier:@"media-provider-selector" action:@selector(chooseProvider)];
    NSLayoutConstraint *sourceWidth=[self.sourceSelectButton.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:.34];sourceWidth.priority=UILayoutPriorityDefaultHigh;NSLayoutConstraint *providerWidth=[self.providerSelectButton.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:.22];providerWidth.priority=UILayoutPriorityDefaultHigh;
    [self.selectionRow addArrangedSubview:self.sourceSelectButton];[self.selectionRow addArrangedSubview:self.providerSelectButton];
    sourceWidth.active=YES;providerWidth.active=YES;[self.sourceSelectButton.heightAnchor constraintEqualToConstant:38].active=YES;[self.providerSelectButton.heightAnchor constraintEqualToConstant:38].active=YES;
    UIView *homeActionSpacer=[UIView new];[homeActionSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[homeActionSpacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];[self.selectionRow addArrangedSubview:homeActionSpacer];
    self.homeModeButton=[self homeToolbarButtonWithSymbol:@"square.grid.2x2.fill" identifier:@"media-home-browse-button" label:@"打开影视库" action:@selector(toggleHomeBrowse)];[self.selectionRow addArrangedSubview:self.homeModeButton];
    self.homeSearchButton=[self homeToolbarButtonWithSymbol:@"magnifyingglass" identifier:@"media-home-search-button" label:@"全站搜索影视" action:@selector(openGlobalSearchFromHome)];[self.selectionRow addArrangedSubview:self.homeSearchButton];
    self.homeMenuButton=[self homeToolbarButtonWithSymbol:@"gearshape.fill" identifier:@"media-home-more-button" label:@"更多影视操作" action:NULL];self.homeMenuButton.menu=[self homeActionsMenu];self.homeMenuButton.showsMenuAsPrimaryAction=YES;[self.selectionRow addArrangedSubview:self.homeMenuButton];
    self.categoryScroll=[UIScrollView new];self.categoryScroll.showsHorizontalScrollIndicator=NO;self.categoryScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.categoryScroll.translatesAutoresizingMaskIntoConstraints=NO;self.categoryScrollHeightConstraint=[self.categoryScroll.heightAnchor constraintEqualToConstant:0];
    self.categories=[[UIStackView alloc] init];self.categories.axis=UILayoutConstraintAxisHorizontal;self.categories.spacing=10;self.categories.translatesAutoresizingMaskIntoConstraints=NO;[self.categoryScroll addSubview:self.categories];[self.view addSubview:self.categoryScroll];
    self.readinessStageLabel=[UILabel new];self.readinessStageLabel.translatesAutoresizingMaskIntoConstraints=NO;self.readinessStageLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.readinessStageLabel.adjustsFontForContentSizeCategory=YES;self.readinessStageLabel.textColor=HostSecondaryText();self.readinessStageLabel.numberOfLines=1;self.readinessStageLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.readinessStageLabel.accessibilityIdentifier=@"media-readiness-stage";[self.view addSubview:self.readinessStageLabel];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];layout.minimumInteritemSpacing=10;layout.minimumLineSpacing=16;layout.sectionInset=UIEdgeInsetsMake(12,14,16,14);
    self.grid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];self.grid.translatesAutoresizingMaskIntoConstraints=NO;self.grid.backgroundColor=HostBackground();self.grid.dataSource=self;self.grid.delegate=self;self.grid.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;[self.grid registerClass:MediaPosterCell.class forCellWithReuseIdentifier:@"movie"];[self.view addSubview:self.grid];
    self.moreButton=[UIButton buttonWithType:UIButtonTypeSystem];self.moreButton.translatesAutoresizingMaskIntoConstraints=NO;[self.moreButton setTitle:@"加载更多" forState:UIControlStateNormal];HostStylePillButton(self.moreButton,YES);[self.moreButton addTarget:self action:@selector(loadMore) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.moreButton];self.moreButton.hidden=YES;
    self.status=[UILabel new];self.status.textColor=UIColor.secondaryLabelColor;self.status.numberOfLines=0;self.status.textAlignment=NSTextAlignmentCenter;self.status.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.status];
    self.resourceButton=[UIButton buttonWithType:UIButtonTypeSystem];self.resourceButton.translatesAutoresizingMaskIntoConstraints=NO;[self.resourceButton setTitle:@"管理资源" forState:UIControlStateNormal];HostStylePillButton(self.resourceButton,NO);[self.resourceButton addTarget:self action:@selector(openResources) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.resourceButton];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.spinner];
    self.floatingHomeSearchButton=[UIButton buttonWithType:UIButtonTypeSystem];self.floatingHomeSearchButton.translatesAutoresizingMaskIntoConstraints=NO;self.floatingHomeSearchButton.accessibilityIdentifier=@"media-home-floating-search";self.floatingHomeSearchButton.accessibilityLabel=@"搜索影视";self.floatingHomeSearchButton.accessibilityHint=@"打开影视全站搜索";self.floatingHomeSearchButton.backgroundColor=HostAccent();self.floatingHomeSearchButton.tintColor=UIColor.whiteColor;self.floatingHomeSearchButton.layer.cornerRadius=28;self.floatingHomeSearchButton.layer.cornerCurve=kCACornerCurveContinuous;self.floatingHomeSearchButton.layer.shadowColor=HostAccent().CGColor;self.floatingHomeSearchButton.layer.shadowOpacity=.34;self.floatingHomeSearchButton.layer.shadowRadius=14;self.floatingHomeSearchButton.layer.shadowOffset=CGSizeMake(0,5);[self.floatingHomeSearchButton setImage:[UIImage systemImageNamed:@"magnifyingglass"] forState:UIControlStateNormal];self.floatingHomeSearchButton.imageView.contentMode=UIViewContentModeScaleAspectFit;HostInstallPressFeedback(self.floatingHomeSearchButton);[self.floatingHomeSearchButton addTarget:self action:@selector(openGlobalSearchFromHome) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.floatingHomeSearchButton];
    self.moreButtonBottomConstraint=[self.moreButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    self.homeScrollTopConstraint=[self.homeScroll.topAnchor constraintEqualToAnchor:self.view.topAnchor];
    self.homeStackTopConstraint=[self.homeStack.topAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.topAnchor];
    [NSLayoutConstraint activateConstraints:@[
        self.homeScrollTopConstraint,[self.homeScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.homeScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.homeScroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.homeStack.leadingAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.leadingAnchor],[self.homeStack.trailingAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.trailingAnchor],self.homeStackTopConstraint,[self.homeStack.bottomAnchor constraintEqualToAnchor:self.homeScroll.contentLayoutGuide.bottomAnchor],[self.homeStack.widthAnchor constraintEqualToAnchor:self.homeScroll.frameLayoutGuide.widthAnchor],
        [self.selectionRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],[self.selectionRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:14],[self.selectionRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],[self.selectionRow.heightAnchor constraintEqualToConstant:42],
        [self.homeModeButton.widthAnchor constraintEqualToConstant:28],[self.homeModeButton.heightAnchor constraintEqualToConstant:32],[self.homeSearchButton.widthAnchor constraintEqualToConstant:28],[self.homeSearchButton.heightAnchor constraintEqualToConstant:32],[self.homeMenuButton.widthAnchor constraintEqualToConstant:28],[self.homeMenuButton.heightAnchor constraintEqualToConstant:32],
        [self.categoryScroll.topAnchor constraintEqualToAnchor:self.selectionRow.bottomAnchor constant:8],[self.categoryScroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.categoryScroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.categoryScrollHeightConstraint,
        [self.categories.leadingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.leadingAnchor constant:14],[self.categories.trailingAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.trailingAnchor constant:-14],[self.categories.topAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.topAnchor constant:2],[self.categories.bottomAnchor constraintEqualToAnchor:self.categoryScroll.contentLayoutGuide.bottomAnchor constant:-2],[self.categories.heightAnchor constraintEqualToConstant:36],
        [self.readinessStageLabel.topAnchor constraintEqualToAnchor:self.categoryScroll.bottomAnchor constant:2],[self.readinessStageLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],[self.readinessStageLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],[self.readinessStageLabel.heightAnchor constraintGreaterThanOrEqualToConstant:16],
        [self.grid.topAnchor constraintEqualToAnchor:self.readinessStageLabel.bottomAnchor constant:2],[self.grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.grid.bottomAnchor constraintEqualToAnchor:self.moreButton.topAnchor],
        [self.moreButton.heightAnchor constraintEqualToConstant:40],self.moreButtonBottomConstraint,[self.moreButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],[self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],[self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.resourceButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:16],[self.resourceButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.spinner.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-16],
        [self.floatingHomeSearchButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-18],[self.floatingHomeSearchButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-14],[self.floatingHomeSearchButton.widthAnchor constraintEqualToConstant:56],[self.floatingHomeSearchButton.heightAnchor constraintEqualToConstant:56]]];
    [self setBrowseControlsHidden:YES];
    self.homeScroll.contentInset=UIEdgeInsetsMake(0,0,MAX(28,self.bottomOverlayInset),0);self.homeScroll.scrollIndicatorInsets=self.homeScroll.contentInset;
    [self loadSources];
    if(self.onDisplayModeChanged)self.onDisplayModeChanged(YES);
}
- (void)setBottomOverlayInset:(CGFloat)inset {if(!isfinite(inset))inset=0;self.bottomOverlayInset=MAX(0,inset);if(self.homeScroll){self.homeScroll.contentInset=UIEdgeInsetsMake(0,0,MAX(28,self.bottomOverlayInset),0);self.homeScroll.scrollIndicatorInsets=self.homeScroll.contentInset;}self.moreButtonBottomConstraint.constant=-self.bottomOverlayInset;}
- (UIButton *)selectionButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);button.layer.cornerRadius=23;button.contentEdgeInsets=UIEdgeInsetsMake(8,12,8,12);button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];button.titleLabel.adjustsFontForContentSizeCategory=YES;button.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;button.titleLabel.adjustsFontSizeToFitWidth=YES;button.titleLabel.minimumScaleFactor=0.82;button.accessibilityIdentifier=identifier;button.isAccessibilityElement=YES;button.accessibilityTraits|=UIAccessibilityTraitButton;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostAccent();button.imageEdgeInsets=UIEdgeInsetsMake(0,0,0,7);[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (UIButton *)homeToolbarButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier label:(NSString *)label action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityIdentifier=identifier;button.accessibilityLabel=label;button.isAccessibilityElement=YES;button.accessibilityTraits=UIAccessibilityTraitButton;button.tintColor=HostText();button.imageView.contentMode=UIViewContentModeScaleAspectFit;button.showsMenuAsPrimaryAction=NO;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    if(action)[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
- (UIButton *)floatingButtonWithSymbol:(NSString *)symbol identifier:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;HostStylePillButton(button,NO);button.layer.cornerRadius=28;button.layer.cornerCurve=kCACornerCurveContinuous;button.clipsToBounds=YES;button.backgroundColor=HostGlassTint();HostSetLayerBorderColor(button,HostBorder());button.layer.borderWidth=0.7;[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];button.tintColor=HostText();button.accessibilityIdentifier=identifier;button.isAccessibilityElement=YES;button.accessibilityTraits|=UIAccessibilityTraitButton;if(action)[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (UIMenu *)homeActionsMenu {
    __weak typeof(self) weakSelf=self;
    return [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:@"配置首页模块" image:[UIImage systemImageNamed:@"square.grid.2x2"] identifier:nil handler:^(UIAction *action){[weakSelf openHomeConfiguration];}],
        [UIAction actionWithTitle:@"全站搜索" image:[UIImage systemImageNamed:@"magnifyingglass"] identifier:nil handler:^(UIAction *action){[weakSelf openGlobalSearch];}],
        [UIAction actionWithTitle:@"源配置与账号" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *action){[weakSelf openSourceConfiguration];}],
        [UIAction actionWithTitle:@"我的收藏" image:[UIImage systemImageNamed:@"heart.fill"] identifier:nil handler:^(UIAction *action){[weakSelf openFavorites];}],
        [UIAction actionWithTitle:@"观看历史" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"] identifier:nil handler:^(UIAction *action){[weakSelf openHistory];}],
        [UIAction actionWithTitle:@"分类筛选" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(UIAction *action){[weakSelf chooseFilters];}],
        [UIAction actionWithTitle:@"刷新当前来源" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *action){[weakSelf refreshCurrentSource];}],
        [UIAction actionWithTitle:@"检查当前服务连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *action){[weakSelf checkCurrentService];}],
        [UIAction actionWithTitle:@"重启当前资源服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *action){[weakSelf restartCurrentService];}]
    ]];
}
- (void)pushMediaPage:(UIViewController *)page {
    if(!page||!self.navigationController)return;
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
    NSArray *capabilities=[self.source[@"capabilities"] isKindOfClass:NSArray.class]?self.source[@"capabilities"]:@[];
    NSString *emptySiteTitle=catalogName.length?@"选择站点":(!self.source?@"选择站点":(self.pendingProviderPickerAfterLoad?@"正在读取站点…":(self.loading?@"加载站点…":(!capabilities.count||[capabilities containsObject:@"providers"]||!self.client||self.sourceInvalidated?@"选择站点":@"无站点"))));
    NSString *siteTitle=directAPI?@"单站点资源":(providerTitle.length?providerTitle:emptySiteTitle);
    self.providerSelectButton.hidden=directAPI&&!self.homeMode;
    BOOL catalogSelector=catalogName.length>0;
    [self.providerSelectButton setTitle:[NSString stringWithFormat:@"%@%@",siteTitle,(directAPI||(!catalogSelector&&!self.source))?@"":@"  ▾"] forState:UIControlStateNormal];
    self.providerSelectButton.enabled=catalogSelector||(!directAPI&&self.source!=nil&&!(self.pendingProviderPickerAfterLoad&&self.loading));
    self.providerSelectButton.alpha=self.providerSelectButton.enabled?1.0:0.62;
    self.providerSelectButton.accessibilityLabel=directAPI?@"此资源为单站点接口":(providerTitle.length?[NSString stringWithFormat:@"内部站点：%@，点按切换",providerTitle]:@"选择内部站点");
    self.providerSelectButton.accessibilityHint=catalogSelector?@"打开此合集中的站点列表；只加载点选的站点":(self.pendingProviderPickerAfterLoad?@"正在准备并读取站点列表":(self.providers.count?@"打开当前影视资源的站点列表":@"点按后按需准备资源并读取站点列表"));
}
- (void)setBrowseControlsHidden:(BOOL)hidden {
    BOOL hasCategories=self.categories.arrangedSubviews.count>0&&[MediaHomeEnabledModules() containsObject:@"catalog"];
    self.selectionRow.hidden=NO;self.categoryScroll.hidden=!hasCategories;self.categoryScrollHeightConstraint.constant=hasCategories?40:0;self.readinessStageLabel.hidden=hidden||!self.readinessStageLabel.text.length;self.grid.hidden=hidden;self.moreButton.hidden=hidden||!self.hasMore;self.homeScroll.hidden=!hidden;self.homeTopImmersiveScrim.hidden=!hidden;
    self.homeSearchButton.hidden=!hidden;self.homeMenuButton.hidden=!hidden;self.floatingHomeSearchButton.hidden=!hidden;self.homeModeButton.hidden=NO;[self.homeModeButton setImage:[UIImage systemImageNamed:hidden?@"square.grid.2x2.fill":@"house.fill"] forState:UIControlStateNormal];self.homeModeButton.accessibilityIdentifier=hidden?@"media-home-browse-button":@"media-browser-home-button";self.homeModeButton.accessibilityLabel=hidden?@"打开影视库":@"返回首页";
    if(hidden){self.navigationItem.searchController=nil;self.search.active=NO;self.status.hidden=YES;self.resourceButton.hidden=YES;[self.spinner stopAnimating];}
    else{BOOL hasContent=self.items.count>0;self.status.hidden=!self.status.text.length||hasContent;self.resourceButton.hidden=self.loading||hasContent||!self.status.text.length;self.readinessStageLabel.hidden=!self.readinessStageLabel.text.length;if(self.loading&&!hasContent)[self.spinner startAnimating];else[self.spinner stopAnimating];}
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
    NSString *badgeText=nil;NSString *lowerSubtitle=subtitle.lowercaseString?:@"";if([lowerSubtitle containsString:@"vip"]||[subtitle containsString:@"会员"]||[subtitle containsString:@"付费"] )badgeText=@"VIP";else if([subtitle containsString:@"独播"])badgeText=@"独播";else if([subtitle containsString:@"更新至"]||[subtitle containsString:@"更新中"])badgeText=@"更新中";else if([subtitle containsString:@"完结"]||[subtitle containsString:@"全集"])badgeText=@"完结";if(badgeText.length){UILabel *badge=[UILabel new];badge.translatesAutoresizingMaskIntoConstraints=NO;badge.text=badgeText;badge.textColor=UIColor.whiteColor;badge.font=[UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];badge.textAlignment=NSTextAlignmentCenter;badge.backgroundColor=[HostAccent() colorWithAlphaComponent:.94];badge.layer.cornerRadius=8;badge.clipsToBounds=YES;badge.accessibilityLabel=[NSString stringWithFormat:@"影片标签：%@",badgeText];[image addSubview:badge];[NSLayoutConstraint activateConstraints:@[[badge.leadingAnchor constraintEqualToAnchor:image.leadingAnchor constant:8],[badge.topAnchor constraintEqualToAnchor:image.topAnchor constant:8],[badge.heightAnchor constraintGreaterThanOrEqualToConstant:20],[badge.widthAnchor constraintGreaterThanOrEqualToConstant:42]]];}
    if(imageURL.length)MediaLoadPosterWithRetry(imageURL,image,1);else if(symbol.length){UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:34 weight:UIFontWeightMedium];image.image=[UIImage systemImageNamed:symbol withConfiguration:config];image.contentMode=UIViewContentModeCenter;image.tintColor=HostAccent();}else{image.image=[UIImage systemImageNamed:@"film"];image.contentMode=UIViewContentModeCenter;image.tintColor=HostSecondaryText();}
    UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.text=title;name.textColor=HostText();name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];name.adjustsFontForContentSizeCategory=YES;name.numberOfLines=1;name.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:name];
    UILabel *detail=[UILabel new];detail.translatesAutoresizingMaskIntoConstraints=NO;detail.text=subtitle;detail.textColor=HostSecondaryText();detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];detail.adjustsFontForContentSizeCategory=YES;detail.numberOfLines=1;detail.lineBreakMode=NSLineBreakByTruncatingTail;[card addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[card.widthAnchor constraintEqualToConstant:MediaHomeCardWidth(self.view.bounds.size.width)],[card.heightAnchor constraintEqualToAnchor:card.widthAnchor multiplier:1.5 constant:54],[image.topAnchor constraintEqualToAnchor:card.topAnchor],[image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[image.heightAnchor constraintEqualToAnchor:card.widthAnchor multiplier:1.5],[name.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:7],[name.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],[name.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-8],[detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:3],[detail.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],[detail.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],[detail.bottomAnchor constraintLessThanOrEqualToAnchor:card.bottomAnchor constant:-6]]];
    [card addAction:[UIAction actionWithHandler:^(UIAction *event){if(action)action();}] forControlEvents:UIControlEventTouchUpInside];return card;
}
- (UIButton *)homeFeatureCardForItem:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    NSString *title=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"精选推荐";
    NSString *imageURL=[item[@"banner"] isKindOfClass:NSString.class]?item[@"banner"]:([item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"");
    NSString *remarks=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"";
    UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom];card.translatesAutoresizingMaskIntoConstraints=NO;HostStyleGlassCard(card,22);HostInstallPressFeedback(card);card.accessibilityIdentifier=@"media-home-feature";card.accessibilityLabel=[NSString stringWithFormat:@"精选影片 %@，%@",title,remarks];
    UIImageView *image=[UIImageView new];image.translatesAutoresizingMaskIntoConstraints=NO;image.contentMode=UIViewContentModeScaleAspectFill;image.clipsToBounds=YES;image.backgroundColor=HostNeutralSurface();[card addSubview:image];if(imageURL.length)MediaLoadPosterWithRetry(imageURL,image,1);else{image.image=[UIImage systemImageNamed:@"film"];image.contentMode=UIViewContentModeCenter;image.tintColor=HostSecondaryText();}
    UIView *scrim=[MediaHomePosterFade new];scrim.translatesAutoresizingMaskIntoConstraints=NO;[card addSubview:scrim];
    UILabel *eyebrow=[UILabel new];eyebrow.translatesAutoresizingMaskIntoConstraints=NO;NSMutableArray *metadata=[NSMutableArray array];for(NSString *key in @[@"year",@"area",@"type"]){id value=item[key];if([value isKindOfClass:NSString.class]&&[value length])[metadata addObject:value];}eyebrow.text=[metadata componentsJoinedByString:@" · "];eyebrow.textColor=HostSecondaryText();eyebrow.textAlignment=NSTextAlignmentCenter;eyebrow.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];eyebrow.adjustsFontForContentSizeCategory=YES;eyebrow.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:eyebrow];
    UILabel *name=[UILabel new];name.translatesAutoresizingMaskIntoConstraints=NO;name.text=title;name.textColor=HostText();name.textAlignment=NSTextAlignmentCenter;name.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];name.adjustsFontForContentSizeCategory=YES;name.numberOfLines=2;name.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:name];
    UILabel *detail=[UILabel new];detail.translatesAutoresizingMaskIntoConstraints=NO;detail.text=remarks.length?remarks:@"点按查看影片详情";detail.textColor=HostSecondaryText();detail.textAlignment=NSTextAlignmentCenter;detail.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];detail.adjustsFontForContentSizeCategory=YES;detail.numberOfLines=1;detail.lineBreakMode=NSLineBreakByTruncatingTail;[scrim addSubview:detail];
    [NSLayoutConstraint activateConstraints:@[[image.topAnchor constraintEqualToAnchor:card.topAnchor],[image.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[image.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[image.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],[scrim.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[scrim.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[scrim.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],[scrim.heightAnchor constraintGreaterThanOrEqualToConstant:112],[eyebrow.leadingAnchor constraintEqualToAnchor:scrim.leadingAnchor constant:16],[eyebrow.trailingAnchor constraintEqualToAnchor:scrim.trailingAnchor constant:-16],[eyebrow.topAnchor constraintEqualToAnchor:scrim.topAnchor constant:10],[name.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],[name.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],[name.topAnchor constraintEqualToAnchor:eyebrow.bottomAnchor constant:2],[detail.leadingAnchor constraintEqualToAnchor:eyebrow.leadingAnchor],[detail.trailingAnchor constraintEqualToAnchor:eyebrow.trailingAnchor],[detail.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],[detail.bottomAnchor constraintLessThanOrEqualToAnchor:scrim.bottomAnchor constant:-8]]];
    __weak typeof(self) weakSelf=self;[card addAction:[UIAction actionWithHandler:^(UIAction *event){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHomeRecommendation:item source:source provider:provider];}] forControlEvents:UIControlEventTouchUpInside];return card;
}
- (NSArray<NSDictionary *> *)homeGridItems {
    NSArray *items=nil;
    if(self.category.length||self.keyword.length)items=[self.items isKindOfClass:NSArray.class]?self.items:@[];
    else items=[self.homeResult[@"items"] isKindOfClass:NSArray.class]?self.homeResult[@"items"]:([self.items isKindOfClass:NSArray.class]?self.items:@[]);
    NSUInteger limit=MIN((NSUInteger)24,items.count);return limit?[items subarrayWithRange:NSMakeRange(0,limit)]:@[];
}
- (void)updateHomeGridLayout {
    if(!self.homeGrid)return;
    CGFloat width=CGRectGetWidth(self.homeGrid.bounds);if(width<=0)width=MAX(1,CGRectGetWidth(self.view.bounds)-32);self.homeGridLayoutWidth=width;
    NSInteger columns=MediaBrowserGridColumns();CGFloat spacing=10,cellWidth=floor((width-spacing*(columns-1))/columns);
    UIFont *name=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection];UIFont *kind=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:10] compatibleWithTraitCollection:self.traitCollection];
    CGFloat posterHeight=ceil(cellWidth*1.5),cellHeight=posterHeight+7+ceil(name.lineHeight)*2+2+ceil(kind.lineHeight)+3;NSUInteger count=[self homeGridItems].count,rows=count?(count+(NSUInteger)columns-1)/(NSUInteger)columns:0;
    UICollectionViewFlowLayout *layout=(UICollectionViewFlowLayout *)self.homeGrid.collectionViewLayout;layout.minimumInteritemSpacing=spacing;layout.minimumLineSpacing=18;layout.sectionInset=UIEdgeInsetsZero;self.homeGridHeightConstraint.constant=rows?rows*cellHeight+(rows-1)*layout.minimumLineSpacing:0;[layout invalidateLayout];self.homePosterVisibilityInitialized=NO;[self.homeGrid reloadData];
    NSArray *allItems=(self.category.length||self.keyword.length)?self.items:([self.homeResult[@"items"] isKindOfClass:NSArray.class]?self.homeResult[@"items"]:@[]);BOOL hasQuery=self.category.length>0||self.keyword.length>0;BOOL showMore=hasQuery?self.hasMore:allItems.count>[self homeGridItems].count;self.homeGridMoreButton.hidden=!showMore;NSString *title=hasQuery?(self.hasMore?@"打开影视库 · 还有更多影片":@"打开影视库"):[NSString stringWithFormat:@"查看全部 · %lu 部",(unsigned long)allItems.count];[self.homeGridMoreButton setTitle:title forState:UIControlStateNormal];
}
- (void)updateVisibleHomePosters {
    if(!self.homeMode||self.homeScroll.hidden){self.homePosterVisibilityInitialized=NO;return;}
    if(!self.homeGrid){[self loadVisibleHomeShelves];return;}
    CGFloat offset=self.homeScroll.contentOffset.y;if(self.homePosterVisibilityInitialized&&fabs(offset-self.lastHomePosterVisibilityOffset)<36){[self loadVisibleHomeShelves];return;}self.homePosterVisibilityInitialized=YES;self.lastHomePosterVisibilityOffset=offset;
    CGRect viewport=[self.homeScroll convertRect:self.homeScroll.bounds toView:self.view];
    for(MediaDiscoveryCell *cell in self.homeGrid.visibleCells){CGRect frame=[cell convertRect:cell.bounds toView:self.view];if(CGRectIntersectsRect(frame,viewport))[cell loadPosterIfNeeded];}
    [self loadVisibleHomeShelves];
}
- (void)addHomeFeatureGrid:(NSArray<NSDictionary *> *)items {
    if(!items.count){if(self.homeStatusLoading&&self.source)[self addHomeSkeletonModules];return;}
    NSArray<NSDictionary *> *bannerItems=[items subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)5,items.count))];
    MediaHomeCarouselView *banner=[MediaHomeCarouselView new];self.homeCarousel=banner;[banner configureWithItems:bannerItems];[banner.heightAnchor constraintEqualToConstant:208].active=YES;[self.homeStack addArrangedSubview:banner];
    __weak typeof(self) weakSelf=self;banner.onSelectItem=^(NSDictionary *item){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHomeRecommendation:item source:owner.source provider:owner.provider?:owner.homeResultProvider?:@""];};
    [self.homeStack addArrangedSubview:[self homeSectionHeader:@"热门推荐" actionTitle:@"全部 ›" selector:@selector(browseRecommendations)]];
    NSMutableArray<UIButton *> *popular=[NSMutableArray array];
    for(NSUInteger index=0;index<items.count&&popular.count<8;index++){
        NSDictionary *item=items[index];
        NSString *title=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"影视内容";
        NSString *subtitle=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"热门推荐";
        NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";
        UIButton *card=[self homeCardWithTitle:title subtitle:subtitle imageURL:poster symbol:nil action:^{MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHomeRecommendation:item source:owner.source provider:owner.provider?:owner.homeResultProvider?:@""];}];
        [popular addObject:card];
    }
    [self addHomeCards:popular emptyText:@"暂无热门推荐" identifier:@"popular"];
    [self.homeStack addArrangedSubview:[self homeSectionHeader:@"更多精选" actionTitle:@"打开影视库 ›" selector:@selector(browseRecommendations)]];
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];layout.minimumInteritemSpacing=10;layout.minimumLineSpacing=18;layout.sectionInset=UIEdgeInsetsZero;
    UICollectionView *grid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];grid.translatesAutoresizingMaskIntoConstraints=NO;grid.backgroundColor=UIColor.clearColor;grid.scrollEnabled=NO;grid.dataSource=self;grid.delegate=self;grid.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;grid.accessibilityIdentifier=@"media-home-discovery-grid";grid.isAccessibilityElement=NO;[grid registerClass:MediaDiscoveryCell.class forCellWithReuseIdentifier:@"media.discovery"];
    self.homeGrid=grid;self.homeGridHeightConstraint=[grid.heightAnchor constraintEqualToConstant:0];self.homeGridHeightConstraint.active=YES;[self.homeStack addArrangedSubview:grid];self.homeGridMoreButton=[self homeActionButton:@"查看全部" symbol:@"arrow.right" action:@selector(browseRecommendations) primary:NO];self.homeGridMoreButton.accessibilityIdentifier=@"media-home-discovery-view-all";[self.homeStack addArrangedSubview:self.homeGridMoreButton];[self updateHomeGridLayout];
}
- (UIView *)homeSkeletonBarWithWidth:(CGFloat)width height:(CGFloat)height {
    UIView *bar=[UIView new];bar.translatesAutoresizingMaskIntoConstraints=NO;bar.backgroundColor=HostRaisedSurface();bar.layer.cornerRadius=height/2;[NSLayoutConstraint activateConstraints:@[[bar.widthAnchor constraintEqualToConstant:width],[bar.heightAnchor constraintEqualToConstant:height]]];return bar;
}
- (UIButton *)homeSkeletonPosterCard {
    CGFloat width=MediaHomeCardWidth(self.view.bounds.size.width);UIButton *card=[UIButton buttonWithType:UIButtonTypeCustom];card.translatesAutoresizingMaskIntoConstraints=NO;card.backgroundColor=UIColor.clearColor;card.accessibilityElementsHidden=YES;
    UIView *poster=[UIView new];poster.translatesAutoresizingMaskIntoConstraints=NO;poster.backgroundColor=HostCard();poster.layer.cornerRadius=12;poster.clipsToBounds=YES;[card addSubview:poster];UIView *line1=[self homeSkeletonBarWithWidth:width*.68 height:9];UIView *line2=[self homeSkeletonBarWithWidth:width*.42 height:7];[card addSubview:line1];[card addSubview:line2];
    [NSLayoutConstraint activateConstraints:@[[card.widthAnchor constraintEqualToConstant:width],[card.heightAnchor constraintEqualToAnchor:card.widthAnchor multiplier:1.5 constant:54],[poster.topAnchor constraintEqualToAnchor:card.topAnchor],[poster.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],[poster.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],[poster.heightAnchor constraintEqualToAnchor:card.widthAnchor multiplier:1.5],[line1.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:8],[line1.topAnchor constraintEqualToAnchor:poster.bottomAnchor constant:10],[line2.leadingAnchor constraintEqualToAnchor:line1.leadingAnchor],[line2.topAnchor constraintEqualToAnchor:line1.bottomAnchor constant:7]]];return card;
}
- (void)addHomeSkeletonShelf:(NSString *)title identifier:(NSString *)identifier {
    [self.homeStack addArrangedSubview:[self homeSectionHeader:title actionTitle:@"" selector:nil]];UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.showsHorizontalScrollIndicator=NO;scroll.accessibilityIdentifier=[NSString stringWithFormat:@"media-home-skeleton-%@",identifier];UIStackView *row=[UIStackView new];row.translatesAutoresizingMaskIntoConstraints=NO;row.axis=UILayoutConstraintAxisHorizontal;row.spacing=10;for(NSUInteger index=0;index<4;index++)[row addArrangedSubview:[self homeSkeletonPosterCard]];[scroll addSubview:row];CGFloat width=MediaHomeCardWidth(self.view.bounds.size.width),height=width*1.5+54;
    [NSLayoutConstraint activateConstraints:@[[scroll.heightAnchor constraintEqualToConstant:height],[row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],[row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],[row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor]]];[self.homeStack addArrangedSubview:scroll];
}
- (void)addHomeSkeletonModules {
    UIView *banner=[UIView new];banner.translatesAutoresizingMaskIntoConstraints=NO;banner.backgroundColor=HostCard();banner.layer.cornerRadius=18;banner.accessibilityIdentifier=@"media-home-banner-skeleton";UIStackView *content=[UIStackView new];content.translatesAutoresizingMaskIntoConstraints=NO;content.axis=UILayoutConstraintAxisVertical;content.alignment=UIStackViewAlignmentLeading;content.spacing=10;UILabel *loading=[UILabel new];loading.text=@"正在加载首页内容";loading.textColor=HostSecondaryText();loading.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];[content addArrangedSubview:loading];[content addArrangedSubview:[self homeSkeletonBarWithWidth:172 height:18]];[content addArrangedSubview:[self homeSkeletonBarWithWidth:220 height:9]];[banner addSubview:content];[NSLayoutConstraint activateConstraints:@[[banner.heightAnchor constraintEqualToConstant:208],[content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:18],[content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-20]]];[self.homeStack addArrangedSubview:banner];
    [self addHomeSkeletonShelf:@"热门推荐" identifier:@"popular"];
    NSArray<NSDictionary *> *categories=self.homeCategories;NSUInteger limit=MIN((NSUInteger)4,categories.count);if(!limit)limit=4;NSArray *fallback=@[@"电视剧",@"电影",@"综艺",@"动漫"];
    for(NSUInteger index=0;index<limit;index++){NSString *title=index<categories.count?[categories[index][@"name"] description]:fallback[index];[self addHomeSkeletonShelf:title identifier:[NSString stringWithFormat:@"category-%lu",(unsigned long)index]];}
}
- (void)toggleHomeFavoriteItem:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    NSString *sourceID=[source[@"id"] description]?:@"",*providerID=provider?:@"",*itemID=[item[@"id"] description]?:@"";NSString *key=[NSString stringWithFormat:@"%lu:%@%lu:%@%lu:%@",(unsigned long)sourceID.length,sourceID,(unsigned long)providerID.length,providerID,(unsigned long)itemID.length,itemID];
    NSMutableDictionary *favorites=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"] mutableCopy]?:[NSMutableDictionary dictionary];if(favorites[key])[favorites removeObjectForKey:key];else favorites[key]=@{@"sourceID":sourceID,@"sourceName":source[@"name"]?:@"",@"provider":providerID,@"item":item?:@{}};[NSUserDefaults.standardUserDefaults setObject:favorites forKey:@"cctv.mediaFavorites.v1"];self.homeModuleCache=nil;[self refreshHomeModules];
}
- (BOOL)isHomePageVisible {
    if(!self.homeMode||!self.view.window||self.view.hidden||self.homeScroll.hidden)return NO;
    UIViewController *top=self.navigationController.topViewController;
    return top==self||top==self.parentViewController;
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {if(scrollView==self.homeScroll)[self saveHomeScrollOffset];}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {if(scrollView==self.homeScroll&&!decelerate)[self saveHomeScrollOffset];}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if(scrollView==self.homeScroll)[self updateVisibleHomePosters];
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
    NSString *shelfID=[NSString stringWithFormat:@"media-home-shelf-category-%@",identifier];UIScrollView *shelf=nil;for(UIView *view in self.homeStack.arrangedSubviews)if([view.accessibilityIdentifier isEqual:shelfID]&&[view isKindOfClass:UIScrollView.class]){shelf=(UIScrollView *)view;break;}if(!shelf){self.homeShelfQueueActive=NO;return;}
    CGRect shelfFrame=[shelf convertRect:shelf.bounds toView:self.homeScroll];CGFloat visibleTop=self.homeScroll.contentOffset.y,visibleBottom=visibleTop+CGRectGetHeight(self.homeScroll.bounds);if(CGRectGetMinY(shelfFrame)>visibleBottom+CGRectGetHeight(self.homeScroll.bounds)*0.8||CGRectGetMaxY(shelfFrame)<visibleTop-CGRectGetHeight(self.homeScroll.bounds)*0.25){self.homeShelfQueueActive=NO;return;}
    NSDictionary *arguments=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];BOOL stale=NO;
    id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:arguments maximumAge:6*3600 isStale:&stale];
    NSUInteger cachedCount=[cached isKindOfClass:NSDictionary.class]&&[cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0;
    [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_cache_decision" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":sourceID,@"provider_id":provider?:@"",@"category_index":@(index),@"cache_hit":@([cached isKindOfClass:NSDictionary.class]),@"cache_stale":@(stale),@"cached_item_count":@(cachedCount),@"refresh_skipped":@([cached isKindOfClass:NSDictionary.class]&&!stale)}];
    if(cached&&!stale){[self loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];return;}
    CFTimeInterval started=CACurrentMediaTime();__weak typeof(self) weakSelf=self;self.homeShelfQueueActive=YES;self.homeShelfRequestInFlight=YES;[self.homeCategoryLoadsInFlight addObject:identifier];self.activeMediaOperation=@"home_shelf";
    [self.client call:@"category" arguments:arguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner.homeCategoryLoadsInFlight removeObject:identifier];if(owner.homeShelfGeneration==generation){owner.homeShelfRequestInFlight=NO;if([owner.activeMediaOperation isEqualToString:@"home_shelf"])owner.activeMediaOperation=nil;}if(owner.generation!=generation||!owner.homeMode||![[owner.source[@"id"] description] isEqual:sourceID]||![(owner.provider?:@"") isEqual:provider]){NSString *reason=owner.generation!=generation?@"superseded_generation":(!owner.homeMode?@"home_mode_changed":(![[owner.source[@"id"] description] isEqual:sourceID]?@"source_changed":@"provider_changed"));[RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":reason}];return;}
        NSTimeInterval elapsed=MAX(0,CACurrentMediaTime()-started);
        if(!error&&[result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class]){
            NSMutableDictionary *normalized=[result mutableCopy];normalized[@"items"]=MediaBrowserDictionaryRows(result[@"items"],NULL);[[MediaMetadataCache shared] storeResult:normalized forSource:owner.source operation:@"category" arguments:arguments];
            [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"item_count":@(([result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class])?[result[@"items"] count]:0),@"elapsed_ms":@((NSInteger)(elapsed*1000))}];
            if(owner.isHomePageVisible)[owner refreshHomeModules];
        }else{
            [RuntimeDiagnostics.shared recordEvent:@"media_home_shelf_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":sourceID,@"category_index":@(index),@"elapsed_ms":@((NSInteger)(elapsed*1000)),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(150*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{MediaBrowserViewController *page=weakSelf;if(page)[page loadHomeShelves:categories index:index+1 generation:generation sourceID:sourceID provider:provider];});
    }];
}
- (void)addHomeCards:(NSArray<UIButton *> *)cards emptyText:(NSString *)emptyText identifier:(NSString *)identifier {
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.showsHorizontalScrollIndicator=NO;scroll.alwaysBounceHorizontal=YES;scroll.accessibilityIdentifier=[NSString stringWithFormat:@"media-home-shelf-%@",identifier?:@"items"];UIStackView *row=[UIStackView new];row.translatesAutoresizingMaskIntoConstraints=NO;row.axis=UILayoutConstraintAxisHorizontal;row.spacing=10;[scroll addSubview:row];
    CGFloat cardWidth=MediaHomeCardWidth(self.view.bounds.size.width);CGFloat posterShelfHeight=cardWidth*1.5+54;CGFloat shelfHeight=cards.count?posterShelfHeight:88;
    if(cards.count){for(UIButton *card in cards)[row addArrangedSubview:card];}
    else{UILabel *empty=[UILabel new];empty.translatesAutoresizingMaskIntoConstraints=NO;empty.accessibilityIdentifier=[scroll.accessibilityIdentifier stringByAppendingString:@"-empty"];empty.text=emptyText;empty.textColor=HostSecondaryText();empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];empty.adjustsFontForContentSizeCategory=YES;empty.numberOfLines=2;empty.backgroundColor=HostCard();empty.layer.cornerRadius=14;empty.clipsToBounds=YES;empty.textAlignment=NSTextAlignmentCenter;[row addArrangedSubview:empty];[NSLayoutConstraint activateConstraints:@[[empty.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],[empty.heightAnchor constraintEqualToConstant:shelfHeight]]];}
    [NSLayoutConstraint activateConstraints:@[[scroll.heightAnchor constraintEqualToConstant:shelfHeight],[row.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],[row.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],[row.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],[row.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],[row.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor]]];[self.homeStack addArrangedSubview:scroll];
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
    if(![enabled containsObject:@"catalog"])return;
    __weak typeof(self) weakSelf=self;NSString *provider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&provider];NSArray *categories=self.homeCategories.count?self.homeCategories:MediaBrowserDictionaryRows(home[@"categories"],NULL);NSUInteger shown=0;
    for(NSDictionary *category in categories){
        if(shown>=8)break;
        NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";NSString *name=[category[@"name"] isKindOfClass:NSString.class]?category[@"name"]:@"";if(!identifier.length||!name.length)continue;
        NSDictionary *arguments=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];id result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:arguments maximumAge:DBL_MAX isStale:NULL];NSArray *items=[result isKindOfClass:NSDictionary.class]?MediaBrowserDictionaryRows(result[@"items"],NULL):@[];
        NSMutableArray<UIButton *> *cards=[NSMutableArray array];
        for(NSUInteger itemIndex=0;itemIndex<items.count&&cards.count<8;itemIndex++){
            NSDictionary *item=items[itemIndex];
            NSString *title=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"影视内容";
            NSString *subtitle=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:name;
            NSString *poster=[item[@"poster"] isKindOfClass:NSString.class]?item[@"poster"]:@"";
            UIButton *card=[self homeCardWithTitle:title subtitle:subtitle imageURL:poster symbol:nil action:^{MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHomeRecommendation:item source:owner.source provider:provider];}];
            [cards addObject:card];
        }
        UIStackView *heading=(UIStackView *)[self homeSectionHeader:name actionTitle:@"" selector:nil];UIButton *all=[UIButton buttonWithType:UIButtonTypeSystem];[all setTitle:@"全部 ›" forState:UIControlStateNormal];all.accessibilityLabel=[NSString stringWithFormat:@"浏览全部%@",name];[all addAction:[UIAction actionWithHandler:^(UIAction *action){MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner showBrowse:YES];owner.category=identifier;owner.keyword=@"";owner.page=1;[owner loadListing:NO];}] forControlEvents:UIControlEventTouchUpInside];[heading addArrangedSubview:all];[self.homeStack addArrangedSubview:heading];
        [self addHomeCards:cards emptyText:@"滚动到此处自动加载" identifier:[NSString stringWithFormat:@"category-%@",identifier]];shown++;
    }
}
- (void)loadVisibleHomeShelves {
    if(!self.homeMode||self.homeScroll.hidden||self.loading||self.homeShelfRequestInFlight||self.homeShelfQueueActive||!self.source||!self.client||!self.homeCategories.count||!self.isHomePageVisible)return;
    NSString *provider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&provider];NSArray *categories=self.homeCategories.count?self.homeCategories:MediaBrowserDictionaryRows(home[@"categories"],NULL);NSUInteger limit=MIN((NSUInteger)8,categories.count);CGFloat visibleTop=self.homeScroll.contentOffset.y,visibleBottom=visibleTop+CGRectGetHeight(self.homeScroll.bounds);
    for(NSUInteger index=0;index<limit;index++){
        NSDictionary *category=categories[index];NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";if(!identifier.length||[self.homeCategoryLoadsInFlight containsObject:identifier])continue;
        NSString *shelfID=[NSString stringWithFormat:@"media-home-shelf-category-%@",identifier];UIScrollView *shelf=nil;for(UIView *view in self.homeStack.arrangedSubviews)if([view.accessibilityIdentifier isEqual:shelfID]&&[view isKindOfClass:UIScrollView.class]){shelf=(UIScrollView *)view;break;}if(!shelf)continue;
        CGRect shelfFrame=[shelf convertRect:shelf.bounds toView:self.homeScroll];if(CGRectGetMinY(shelfFrame)>visibleBottom+CGRectGetHeight(self.homeScroll.bounds)*0.8||CGRectGetMaxY(shelfFrame)<visibleTop-CGRectGetHeight(self.homeScroll.bounds)*0.25)continue;
        NSDictionary *arguments=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];BOOL stale=NO;id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:arguments maximumAge:6*3600 isStale:&stale];if(cached&&!stale)continue;
        self.homeShelfGeneration=self.generation;self.homeShelfQueueActive=YES;[self loadHomeShelves:categories index:index generation:self.generation sourceID:[self.source[@"id"] description]?:@"" provider:provider?:@""];return;
    }
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
    NSArray *categories=self.homeCategories.count?self.homeCategories:MediaBrowserDictionaryRows(home[@"categories"],NULL);
    NSMutableArray *signature=[NSMutableArray arrayWithObject:provider?:@""];NSUInteger count=0;
    for(NSDictionary *category in categories){if(count>=8)break;NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";NSString *name=[category[@"name"] isKindOfClass:NSString.class]?category[@"name"]:@"";if(!identifier.length||!name.length)continue;
        NSDictionary *args=[self arguments:@{@"categoryId":identifier,@"page":@1,@"filters":@{}}];
        id result=[[MediaMetadataCache shared] resultForSource:self.source operation:@"category" arguments:args maximumAge:24*3600 isStale:NULL];NSArray *items=[result isKindOfClass:NSDictionary.class]?MediaBrowserDictionaryRows(result[@"items"],NULL):@[];
        [signature addObject:@[identifier,name,[items subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)8,items.count))]]];count++;
    }
    return signature;
}
- (void)appendHomeModule:(NSString *)key signature:(id)signature build:(dispatch_block_t)build {
    if(!self.homeModuleCache)self.homeModuleCache=[NSMutableDictionary dictionary];
    NSArray *context=@[signature?:@[],self.source[@"id"]?:@"",self.provider?:@"",@(self.view.bounds.size.width),@(MediaBrowserGridColumns()),@(self.traitCollection.userInterfaceStyle),self.traitCollection.preferredContentSizeCategory?:@""];
    NSData *identity=[NSJSONSerialization isValidJSONObject:context]?[NSJSONSerialization dataWithJSONObject:context options:NSJSONWritingSortedKeys error:NULL]:nil;
    NSDictionary *cached=self.homeModuleCache[key];
    if(identity&&[cached[@"identity"] isEqual:identity]){
        for(UIView *view in cached[@"views"])[self.homeStack addArrangedSubview:view];
        if([key isEqual:@"feature"]){self.homeGrid=cached[@"grid"];self.homeGridHeightConstraint=cached[@"grid_height"];self.homeGridMoreButton=cached[@"grid_more"];self.homeGridLayoutWidth=0;[self updateHomeGridLayout];}
        return;
    }
    NSUInteger start=self.homeStack.arrangedSubviews.count;build();
    if(identity){NSMutableDictionary *record=[@{@"identity":identity,@"views":[self.homeStack.arrangedSubviews subarrayWithRange:NSMakeRange(start,self.homeStack.arrangedSubviews.count-start)]} mutableCopy];if([key isEqual:@"feature"]&&self.homeGrid){record[@"grid"]=self.homeGrid;if(self.homeGridHeightConstraint)record[@"grid_height"]=self.homeGridHeightConstraint;if(self.homeGridMoreButton)record[@"grid_more"]=self.homeGridMoreButton;}self.homeModuleCache[key]=record;}
    else[self.homeModuleCache removeObjectForKey:key];
}
- (void)rebuildHomeModulesNow {
    CFTimeInterval rebuildStarted=CACurrentMediaTime();NSUInteger coalesced=self.pendingHomeRefreshCount;self.pendingHomeRefreshCount=0;
    if(!self.homeStack)return;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_modules_rebuild_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"home_mode":@(self.homeMode),@"source_item_count":@(self.items.count),@"category_count":@(self.homeCategories.count)}];CGPoint previousOffset=self.homeScroll.contentOffset;BOOL preserveOffset=self.homeScroll.bounds.size.height>0;__weak typeof(self) weakSelf=self;self.homeGrid=nil;self.homeCarousel=nil;self.homeGridHeightConstraint=nil;self.homeGridMoreButton=nil;self.homeGridLayoutWidth=0;for(UIView *view in self.homeStack.arrangedSubviews.copy){if(view==self.homeStatusCard)continue;[self.homeStack removeArrangedSubview:view];[view removeFromSuperview];}[self updateHomeStatusCard];
    NSSet *enabled=MediaHomeEnabledModules();
    if(![enabled isEqual:self.cachedHomeModules]){[self.homeModuleCache removeAllObjects];self.cachedHomeModules=enabled;}
    if([enabled containsObject:@"recommendations"]){NSString *featuredProvider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&featuredProvider];NSArray *allFeatured=[home[@"items"] isKindOfClass:NSArray.class]?home[@"items"]:@[];NSArray *featured=allFeatured.count>24?[allFeatured subarrayWithRange:NSMakeRange(0,24)]:allFeatured;[self appendHomeModule:@"feature" signature:@[featured,featuredProvider?:@"",self.source?:@{},@(self.homeStatusLoading)] build:^{[self addHomeFeatureGrid:featured];}];}
    if([enabled containsObject:@"catalog"]){[self appendHomeModule:@"catalog" signature:[self homeCategoryModuleSignature] build:^{[self addHomeCategoryShelves:enabled];}];}
    if([enabled containsObject:@"recommendations"]){NSString *cachedProvider=@"";NSDictionary *home=[self cachedHomeResultForSelectedProvider:&cachedProvider];NSArray *recommendations=[home[@"items"] isKindOfClass:NSArray.class]?home[@"items"]:@[];NSString *sourceName=[self.source[@"name"] isKindOfClass:NSString.class]?self.source[@"name"]:@"影视来源";
        if(!recommendations.count){[self.homeStack addArrangedSubview:[self homeSectionHeader:@"影视推荐" actionTitle:self.source?@"打开影视库":@"导入资源" selector:self.source?@selector(browseRecommendations):@selector(openResources)]];UIButton *empty=[self homeActionButton:self.source?([NSString stringWithFormat:@"%@ · 进入影视库加载推荐",sourceName]):@"添加影视资源后浏览推荐" symbol:self.source?@"sparkles.tv":@"plus" action:self.source?@selector(browseRecommendations):@selector(openResources) primary:NO];empty.accessibilityIdentifier=@"media-home-recommendations-empty";[self.homeStack addArrangedSubview:empty];}}
    if([enabled containsObject:@"continue"]){[self appendHomeModule:@"continue" signature:MediaPlaybackStateStore.watchHistory build:^{NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *entry in MediaPlaybackStateStore.watchHistory){if([entry[@"completed"] boolValue]||[entry[@"position"] doubleValue]<=0)continue;NSDictionary *item=entry[@"item"]?:@{};NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",entry[@"episodeName"]?:@"继续观看",entry[@"sourceName"]?:@"本机记录"];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"继续观看" subtitle:subtitle imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHistoryEntry:entry];}]];if(cards.count>=10)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"继续观看" actionTitle:@"全部" selector:@selector(openHistory)]];[self addHomeCards:cards emptyText:@"还没有未看完的影片，开始播放后会显示在这里" identifier:@"continue"];
    }];}
    if([enabled containsObject:@"favorites"]){[self appendHomeModule:@"favorites" signature:[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{} build:^{NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"cctv.mediaFavorites.v1"]?:@{};NSArray *entries=[saved.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[a[@"item"][@"name"] description] localizedStandardCompare:[b[@"item"][@"name"] description]];}];NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *entry in entries){NSDictionary *item=entry[@"item"]?:@{};NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",entry[@"sourceName"]?:@"影视资源",entry[@"provider"]?:@"站点"];[cards addObject:[self homeCardWithTitle:item[@"name"]?:@"已收藏影片" subtitle:subtitle imageURL:item[@"poster"] symbol:nil action:^{[weakSelf openHomeFavorite:entry];}]];if(cards.count>=10)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"影视收藏" actionTitle:@"全部" selector:@selector(openFavorites)]];[self addHomeCards:cards emptyText:@"还没有收藏影片，打开影片详情后点按收藏" identifier:@"favorites"];
    }];}
    if([enabled containsObject:@"sources"]){NSMutableSet *pins=[MediaHomePinnedSources() mutableCopy];if(![NSUserDefaults.standardUserDefaults objectForKey:MediaHomePinnedSourcesDefaultsKey]&&self.sources.count){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];if(saved.length)[pins addObject:saved];else for(NSDictionary *source in [self.sources subarrayWithRange:NSMakeRange(0,MIN((NSUInteger)3,self.sources.count))])[pins addObject:source[@"id"]?:@""];[NSUserDefaults.standardUserDefaults setObject:pins.allObjects forKey:MediaHomePinnedSourcesDefaultsKey];}
        NSMutableArray *cards=[NSMutableArray array];for(NSDictionary *source in self.sources){NSString *sourceID=source[@"id"]?:@"";if(![pins containsObject:sourceID])continue;BOOL running=MediaSourceUsesNativeCatalogAPI(source)||[PyHost isRunningServiceIdentifier:sourceID];NSString *engine=source[@"engine"]?:@"影视资源";NSString *subtitle=running?([source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"可直接访问"):engine;[cards addObject:[self homeCardWithTitle:source[@"name"]?:@"影视来源" subtitle:subtitle imageURL:nil symbol:@"square.stack.3d.up" action:^{[weakSelf browsePinnedSource:source];}]];if(cards.count>=12)break;}
        [self.homeStack addArrangedSubview:[self homeSectionHeader:@"固定来源" actionTitle:@"管理" selector:@selector(openHomeConfiguration)]];[self addHomeCards:cards emptyText:self.sources.count?@"还没有固定来源，点按右上角配置首页添加":@"尚未导入影视资源。可先到资源页导入 Python、JavaScript 或 ZIP 影视包" identifier:@"sources"];
    }
    if(!enabled.count){UILabel *empty=[UILabel new];empty.text=@"首页模块已全部隐藏。使用“配置首页”选择要显示的内容。";empty.textColor=HostSecondaryText();empty.numberOfLines=0;empty.textAlignment=NSTextAlignmentCenter;empty.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];[self.homeStack addArrangedSubview:empty];}
    if(!self.sources.count){UIButton *import=[self homeActionButton:@"导入影视资源" symbol:@"plus" action:@selector(openResources) primary:NO];[self.homeStack addArrangedSubview:import];}
    if(preserveOffset){[self.homeScroll layoutIfNeeded];CGFloat minimum=-self.homeScroll.adjustedContentInset.top;CGFloat maximum=MAX(minimum,self.homeScroll.contentSize.height-self.homeScroll.bounds.size.height+self.homeScroll.adjustedContentInset.bottom);self.homeScroll.contentOffset=CGPointMake(previousOffset.x,MIN(MAX(previousOffset.y,minimum),maximum));}[self restoreHomeScrollOffsetIfNeeded];[self loadVisibleHomeShelves];[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_modules_rebuild_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"home_mode":@(self.homeMode),@"module_view_count":@(self.homeStack.arrangedSubviews.count),@"source_item_count":@(self.items.count),@"elapsed_us":@((NSInteger)(MAX(0,CACurrentMediaTime()-rebuildStarted)*1000000)),@"coalesced_requests":@(coalesced)}];
}
- (void)openGlobalSearchFromHome {[self openGlobalSearch];}
- (void)browseRecommendations {[self showBrowse:YES];}
- (void)pushMediaDetail:(MediaDetailViewController *)detail {
    if(!detail)return;
    __weak typeof(self) weakSelf=self;
    __weak MediaDetailViewController *weakDetail=detail;
    detail.onPlay=^(NSDictionary *result,NSDictionary *context){MediaDetailViewController *owner=weakDetail;if(owner)[owner showInlinePlaybackResult:result context:context];};
    detail.onReturnHome=^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner returnToHomeFromNavigation];[owner.navigationController popToViewController:owner animated:YES];};
    [self pushMediaPage:detail];
}
- (void)openHomeRecommendation:(NSDictionary *)item source:(NSDictionary *)source provider:(NSString *)provider {
    if(![item isKindOfClass:NSDictionary.class]||![source isKindOfClass:NSDictionary.class])return;
    if([self openMetadataSearchForItem:item])return;
    if(MediaSourceUsesNativeCatalogAPI(source)){MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];return;}
    self.pendingHomeDetail=@{@"item":item,@"source":source,@"provider":provider?:@""};self.pendingBrowseState=nil;[self activate:source keepingHome:YES];
}
- (void)browsePinnedSource:(NSDictionary *)source {self.pendingBrowseState=nil;self.provider=nil;self.nextHomeLoadTrigger=@"home_pinned_source";[self activate:source];}
- (void)openHomeConfiguration {
    MediaHomeConfigurationViewController *page=[MediaHomeConfigurationViewController new];page.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];__weak typeof(self) weakSelf=self;page.onChange=^{MediaBrowserViewController *owner=weakSelf;if(!owner)return;[owner.grid.collectionViewLayout invalidateLayout];[owner.grid reloadData];[owner updateHomeGridLayout];[owner refreshHomeModules];};UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];HostStyleNavigation(navigation);navigation.modalPresentationStyle=UIModalPresentationPageSheet;UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;}[self presentViewController:navigation animated:YES completion:nil];
}
- (void)openHomeFavorite:(NSDictionary *)entry {
    NSString *sourceID=entry[@"sourceID"]?:@"";NSDictionary *source=nil;for(NSDictionary *candidate in self.sources)if([candidate[@"id"] isEqual:sourceID]){source=candidate;break;}
    if(!source){[self showMessage:@"该收藏对应的影视资源已移除，请重新导入后打开" loading:NO];return;}NSDictionary *item=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};if([self openMetadataSearchForItem:item])return;NSString *provider=[entry[@"provider"] isKindOfClass:NSString.class]?entry[@"provider"]:@"";
    if(MediaSourceUsesNativeCatalogAPI(source)){MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider;detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];return;}
    self.pendingHomeDetail=@{@"item":item,@"source":source,@"provider":provider};self.pendingBrowseState=nil;[self activate:source keepingHome:YES];
}
- (void)openPendingHomeDetailForSource:(NSDictionary *)source provider:(NSString *)provider {
    NSDictionary *pending=self.pendingHomeDetail;if(![pending isKindOfClass:NSDictionary.class]||![[pending[@"source"][@"id"] description] isEqual:[source[@"id"] description]])return;
    NSDictionary *item=[pending[@"item"] isKindOfClass:NSDictionary.class]?pending[@"item"]:@{};self.pendingHomeDetail=nil;if([self openMetadataSearchForItem:item])return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];}
- (NSString *)stateKeyForSource:(NSDictionary *)source provider:(NSString *)provider {return [NSString stringWithFormat:@"%@|%@",source[@"id"]?:@"",provider?:@""];}
- (void)saveCurrentBrowseState {if(!self.source)return;if(!self.browseStates)self.browseStates=[NSMutableDictionary dictionary];NSString *key=[self stateKeyForSource:self.source provider:self.provider];NSString *keyword=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]&&[self.keyword isKindOfClass:NSString.class]?self.keyword:@"";if(keyword.length>256)keyword=[keyword substringToIndex:256];NSDictionary *filters=[self.selectedFilters isKindOfClass:NSDictionary.class]?self.selectedFilters:@{};self.browseStates[key]=@{@"keyword":keyword,@"category":self.category?:@"",@"filters":filters,@"provider":self.provider?:@"",@"page":@(MAX(1,MIN(100,self.page))),@"season":@(MAX(1,self.widgetSeason)),@"episode":@(MAX(1,self.widgetEpisode)),@"offset":@(MAX(0,self.grid.contentOffset.y)),@"savedAt":@(NSDate.date.timeIntervalSince1970)};while(self.browseStates.count>32){NSString *oldest=nil;double timestamp=DBL_MAX;for(NSString *candidate in self.browseStates){double value=[self.browseStates[candidate][@"savedAt"] doubleValue];if(value<timestamp){timestamp=value;oldest=candidate;}}if(!oldest)break;[self.browseStates removeObjectForKey:oldest];}[NSUserDefaults.standardUserDefaults setObject:self.browseStates forKey:@"media.browseStates.v1"];}
- (void)restorePendingBrowseState {NSDictionary *state=self.pendingBrowseState;self.pendingBrowseState=nil;if(!state)return;self.keyword=[NSUserDefaults.standardUserDefaults boolForKey:@"media.globalSearchHistoryEnabled.v1"]&&[state[@"keyword"] isKindOfClass:NSString.class]?state[@"keyword"]:@"";self.category=state[@"category"];self.selectedFilters=[state[@"filters"] isKindOfClass:NSDictionary.class]?[state[@"filters"] mutableCopy]:[NSMutableDictionary dictionary];self.pendingRestorePage=MAX(1,MIN(100,[state[@"page"] integerValue]));self.page=self.pendingRestorePage;self.widgetSeason=MAX(1,[state[@"season"] integerValue]);self.widgetEpisode=MAX(1,[state[@"episode"] integerValue]);self.pendingRestoreOffset=@([state[@"offset"] doubleValue]);self.search.searchBar.text=self.keyword;self.navigationItem.prompt=[self.source[@"protocol"] isEqual:@"widget-extractor"]?[NSString stringWithFormat:@"第 %ld 季 · 第 %ld 集",(long)self.widgetSeason,(long)self.widgetEpisode]:nil;for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:self.category];button.backgroundColor=selected?[HostAccent() colorWithAlphaComponent:0.23]:HostNeutralSurface();HostSetLayerBorderColor(button,selected?[HostAccent() colorWithAlphaComponent:0.42]:HostBorder());[button setTitleColor:selected?HostAccent():HostText() forState:UIControlStateNormal];}if(self.keyword.length||self.category.length){self.page=1;[self loadListing:NO];return;}self.pendingRestorePage=0;CGFloat offset=self.pendingRestoreOffset.doubleValue;self.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[self.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
- (void)openFavorites {
    MediaFavoritesViewController *page=[MediaFavoritesViewController new];__weak typeof(self) weakSelf=self;
     page.onSelect=^(NSDictionary *entry){MediaBrowserViewController *owner=weakSelf;if(!owner)return;NSDictionary *savedItem=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};if([owner openMetadataSearchForItem:savedItem])return;NSArray *available=owner.sourcesProvider?owner.sourcesProvider():owner.sources?:@[];NSString *sourceID=entry[@"sourceID"]?:@"";NSDictionary *source=nil;
        for(NSDictionary *candidate in available)if([candidate[@"id"] isEqual:sourceID]){source=candidate;break;}
        if(!source){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"影视资源不可用" message:@"该收藏对应的资源未启用或已移除。重新启用资源后即可继续播放。" preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[owner presentViewController:alert animated:YES completion:nil];return;}
        MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=entry[@"item"]?:@{};detail.source=source;detail.provider=entry[@"provider"]?:@"";detail.onPlay=owner.onPlay;detail.onPlaybackWillStart=owner.onPlaybackWillStart;[owner pushMediaDetail:detail];
    };
    [self pushMediaPage:page];
}
- (void)openHistory {
    MediaWatchHistoryViewController *page=[MediaWatchHistoryViewController new];__weak typeof(self) weakSelf=self;
    page.onSelect=^(NSDictionary *entry){MediaBrowserViewController *owner=weakSelf;if(owner)[owner openHistoryEntry:entry];};
    [self pushMediaPage:page];
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
    if([self openMetadataSearchForItem:item])return;
    id itemID=item[@"id"];if(![itemID isKindOfClass:NSString.class]&&![itemID isKindOfClass:NSNumber.class]){[self showMessage:@"观看记录缺少影片标识，无法重新打开详情" loading:NO];return;}
    MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.resumeEntry=entry;detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];
}
- (void)openResources {if(self.onResources)self.onResources();}
- (void)openGlobalSearch {
    [self openGlobalSearchForKeyword:nil excludingIndexSources:NO];
}
- (void)openGlobalSearchForKeyword:(NSString *)keyword excludingIndexSources:(BOOL)excludeIndexSources {
    MediaGlobalSearchViewController *page=[MediaGlobalSearchViewController new];NSArray *available=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];if(excludeIndexSources){NSMutableArray *playableSources=[NSMutableArray array];for(NSDictionary *source in available)if(![source[@"protocol"] isEqual:@"douban-index"])[playableSources addObject:source];available=playableSources.copy;}page.sources=available;page.initialKeyword=keyword;page.onActivateService=self.onActivateService;__weak typeof(self) weakSelf=self;
    page.onSelectResult=^(NSDictionary *item,NSDictionary *source,NSString *provider){MediaBrowserViewController *owner=weakSelf;if(!owner)return;if([owner openMetadataSearchForItem:item])return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=item;detail.source=source;detail.provider=provider?:@"";detail.onPlay=owner.onPlay;detail.onPlaybackWillStart=owner.onPlaybackWillStart;[owner pushMediaDetail:detail];};
    [self pushMediaPage:page];
}
- (BOOL)openMetadataSearchForItem:(NSDictionary *)item {
    NSString *identifier=[item[@"id"] isKindOfClass:NSString.class]?item[@"id"]:@"";if(![identifier hasPrefix:@"msearch:"])return NO;NSString *keyword=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"";if(!keyword.length){NSArray *parts=[identifier componentsSeparatedByString:@"###"];if(parts.count>1)keyword=parts[1];}keyword=[keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(!keyword.length){[self showMessage:@"豆瓣索引没有返回可搜索的片名" loading:NO];return YES;}NSArray *all=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];NSUInteger playableCount=0;for(NSDictionary *source in all)if(![source[@"protocol"] isEqual:@"douban-index"])playableCount++;if(!playableCount){[self showMessage:[NSString stringWithFormat:@"%@ 是片名索引，不提供视频流。请先导入一个点播源，再从此处搜索播放。",keyword] loading:NO];return YES;}[self openGlobalSearchForKeyword:keyword excludingIndexSources:YES];return YES;
}
- (void)presentPicker:(MediaSourcePicker *)picker {
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:picker];navigation.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;HostStyleNavigation(navigation);navigation.navigationBar.prefersLargeTitles=NO;navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    UISheetPresentationController *sheet=navigation.sheetPresentationController;if(sheet){sheet.detents=@[UISheetPresentationControllerDetent.mediumDetent,UISheetPresentationControllerDetent.largeDetent];sheet.prefersGrabberVisible=YES;sheet.preferredCornerRadius=24;sheet.prefersScrollingExpandsWhenScrolledToEdge=YES;}
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)loadSources {
    self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    if(!self.sources.count){self.source=nil;self.providers=@[];[self updateSelectionControls];[self refreshHomeModules];if(self.deferAutomaticLoading){self.homeLoadDeferred=YES;[self showMessage:[self selectedCatalog]?@"已选择资源合集 · 从右侧胶囊选择内部站点":@"尚未导入影视资源" loading:NO];}return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=nil;NSDictionary *catalog=[self selectedCatalog];
    if(catalog){NSString *catalogID=catalog[@"id"]?:@"";for(NSDictionary *source in self.sources){NSString *memberID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");if([source[@"id"] isEqual:saved]&&[memberID isEqual:catalogID]){selected=source;break;}}}
    else{selected=self.sources.firstObject;for(NSDictionary *source in self.sources)if([source[@"id"] isEqual:saved]){selected=source;break;}}
    if(catalog&&!selected){self.source=nil;self.providers=@[];self.provider=nil;self.homeLoadDeferred=YES;self.deferAutomaticLoading=YES;[self updateSelectionControls];[self refreshHomeModules];[self showMessage:@"已选择资源合集 · 从右侧胶囊选择内部站点" loading:NO];return;}
    self.source=selected;id savedHomeOffset=[NSUserDefaults.standardUserDefaults objectForKey:[self homeScrollOffsetKeyForSource:selected]];self.pendingHomeOffsetRestore=[savedHomeOffset respondsToSelector:@selector(doubleValue)]?savedHomeOffset:nil;[self updateSelectionControls];
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
    NSArray<NSDictionary *> *updated=self.sourcesProvider?self.sourcesProvider():@[];
    self.sources=updated;
    if(!updated.count){
        self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.source=nil;[self clearHomeResult];self.provider=nil;self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.moreButton.hidden=YES;[self.grid reloadData];[self updateSelectionControls];[self refreshHomeModules];
        for(UIView *view in self.categories.arrangedSubviews.copy){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
        if(self.homeMode&&[self selectedCatalog])[self showMessage:@"已选择资源合集 · 从右侧胶囊选择内部站点" loading:NO];
        return;
    }
    if(self.homeMode){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];for(NSDictionary *candidate in updated)if(saved.length&&[candidate[@"id"] isEqual:saved]&&![candidate[@"id"] isEqual:self.source[@"id"]]){self.generation++;[self.readiness cancel];[self.client cancel];self.readiness=nil;self.client=nil;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.loading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.source=candidate;[self clearHomeResult];self.provider=nil;self.providers=@[];self.items=@[];self.sourceInvalidated=NO;self.homeLoadDeferred=YES;[self.grid reloadData];[self updateSelectionControls];[self showMessage:@"影视来源已更新 · 点按加载首页" loading:NO];[self refreshHomeModules];return;}}
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:self.source[@"id"]]){BOOL changed=![(candidate[@"packageRoot"]?:@"") isEqual:(self.source[@"packageRoot"]?:@"")]||![(candidate[@"api"]?:@"") isEqual:(self.source[@"api"]?:@"")];self.source=candidate;if(self.homeMode){if(changed){self.generation++;[self.readiness cancel];[self.client cancel];self.client=nil;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.loading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.providers=@[];self.items=@[];self.homeCategories=@[];self.homeShelfGeneration=0;[self clearHomeResult];self.sourceInvalidated=NO;self.homeLoadDeferred=YES;[self showMessage:@"影视来源已更新 · 点按加载首页" loading:NO];} [self updateSelectionControls];[self refreshHomeModules];return;}if((self.sourceInvalidated||changed)&&MediaSourceUsesNativeCatalogAPI(candidate)){[self activate:candidate];return;}if((self.sourceInvalidated||changed)&&[PyHost isRunningServiceIdentifier:candidate[@"id"]]){[self activate:candidate];return;}if(changed)[self invalidateServiceIdentifier:candidate[@"id"]];[self updateSelectionControls];[self refreshHomeModules];return;}
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaSource"];NSDictionary *selected=updated.firstObject;
    NSString *selectedCatalogID=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaCatalogID"]?:@"";NSDictionary *savedCatalog=[self selectedCatalog];BOOL selectedCatalogMemberFound=NO;
    if(savedCatalog&&selectedCatalogID.length){for(NSDictionary *candidate in updated){NSString *memberID=[candidate[@"catalogID"] isKindOfClass:NSString.class]?candidate[@"catalogID"]:([candidate[@"tvboxCatalogID"] isKindOfClass:NSString.class]?candidate[@"tvboxCatalogID"]:@"");if([candidate[@"id"] isEqual:saved]&&[memberID isEqual:selectedCatalogID]){selectedCatalogMemberFound=YES;selected=candidate;break;}}}
    else if(selectedCatalogID.length){self.selectedCatalogID=@"";[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];selectedCatalogID=@"";}
    if(self.homeMode&&savedCatalog&&!selectedCatalogMemberFound){
        NSString *currentCatalogID=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");
        if(![currentCatalogID isEqual:selectedCatalogID]){self.generation++;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.readiness=nil;self.client=nil;self.source=nil;self.provider=nil;self.providers=@[];self.items=@[];self.homeCategories=@[];self.loading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self clearHomeResult];[self.grid reloadData];}
        self.homeLoadDeferred=YES;self.deferAutomaticLoading=YES;[self updateSelectionControls];[self showMessage:@"已选择资源合集 · 从右侧胶囊选择内部站点" loading:NO];[self refreshHomeModules];return;
    }
    for(NSDictionary *candidate in updated)if([candidate[@"id"] isEqual:saved]){selected=candidate;break;}
    if(self.homeMode){self.generation++;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.readiness=nil;self.client=nil;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.loading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.source=selected;[self clearHomeResult];self.provider=nil;self.providers=@[];self.homeLoadDeferred=YES;[self updateSelectionControls];[self showMessage:@"影视来源已更新 · 请到资源页手动加载首页" loading:NO];[self refreshHomeModules];}
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
    NSString *catalogID=[target[@"catalogID"] isKindOfClass:NSString.class]?target[@"catalogID"]:([target[@"tvboxCatalogID"] isKindOfClass:NSString.class]?target[@"tvboxCatalogID"]:@"");
    if(catalogID.length){self.selectedCatalogID=catalogID;[NSUserDefaults.standardUserDefaults setObject:catalogID forKey:@"selectedMediaCatalogID"];}else{self.selectedCatalogID=@"";[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];}
    [NSUserDefaults.standardUserDefaults setObject:targetID forKey:@"selectedMediaSource"];
    self.nextHomeLoadTrigger=@"resource_list_open";
    [self activate:target];
}
- (void)showMessage:(NSString *)message loading:(BOOL)loading {
    self.status.text=message?:@"";self.homeStatusLoading=loading;
    if(self.homeMode){self.status.hidden=YES;self.resourceButton.hidden=YES;[self.spinner stopAnimating];[self updateHomeStatusCard];return;}
    BOOL hasContent=self.items.count>0;self.status.hidden=!message.length||hasContent;self.resourceButton.hidden=loading||hasContent||!message.length;
    if(loading&&!hasContent)[self.spinner startAnimating];else[self.spinner stopAnimating];
}
- (void)chooseResource {
    NSArray<NSDictionary *> *catalogs=self.catalogsProvider?self.catalogsProvider():@[];
    self.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];
    if(!self.sources.count&&!catalogs.count){[self openResources];return;}
    NSMutableArray *choices=[NSMutableArray array];for(NSDictionary *source in self.sources){NSString *memberID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");if(memberID.length)continue;BOOL current=[source[@"id"] isEqual:self.source[@"id"]];NSString *engineValue=[source[@"engine"] isKindOfClass:NSString.class]?source[@"engine"]:@"";NSString *engine=engineValue.lowercaseString;NSString *scope=([engine containsString:@"python"]||[engine containsString:@"py"])?@"python":([engine containsString:@"node"])?@"node":([engine containsString:@"javascript"]||[engine isEqual:@"js"])?@"javascriptcore":@"other";NSString *scopeName=[scope isEqual:@"python"]?@"Python":([scope isEqual:@"node"]?@"Node.js":([scope isEqual:@"javascriptcore"]?@"JavaScriptCore":@"其他"));NSString *status=[source[@"status"] isKindOfClass:NSString.class]?source[@"status"]:@"已导入";NSString *name=[source[@"name"] isKindOfClass:NSString.class]?source[@"name"]:@"影视资源";NSString *url=[source[@"url"] isKindOfClass:NSString.class]?source[@"url"]:@"";NSString *subtitle=[NSString stringWithFormat:@"%@ · %@%@",scopeName,current?@"当前资源 · ":@"",status];[choices addObject:@{@"name":name,@"subtitle":subtitle,@"url":url,@"source":source,@"scope":scope,@"scopeName":scopeName,@"selected":@(current)}];}
    for(NSDictionary *catalog in catalogs){NSString *catalogID=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";if(!catalogID.length)continue;NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];NSUInteger usable=0;for(NSDictionary *site in sites)if([site[@"supported"] boolValue])usable++;for(NSDictionary *live in lives)if([live[@"supported"] boolValue])usable++;NSString *catalogName=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"资源合集";NSString *subtitle=[NSString stringWithFormat:@"一个资源站 · 按需选择 %lu 个内部站点/直播列表 · 点选后再加载",(unsigned long)usable];[choices addObject:@{@"name":catalogName,@"subtitle":subtitle,@"catalogID":catalogID,@"scope":@"catalog",@"scopeName":@"资源合集",@"selected":@([self.selectedCatalogID isEqual:catalogID])}];}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=@"选择影视资源或资源合集";picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner)return;NSString *catalogID=[choice[@"catalogID"] isKindOfClass:NSString.class]?choice[@"catalogID"]:@"";if(catalogID.length){NSDictionary *catalog=nil;NSArray *availableCatalogs=owner.catalogsProvider?owner.catalogsProvider():@[];for(NSDictionary *item in availableCatalogs)if([item[@"id"] isEqual:catalogID]){catalog=item;break;}if(catalog)[owner selectCatalogResource:catalog];return;}NSDictionary *source=choice[@"source"];if(source){NSString *memberID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");owner.selectedCatalogID=memberID;owner.deferAutomaticLoading=NO;owner.homeLoadDeferred=NO;if(memberID.length)[NSUserDefaults.standardUserDefaults setObject:memberID forKey:@"selectedMediaCatalogID"];else[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];owner.pendingProviderPickerAfterLoad=NO;owner.nextHomeLoadTrigger=@"resource_selector";if(owner.homeMode)[owner activate:source keepingHome:YES];else[owner activate:source];}};[self presentPicker:picker];
}
- (NSDictionary *)selectedCatalog {
    if(!self.selectedCatalogID.length){NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"selectedMediaCatalogID"];if(saved.length)self.selectedCatalogID=saved;}
    NSArray *catalogs=self.catalogsProvider?self.catalogsProvider():@[];for(NSDictionary *catalog in catalogs)if([catalog[@"id"] isEqual:self.selectedCatalogID])return catalog;return nil;
}
- (NSDictionary *)sourceForCatalogSite:(NSDictionary *)site catalog:(NSDictionary *)catalog {
    NSString *catalogID=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"",*key=[site[@"key"] isKindOfClass:NSString.class]?site[@"key"]:@"",*apiKind=[site[@"apiKind"] isKindOfClass:NSString.class]?site[@"apiKind"]:@"";
    if(!self.sources)self.sources=self.sourcesProvider?self.sourcesProvider():@[];
    NSString *nativeID=([apiKind isEqual:@"tvbox-api"]||[apiKind isEqual:@"maccms-api"]||[apiKind isEqual:@"douban-index"])?[NSString stringWithFormat:@"%@:%@:%@",apiKind,catalogID,key]:@"";
    for(NSDictionary *source in self.sources){if(nativeID.length&&[source[@"id"] isEqual:nativeID])return source;NSString *sourceCatalog=[source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:([source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:@"");if(![sourceCatalog isEqual:catalogID])continue;NSArray *siteKeys=[source[@"tvboxSiteKeys"] isKindOfClass:NSArray.class]?source[@"tvboxSiteKeys"]:@[];if([source[@"tvboxSiteKey"] isEqual:key]||[siteKeys containsObject:key])return source;}
    return nil;
}
- (void)selectCatalogResource:(NSDictionary *)catalog {
    NSString *identifier=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";if(!identifier.length)return;
    [self saveCurrentBrowseState];self.selectedCatalogID=identifier;[NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"selectedMediaCatalogID"];
    NSString *sourceCatalog=[self.source[@"catalogID"] isKindOfClass:NSString.class]?self.source[@"catalogID"]:([self.source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?self.source[@"tvboxCatalogID"]:@"");
    if(![sourceCatalog isEqual:identifier]){self.generation++;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.readiness=nil;self.client=nil;self.source=nil;self.provider=nil;self.providers=@[];self.loading=NO;self.homeStatusLoading=NO;self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;self.homeLoadDeferred=YES;self.items=@[];self.homeCategories=@[];self.category=nil;self.keyword=@"";self.selectedFilters=[NSMutableDictionary dictionary];[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaSource"];[self clearHomeResult];[self.grid reloadData];}
    self.deferAutomaticLoading=YES;[self updateSelectionControls];[self showMessage:[NSString stringWithFormat:@"已选择 %@ · 从二级胶囊选择内部站点",catalog[@"name"]?:@"资源合集"] loading:NO];
}
- (void)chooseCatalogProvider {
    NSDictionary *catalog=[self selectedCatalog];if(!catalog){self.selectedCatalogID=@"";[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];[self chooseProvider];return;}
    self.sources=self.sourcesProvider?self.sourcesProvider():self.sources?:@[];
    NSString *catalogID=catalog[@"id"]?:@"";NSArray *sites=[catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[];NSArray *lives=[catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[];NSMutableArray *choices=[NSMutableArray array];
    for(NSDictionary *site in sites){BOOL supported=[site[@"supported"] boolValue];NSDictionary *source=[self sourceForCatalogSite:site catalog:catalog];NSString *siteKey=site[@"key"]?:@"";BOOL current=source&&[source[@"id"] isEqual:self.source[@"id"]];NSString *status=[site[@"status"] isKindOfClass:NSString.class]?site[@"status"]:@"按需加载";if(source)status=@"已加入合集 · 点按切换";NSString *apiKind=site[@"apiKind"]?:@"";NSString *kindLabel=[apiKind isEqual:@"script"]?@"脚本站点":([apiKind isEqual:@"maccms-api"]?@"MacCMS 接口":([apiKind isEqual:@"douban-index"]?@"豆瓣影视索引":@"影视接口"));NSString *subtitle=[NSString stringWithFormat:@"%@ · %@",kindLabel,status];NSMutableDictionary *choice=[@{@"name":site[@"name"]?:@"未命名影视站点",@"subtitle":subtitle,@"site":site,@"catalogID":catalogID,@"siteKey":siteKey,@"scope":@"site",@"scopeName":@"影视站点",@"selected":@(current),@"supported":@(supported)} mutableCopy];if(source)choice[@"source"]=source;[choices addObject:choice];}
    for(NSDictionary *live in lives){if(![live[@"supported"] boolValue])continue;NSString *savedURL=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"tvboxLiveSelection.%@",catalogID]]?:@"";BOOL selected=[savedURL isEqual:live[@"url"]?:@""];[choices addObject:@{@"name":live[@"name"]?:@"直播列表",@"subtitle":@"直播列表 · 仅加载所选清单",@"live":live,@"catalogID":catalogID,@"scope":@"live",@"scopeName":@"直播列表",@"selected":@(selected)}];}
    if(!choices.count){[self showMessage:@"这个资源合集没有可用的内部站点" loading:NO];return;}
    MediaSourcePicker *picker=[[MediaSourcePicker alloc] initWithStyle:UITableViewStyleInsetGrouped];picker.screenTitle=[NSString stringWithFormat:@"%@ · 内部站点",catalog[@"name"]?:@"资源合集"];picker.choices=choices;__weak typeof(self) weakSelf=self;
    picker.onSelect=^(NSDictionary *choice){MediaBrowserViewController *owner=weakSelf;if(!owner)return;owner.selectedCatalogID=catalogID;[NSUserDefaults.standardUserDefaults setObject:catalogID forKey:@"selectedMediaCatalogID"];
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
    self.backgroundLoadInterrupted=self.loading||self.homeShelfRequestInFlight;
    [self.readiness cancelWithReason:@"app_backgrounded"];[self.client cancel];[self.configurationClient cancel];
    self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;
    self.resumeCancelledMediaRequestOnAppear=NO;
}
- (void)resumeAfterForeground {
    if(!self.foregroundCheckNeeded)return;
    self.foregroundCheckNeeded=NO;
    BOOL interrupted=self.backgroundLoadInterrupted;self.backgroundLoadInterrupted=NO;
    self.loading=NO;self.homeStatusLoading=NO;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;
    if(interrupted){if(self.homeMode)self.homeLoadDeferred=YES;[self showMessage:self.homeMode?(self.homeResult?@"已保留首页内容；需要更新请到资源页手动刷新":@"上次加载已暂停；请到资源页手动加载"):@"已保留当前内容；需要时手动刷新" loading:NO];}
    else [self updateHomeStatusCard];
}
- (void)checkCurrentService {
    if(self.restartInProgress||self.loading||!self.source)return;
    if(UIApplication.sharedApplication.applicationState==UIApplicationStateBackground){self.foregroundCheckNeeded=YES;return;}
    self.foregroundCheckNeeded=NO;if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"service_check";
    if(MediaSourceUsesNativeCatalogAPI(self.source)){if(self.client)[self loadHome];return;}
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
    BOOL sourceChanged=![[self.source[@"id"] description] isEqual:[source[@"id"] description]];
    NSString *catalogID=[source[@"catalogID"] isKindOfClass:NSString.class]?source[@"catalogID"]:([source[@"tvboxCatalogID"] isKindOfClass:NSString.class]?source[@"tvboxCatalogID"]:@"");
    self.selectedCatalogID=catalogID;if(catalogID.length)[NSUserDefaults.standardUserDefaults setObject:catalogID forKey:@"selectedMediaCatalogID"];else[NSUserDefaults.standardUserDefaults removeObjectForKey:@"selectedMediaCatalogID"];
    if([source[@"id"] isKindOfClass:NSString.class])[NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];
    if(keepingHome&&sourceChanged){[self saveHomeScrollOffset];self.pendingHomeOffsetRestore=nil;if(self.homeScroll)[self.homeScroll setContentOffset:CGPointMake(0,-self.homeScroll.adjustedContentInset.top) animated:NO];}
    if(!self.nextHomeLoadTrigger.length)self.nextHomeLoadTrigger=@"source_activation";
    self.deferAutomaticLoading=NO;self.homeLoadDeferred=NO;self.homeMode=keepingHome;self.title=keepingHome?@"":@"影视库";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;self.navigationItem.searchController=keepingHome?nil:self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;[self setBrowseControlsHidden:keepingHome];[self notifyDisplayModeChanged];
    if(self.pendingHomeDetail&&![self.pendingHomeDetail[@"source"][@"id"] isEqual:source[@"id"]])self.pendingHomeDetail=nil;
    self.sourceInvalidated=NO;self.serviceUnavailable=NO;self.capabilityReadinessRetryCount=0;[self saveCurrentBrowseState];self.generation++;NSUInteger generation=self.generation;self.diagnosticTraceID=NSUUID.UUID.UUIDString.lowercaseString;[self.readiness cancel];[self.client cancel];[self.configurationClient cancel];self.activeMediaOperation=nil;self.activeHomeRequestSourceID=nil;self.activeHomeRequestProviderID=nil;self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaRequestAppend=NO;self.resumeCancelledMediaRequestOnAppear=NO;self.cancelledMediaOperation=nil;self.cancelledMediaRequestWasAppend=NO;self.source=source;[self clearHomeResult];self.homeCategories=@[];self.homeShelfGeneration=0;NSString *preferredProvider=[NSUserDefaults.standardUserDefaults stringForKey:[NSString stringWithFormat:@"mediaProvider.%@",source[@"id"]]];self.provider=nil;self.pendingBrowseState=self.browseStates[[self stateKeyForSource:source provider:preferredProvider]]?:self.browseStates[[self stateKeyForSource:source provider:nil]];if(sourceChanged&&!self.pendingBrowseState)[self.grid setContentOffset:CGPointMake(0,-self.grid.adjustedContentInset.top) animated:NO];self.providers=@[];self.items=@[];self.category=nil;self.keyword=@"";self.page=1;self.loading=YES;self.moreButton.hidden=YES;[self.grid reloadData];
    [self updateSelectionControls];
    self.widgetSeason=1;self.widgetEpisode=1;BOOL widget=[source[@"protocol"] isEqual:@"widget-extractor"];self.navigationItem.prompt=widget?@"第 1 季 · 第 1 集 · 工具栏筛选可修改":nil;self.search.searchBar.placeholder=widget?@"输入完整剧名，筛选中选择季 / 集":@"搜索当前影视来源";
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    [NSUserDefaults.standardUserDefaults setObject:source[@"id"] forKey:@"selectedMediaSource"];
    if(MediaSourceUsesNativeCatalogAPI(source)){
        self.client=[[MediaAPIClient alloc] initWithTVBoxSource:source];NSMutableDictionary *saved=[source mutableCopy];BOOL doubanIndex=[source[@"protocol"] isEqual:@"douban-index"];saved[@"capabilities"]=doubanIndex?@[@"home",@"category",@"search"]:@[@"home",@"category",@"search",@"detail",@"play"];self.source=saved;self.provider=@"";self.providers=@[];self.readinessStageLabel.text=doubanIndex?@"豆瓣索引 · 仅提供影片信息，播放时跨点播源搜索":([source[@"protocol"] isEqual:@"maccms-api"]?@"MacCMS JSON/XML API · 按需连接，不启动插件运行时":@"TVBox JSON API · 不启动插件运行时");self.loading=NO;[self updateSelectionControls];[self loadHome];NSDictionary *resume=self.pendingHistoryEntry;if(resume&&[resume[@"sourceID"] isEqual:self.source[@"id"]]){self.pendingHistoryEntry=nil;[self openHistoryDetail:resume source:self.source provider:@""];}return;
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
    self.homeShelfRequestInFlight=NO;self.homeShelfQueueActive=NO;[self.homeCategoryLoadsInFlight removeAllObjects];self.activeMediaRequestAppend=NO;self.activeMediaOperation=@"home";
    self.activeHomeRequestSourceID=requestedSourceID;self.activeHomeRequestProviderID=requestedProvider;
    self.filters=@{};self.selectedFilters=[NSMutableDictionary dictionary];
    BOOL hasProviderDirectory=[self.source[@"capabilities"] containsObject:@"providers"];
    self.readinessStageLabel.text=hasProviderDirectory?@"站点目录已读取 · 正在加载影视内容":@"资源能力已读取 · 正在加载影视内容";
    if(hasProviderDirectory)[RuntimeDiagnostics.shared recordEvent:@"media_provider_list_readable" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":self.source[@"id"]?:@"",@"provider_count":@(self.providers.count)}];
    self.loading=YES;[self updateSelectionControls];self.keyword=@"";self.category=nil;self.page=1;self.hasMore=NO;self.moreButton.hidden=YES;self.items=@[];[self.grid reloadData];[self showMessage:@"正在加载推荐与分类…" loading:YES];if(self.homeMode)[self refreshHomeModules];
    NSDictionary *requestArguments=[self arguments:@{}];BOOL cacheStale=NO;id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:@"home" arguments:requestArguments maximumAge:6*3600 isStale:&cacheStale];NSUInteger cachedItemCount=[cached isKindOfClass:NSDictionary.class]&&[cached[@"items"] isKindOfClass:NSArray.class]?[cached[@"items"] count]:0;CFTimeInterval requestStartedAt=CACurrentMediaTime();[RuntimeDiagnostics.shared recordEvent:@"media_home_request_started" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"generation":@(generation),@"trigger":trigger,@"home_mode":@(self.homeMode),@"automatic_load_deferred":@(self.deferAutomaticLoading||self.homeLoadDeferred),@"port":self.source[@"port"]?:@0,@"cache_hit":@([cached isKindOfClass:NSDictionary.class]),@"cache_stale":@(cacheStale),@"cached_item_count":@(cachedItemCount)}];
    if([cached isKindOfClass:NSDictionary.class]){[self applyHomeResult:cached];if(self.homeMode){[self refreshHomeModules];[self showMessage:cacheStale?@"正在更新 · 暂用缓存推荐":@"正在校验 · 显示上次推荐" loading:YES];}else[self showMessage:cacheStale?@"正在更新 · 暂用缓存推荐":@"正在校验 · 显示上次推荐" loading:YES];}
    __weak typeof(self) weakSelf=self;
    [self.client call:@"home" arguments:requestArguments correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;BOOL sameSource=[[owner.source[@"id"] description] isEqual:requestedSourceID];BOOL sameProvider=[(owner.provider?:@"") isEqual:requestedProvider];BOOL stillCurrentOperation=[owner.activeMediaOperation isEqualToString:@"home"];if(owner.generation!=generation||!sameSource||!sameProvider||!stillCurrentOperation){NSString *reason=owner.generation!=generation?@"superseded_generation":(!sameSource?@"source_changed":(!sameProvider?@"provider_changed":@"superseded_operation"));[RuntimeDiagnostics.shared recordEvent:@"media_home_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider":requestedProvider,@"generation":@(generation),@"current_generation":@(owner.generation),@"current_service_id":[owner.source[@"id"] description]?:@"",@"current_provider":owner.provider?:@"",@"current_operation":owner.activeMediaOperation?:@"",@"reason":reason}];return;}owner.activeMediaOperation=nil;owner.activeHomeRequestSourceID=nil;owner.activeHomeRequestProviderID=nil;owner.loading=NO;[owner updateSelectionControls];NSTimeInterval responseElapsed=MAX(0,CACurrentMediaTime()-requestStartedAt);[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil&&[result isKindOfClass:NSDictionary.class] elapsed:responseElapsed];[RuntimeDiagnostics.shared recordEvent:@"media_home_response_received" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider":requestedProvider,@"generation":@(generation),@"elapsed_ms":@((NSInteger)(responseElapsed*1000)),@"item_count":@(([result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class])?[result[@"items"] count]:0),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];
        if(error||![result isKindOfClass:NSDictionary.class]){NSString *message=error.localizedDescription?:@"资源返回的首页数据格式无法识别";owner.readinessStageLabel.text=owner.items.count?@"内容接口失败 · 当前仍显示缓存内容":@"内容接口读取失败";[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存内容 · 更新失败：%@",message]:message loading:NO];[RuntimeDiagnostics.shared recordEvent:@"media_home_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"failure_stage":error?@"request_error":@"invalid_result_shape",@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":message}];return;}
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
    if(![result isKindOfClass:NSDictionary.class]){self.homeResult=nil;self.items=@[];self.homeCategories=@[];[self.grid reloadData];[self.homeGrid reloadData];[self showMessage:@"首页数据格式无法识别，请重试或检查资源日志" loading:NO];return;}
    NSUInteger discardedItems=0;NSMutableDictionary *normalized=[result mutableCopy];NSArray *incoming=MediaBrowserDictionaryRows(result[@"items"],&discardedItems);NSArray *incomingCategories=MediaBrowserDictionaryRows(result[@"categories"],NULL);normalized[@"items"]=incoming;normalized[@"categories"]=incomingCategories;if(![normalized[@"filters"] isKindOfClass:NSDictionary.class])normalized[@"filters"]=@{};result=normalized;
    NSUInteger renderSerial=++self.diagnosticGridApplySerial;self.diagnosticGridConfiguredSerial=0;self.diagnosticGridVisibleSerial=0;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_data_apply_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"render_serial":@(renderSerial),@"item_count":@(incoming.count),@"category_count":@(incomingCategories.count),@"discarded_item_count":@(discardedItems),@"home_mode":@(self.homeMode)}];
    self.homeResult=[result isKindOfClass:NSDictionary.class]?[result copy]:nil;self.homeResultSourceID=[self.source[@"id"] isKindOfClass:NSString.class]?self.source[@"id"]:@"";self.homeResultProvider=self.provider?:@"";
    self.items=[result[@"items"] isKindOfClass:NSArray.class]?result[@"items"]:@[];[self.grid reloadData];
    self.homeCategories=[result[@"categories"] isKindOfClass:NSArray.class]?result[@"categories"]:@[];
    self.filters=[result[@"filters"] isKindOfClass:NSDictionary.class]?result[@"filters"]:@{};
    for(UIView *view in self.categories.arrangedSubviews){[self.categories removeArrangedSubview:view];[view removeFromSuperview];}
    NSMutableArray<NSDictionary *> *validCategories=[NSMutableArray array];for(NSDictionary *category in incomingCategories){if(![category isKindOfClass:NSDictionary.class])continue;NSString *identifier=[category[@"id"] isKindOfClass:NSString.class]?category[@"id"]:@"";NSString *name=[category[@"name"] isKindOfClass:NSString.class]?category[@"name"]:@"";if(identifier.length&&name.length)[validCategories addObject:category];}
    self.homeCategories=validCategories;
    UIButton *featured=[UIButton buttonWithType:UIButtonTypeSystem];featured.accessibilityIdentifier=@"__featured__";featured.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];featured.contentEdgeInsets=UIEdgeInsetsMake(7,14,7,14);[featured setTitle:@"精选" forState:UIControlStateNormal];[featured addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[self.categories addArrangedSubview:featured];
    for(NSDictionary *category in validCategories){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:category[@"name"] forState:UIControlStateNormal];button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];button.contentEdgeInsets=UIEdgeInsetsMake(7,14,7,14);button.accessibilityIdentifier=[category[@"id"] description];button.accessibilityLabel=[NSString stringWithFormat:@"影视分类：%@",category[@"name"]];[button addTarget:self action:@selector(selectCategory:) forControlEvents:UIControlEventTouchUpInside];[self.categories addArrangedSubview:button];}
    BOOL hasCategories=self.categories.arrangedSubviews.count>0&&[MediaHomeEnabledModules() containsObject:@"catalog"];self.categoryScrollHeightConstraint.constant=hasCategories?40:0;self.categoryScroll.hidden=!hasCategories;
    for(UIButton *button in self.categories.arrangedSubviews){BOOL selected=[button.accessibilityIdentifier isEqual:@"__featured__"]?!self.category.length:[button.accessibilityIdentifier isEqual:self.category];HostStylePillButton(button,selected);[button setTitleColor:selected?HostOnAccent():HostSecondaryText() forState:UIControlStateNormal];if(selected){button.backgroundColor=HostAccent();HostSetLayerBorderColor(button,HostAccent());}}
    [self.homeGrid reloadData];[self updateHomeGridLayout];
    [RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_home_data_apply_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"source_generation":@(self.generation),@"render_serial":@(renderSerial),@"item_count":@(self.items.count),@"category_count":@(self.homeCategories.count),@"home_mode":@(self.homeMode)}];
}
- (void)selectCategory:(UIButton *)button {
    NSString *identifier=button.accessibilityIdentifier?:@"";BOOL featured=[identifier isEqual:@"__featured__"];
    if(!featured&&[identifier isEqual:self.category]&&!self.keyword.length)return;
    if(self.loading&&(self.activeMediaOperation.length)){self.generation++;[self.client cancel];self.loading=NO;self.activeMediaOperation=nil;[self updateSelectionControls];}
    self.selectedFilters=[NSMutableDictionary dictionary];self.keyword=@"";self.search.searchBar.text=@"";self.page=1;self.hasMore=NO;self.category=featured?nil:identifier;
    for(UIButton *item in self.categories.arrangedSubviews){BOOL selected=item==button;HostStylePillButton(item,selected);item.backgroundColor=selected?HostAccent():HostNeutralSurface();HostSetLayerBorderColor(item,selected?HostAccent():HostBorder());[item setTitleColor:selected?HostOnAccent():HostSecondaryText() forState:UIControlStateNormal];}
    if(featured){if(!self.homeMode)[self showHome:YES];NSArray *homeItems=[self.homeResult[@"items"] isKindOfClass:NSArray.class]?self.homeResult[@"items"]:@[];self.items=homeItems;[self.grid reloadData];[self updateHomeGridLayout];[self showMessage:homeItems.count?@"":@"当前来源暂无精选内容，请选择其他类型或到资源页刷新" loading:NO];return;}
    self.items=@[];[self.grid reloadData];[self updateHomeGridLayout];if(self.source&&!self.loading)[self loadListing:NO];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *keyword=[searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.keyword=keyword;
    NSUInteger generation=++self.searchGeneration;__weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{MediaBrowserViewController *owner=weakSelf;if(!owner || owner.searchGeneration!=generation || !owner.source || owner.loading)return;owner.page=1;if(keyword.length)[owner loadListing:NO];else if(!owner.category.length){owner.nextHomeLoadTrigger=@"search_reset";[owner loadHome];}});
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
    if(!append){id cached=[[MediaMetadataCache shared] resultForSource:self.source operation:operation arguments:args maximumAge:6*3600 isStale:&cacheStale];if([cached isKindOfClass:NSDictionary.class]){hadCachedResult=YES;self.items=MediaBrowserDictionaryRows(cached[@"items"],NULL);cachedItemCount=self.items.count;self.hasMore=MediaBrowserBoolean(cached[@"hasMore"]);self.moreButton.hidden=!self.hasMore;[self.grid reloadData];[self updateHomeGridLayout];[self showMessage:cacheStale?@"正在更新 · 暂用缓存结果":@"正在校验 · 显示上次结果" loading:YES];}}
    if(!append&&!hadCachedResult){self.items=@[];[self.grid reloadData];[self updateHomeGridLayout];[self showMessage:@"正在加载…" loading:YES];}self.moreButton.enabled=NO;
    CFTimeInterval requestStartedAt=CACurrentMediaTime();[RuntimeDiagnostics.shared recordEvent:@"media_listing_request_started" category:@"media_api" fields:@{@"correlation_id":self.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"request_generation":@(generation),@"page":@(requestedPage),@"append":@(append),@"cache_hit":@(hadCachedResult),@"cache_stale":@(cacheStale),@"cached_item_count":@(cachedItemCount),@"search_term_length":@(requestedKeyword.length),@"has_category":@(requestedCategory.length>0),@"filter_count":@(requestedFilters.count)}];__weak typeof(self) weakSelf=self;
    [self.client call:operation arguments:args correlationID:self.diagnosticTraceID completion:^(id result,NSError *error){
        MediaBrowserViewController *owner=weakSelf;if(!owner)return;if(owner.generation!=generation||![[owner.source[@"id"] description] isEqual:requestedSourceID]||![(owner.provider?:@"") isEqual:requestedProvider]){[RuntimeDiagnostics.shared recordEvent:@"media_listing_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"request_generation":@(generation),@"current_generation":@(owner.generation),@"reason":owner.generation!=generation?@"superseded_generation":(![[owner.source[@"id"] description] isEqual:requestedSourceID]?@"source_changed":@"provider_changed")}];return;}if([owner.activeMediaOperation isEqualToString:operation])owner.activeMediaOperation=nil;owner.activeMediaRequestAppend=NO;owner.loading=NO;[owner updateSelectionControls];owner.moreButton.enabled=YES;BOOL validResultShape=[result isKindOfClass:NSDictionary.class]&&[result[@"items"] isKindOfClass:NSArray.class];[MediaSourceHealthStore.shared recordSourceID:requestedSourceID success:error==nil&&validResultShape elapsed:MAX(0,CACurrentMediaTime()-requestStartedAt)];
        if(episode!=owner.widgetEpisode || season!=owner.widgetSeason || ![requestedKeyword isEqualToString:owner.keyword?:@""] || (!requestedKeyword.length && (![requestedCategory isEqualToString:owner.category?:@""] || ![requestedFilters isEqual:owner.selectedFilters?:@{}]))){[RuntimeDiagnostics.shared recordEvent:@"media_listing_response_discarded" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"operation":operation,@"request_generation":@(generation),@"requested_page":@(requestedPage),@"current_page":@(owner.page),@"reason":@"search_category_or_filter_changed"}];owner.page=1;[owner loadListing:NO];return;}
        NSInteger elapsedMS=(NSInteger)(MAX(0,CACurrentMediaTime()-requestStartedAt)*1000);
        if(error||![result isKindOfClass:NSDictionary.class]||![result[@"items"] isKindOfClass:NSArray.class]){NSString *message=error.localizedDescription?:@"资源返回的数据格式不完整";[RuntimeDiagnostics.shared recordEvent:@"media_listing_failed" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"page":@(requestedPage),@"append":@(append),@"elapsed_ms":@(elapsedMS),@"retained_cached_items":@(owner.items.count),@"failure_stage":error?@"request_error":@"invalid_result_shape",@"error_domain":error.domain?:@"",@"error_code":@(error.code),@"error_message":message}];owner.readinessStageLabel.text=owner.items.count?@"更新失败 · 当前仍显示可用影视内容":@"影视内容接口读取失败";[owner updateHomeGridLayout];if(append)owner.page=MAX(1,owner.page-1);[owner showMessage:owner.items.count?[NSString stringWithFormat:@"显示缓存结果 · 更新失败：%@",message]:message loading:NO];return;}
        NSUInteger discardedRows=0;NSArray *incoming=MediaBrowserDictionaryRows(result[@"items"],&discardedRows);NSMutableDictionary *normalized=[result mutableCopy];normalized[@"items"]=incoming;if(![normalized[@"hasMore"] isKindOfClass:NSNumber.class])normalized[@"hasMore"]=@(MediaBrowserBoolean(normalized[@"hasMore"]));
        if(!append)[[MediaMetadataCache shared] storeResult:normalized forSource:owner.source operation:operation arguments:args];
        NSMutableArray *all=append?[owner.items mutableCopy]:[NSMutableArray array];NSMutableSet<NSString *> *identities=[NSMutableSet set];for(id rawItem in all)if([rawItem isKindOfClass:NSDictionary.class]){NSString *identity=MediaBrowserItemIdentity(rawItem);if(identity.length)[identities addObject:identity];}for(NSDictionary *item in incoming){NSString *identity=MediaBrowserItemIdentity(item);if(!identity.length||![identities containsObject:identity]){[all addObject:item];if(identity.length)[identities addObject:identity];}}
        owner.items=all;owner.readinessStageLabel.text=@"影视内容接口已读取 · 实际播放需以视频首帧确认";[RuntimeDiagnostics.shared recordEvent:@"media_content_readable" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":owner.source[@"id"]?:@"",@"content_count":@(all.count),@"operation":operation}];[RuntimeDiagnostics.shared recordEvent:@"media_listing_result_applied" category:@"media_api" fields:@{@"correlation_id":owner.diagnosticTraceID?:@"",@"service_id":requestedSourceID,@"provider_id":requestedProvider,@"operation":operation,@"page":@(requestedPage),@"append":@(append),@"incoming_count":@(incoming.count),@"discarded_row_count":@(discardedRows),@"displayed_count":@(all.count),@"has_more":@(MediaBrowserBoolean(normalized[@"hasMore"])),@"elapsed_ms":@(elapsedMS)}];if(owner.pendingRestorePage>requestedPage && MediaBrowserBoolean(normalized[@"hasMore"]) && incoming.count && requestedPage<owner.pendingRestorePage){owner.page=requestedPage+1;[owner loadListing:YES];return;}if(owner.pendingRestorePage){owner.page=requestedPage;owner.pendingRestorePage=0;}owner.hasMore=MediaBrowserBoolean(normalized[@"hasMore"]);owner.moreButton.hidden=!owner.hasMore;[owner.grid reloadData];[owner updateHomeGridLayout];[owner showMessage:all.count?@"":@"没有找到影片，请更换关键词或分类" loading:NO];
        if(owner.pendingRestoreOffset){CGFloat offset=owner.pendingRestoreOffset.doubleValue;owner.pendingRestoreOffset=nil;dispatch_async(dispatch_get_main_queue(),^{[owner.grid setContentOffset:CGPointMake(0,offset) animated:NO];});}
    }];
}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {return collectionView==self.homeGrid?[self homeGridItems].count:self.items.count;}
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat available=collectionView.bounds.size.width;BOOL home=collectionView==self.homeGrid;NSInteger columns=home?MediaBrowserGridColumns():3;CGFloat spacing=10;CGFloat width=floor((available-(home?0:28)-(columns-1)*spacing)/columns);
    if(home){UIFont *name=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection],*kind=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:10] compatibleWithTraitCollection:self.traitCollection];return CGSizeMake(width,ceil(width*1.5)+7+ceil(name.lineHeight)*2+2+ceil(kind.lineHeight)+3);}
    UIFont *name=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold] compatibleWithTraitCollection:self.traitCollection],*remarks=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11] compatibleWithTraitCollection:self.traitCollection];return CGSizeMake(width,width*1.43+8+ceil(name.lineHeight)*2+ceil(remarks.lineHeight)+1);
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    if(collectionView==self.homeGrid){
        NSArray<NSDictionary *> *items=[self homeGridItems];
        MediaDiscoveryCell *cell=(MediaDiscoveryCell *)[collectionView dequeueReusableCellWithReuseIdentifier:@"media.discovery" forIndexPath:ip];
        if(ip.item>=items.count){[cell configureWithItem:@{}];return cell;}
        NSDictionary *item=items[ip.item];NSMutableDictionary *display=[item mutableCopy];NSString *status=[item[@"remarks"] isKindOfClass:NSString.class]?item[@"remarks"]:@"";NSString *itemID=[item[@"id"] description]?:@"";
        for(NSDictionary *entry in MediaPlaybackStateStore.watchHistory){NSDictionary *historyItem=[entry[@"item"] isKindOfClass:NSDictionary.class]?entry[@"item"]:@{};if([entry[@"sourceID"] isEqual:[self.source[@"id"] description]]&&[entry[@"provider"] isEqual:self.provider?:@""]&&[[historyItem[@"id"] description] isEqual:itemID]&&![entry[@"completed"] boolValue]){NSString *episode=[entry[@"episodeName"] isKindOfClass:NSString.class]?entry[@"episodeName"]:@"";status=episode.length?[NSString stringWithFormat:@"继续 · %@",episode]:@"继续观看";break;}}
        display[@"__homePosterStatus"]=status.length?status:@"点按查看";[cell configureWithItem:display];cell.accessibilityIdentifier=[NSString stringWithFormat:@"media-home-card-%@",itemID.length?itemID:[NSString stringWithFormat:@"%ld",(long)ip.item]];
        return cell;
    }
    MediaPosterCell *cell=(MediaPosterCell *)[collectionView dequeueReusableCellWithReuseIdentifier:@"movie" forIndexPath:ip];
    BOOL firstCellForRender=self.diagnosticGridConfiguredSerial!=self.diagnosticGridApplySerial;if(firstCellForRender){self.diagnosticGridConfiguredSerial=self.diagnosticGridApplySerial;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_cell_configuration_started" fields:@{@"service_id":self.source[@"id"]?:@"",@"render_serial":@(self.diagnosticGridApplySerial),@"item_index":@(ip.item),@"item_count":@(self.items.count)}];}
    [cell configureWithItem:self.items[ip.item]];
    if(firstCellForRender)[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_cell_configuration_completed" fields:@{@"service_id":self.source[@"id"]?:@"",@"render_serial":@(self.diagnosticGridApplySerial),@"item_index":@(ip.item),@"item_count":@(self.items.count)}];
    return cell;
}
- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if(collectionView==self.homeGrid){[(MediaDiscoveryCell *)cell loadPosterIfNeeded];NSString *state=[NSString stringWithFormat:@"%@|%@|%@|%lu",[self.source[@"id"] description]?:@"",self.provider?:@"",self.category?:@"featured",(unsigned long)[self homeGridItems].count];if(![state isEqual:self.homeDiscoveryVisibleStateKey]){self.homeDiscoveryVisibleStateKey=state;[RuntimeDiagnostics.shared recordEvent:@"media_home_discovery_first_card_displayed" category:@"media_api" fields:@{@"service_id":self.source[@"id"]?:@"",@"item_index":@(indexPath.item),@"item_count":@([self homeGridItems].count),@"category_selected":@(self.category.length>0)}];}return;}
    if(self.diagnosticGridVisibleSerial==self.diagnosticGridApplySerial)return;self.diagnosticGridVisibleSerial=self.diagnosticGridApplySerial;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_first_cell_will_display" fields:@{@"service_id":self.source[@"id"]?:@"",@"render_serial":@(self.diagnosticGridApplySerial),@"item_index":@(indexPath.item),@"item_count":@(self.items.count),@"home_mode":@(self.homeMode)}];
}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    HostAnimateSelection([collectionView cellForItemAtIndexPath:ip]);
    if(collectionView==self.homeGrid){NSArray<NSDictionary *> *items=[self homeGridItems];if(ip.item<items.count)[self openHomeRecommendation:items[ip.item] source:self.source provider:self.provider?:self.homeResultProvider?:@""];return;}
    NSDictionary *selectedItem=self.items[ip.item];if([self openMetadataSearchForItem:selectedItem])return;MediaDetailViewController *detail=[MediaDetailViewController new];detail.item=selectedItem;detail.source=self.source;detail.provider=self.provider;detail.onPlay=self.onPlay;detail.onPlaybackWillStart=self.onPlaybackWillStart;[self pushMediaDetail:detail];
}
@end
