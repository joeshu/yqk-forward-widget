#import "MediaFeedView.h"
#import "HostTheme.h"
#import "HostImageLoader.h"
#import "RuntimeDiagnostics.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static NSString *MediaFeedString(id value) { return [value isKindOfClass:NSString.class]?value:@""; }
static NSArray *MediaFeedItems(NSDictionary *section) { return [section[@"items"] isKindOfClass:NSArray.class]?section[@"items"]:@[]; }
static void MediaFeedLoadPosterWithRetry(NSString *url, UIImageView *imageView, NSUInteger retriesRemaining) {
    if(!url.length||!imageView)return;
    __weak UIImageView *weakImageView=imageView;
    [HostImageLoader.shared loadPosterURL:url intoImageView:imageView completion:^(BOOL succeeded,NSTimeInterval retryAfter){
        if(succeeded||!retriesRemaining||retryAfter<=0)return;
        NSTimeInterval delay=MIN(120.0,MAX(1.0,retryAfter+0.25));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            UIImageView *current=weakImageView;
            if(!current||!current.window||![current.accessibilityIdentifier isEqualToString:url])return;
            MediaFeedLoadPosterWithRetry(url,current,retriesRemaining-1);
        });
    }];
}

@interface MediaFeedPosterCell : UICollectionViewCell
@property(nonatomic,strong) UIImageView *poster;
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UILabel *badgeLabel;
@property(nonatomic,strong) CAGradientLayer *posterScrim;
- (void)configureItem:(NSDictionary *)item;
@end
@implementation MediaFeedPosterCell
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.poster=[UIImageView new];self.poster.contentMode=UIViewContentModeScaleAspectFill;self.poster.clipsToBounds=YES;self.poster.backgroundColor=HostNeutralSurface();self.poster.layer.cornerRadius=14;self.poster.layer.cornerCurve=kCACornerCurveContinuous;self.poster.layer.borderWidth=0.6;HostSetLayerBorderColor(self.poster,HostBorder());self.poster.layer.drawsAsynchronously=YES;[self.contentView addSubview:self.poster];
        self.nameLabel=[UILabel new];self.nameLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.nameLabel.adjustsFontForContentSizeCategory=YES;self.nameLabel.textColor=HostText();self.nameLabel.numberOfLines=2;self.nameLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.nameLabel];
        self.detailLabel=[UILabel new];self.detailLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.detailLabel.adjustsFontForContentSizeCategory=YES;self.detailLabel.textColor=HostSecondaryText();self.detailLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self.contentView addSubview:self.detailLabel];
        self.posterScrim=[CAGradientLayer layer];self.posterScrim.colors=@[(id)UIColor.clearColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:0.52].CGColor];self.posterScrim.locations=@[@0.0,@1.0];[self.poster.layer addSublayer:self.posterScrim];
        self.badgeLabel=[UILabel new];self.badgeLabel.font=HostMonospacedDigitFont(10,UIFontWeightSemibold,UIFontTextStyleCaption2);self.badgeLabel.textColor=UIColor.whiteColor;self.badgeLabel.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:.68];self.badgeLabel.textAlignment=NSTextAlignmentCenter;self.badgeLabel.layer.cornerRadius=8;self.badgeLabel.layer.cornerCurve=kCACornerCurveContinuous;self.badgeLabel.layer.borderWidth=0.5;self.badgeLabel.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;self.badgeLabel.clipsToBounds=YES;[self.poster addSubview:self.badgeLabel];
        self.isAccessibilityElement=YES;self.accessibilityTraits=UIAccessibilityTraitButton;
    }return self;
}
- (void)prepareForReuse {[super prepareForReuse];self.transform=CGAffineTransformIdentity;self.poster.accessibilityIdentifier=nil;self.poster.image=nil;self.nameLabel.text=nil;self.detailLabel.text=nil;self.badgeLabel.text=nil;self.accessibilityLabel=nil;self.accessibilityIdentifier=nil;}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if(UIAccessibilityIsReduceMotionEnabled())return;
    [UIView animateWithDuration:highlighted?0.10:0.26 delay:0 usingSpringWithDamping:0.74 initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform=highlighted?CGAffineTransformMakeScale(0.965,0.965):CGAffineTransformIdentity;
        self.poster.alpha=highlighted?0.92:1.0;
    } completion:nil];
}
- (void)configureItem:(NSDictionary *)item {
    self.poster.backgroundColor=HostNeutralSurface();HostSetLayerBorderColor(self.poster,HostBorder());
    self.nameLabel.textColor=HostText();self.detailLabel.textColor=HostSecondaryText();
    BOOL directory=[item[@"directory"] boolValue];self.poster.accessibilityIdentifier=nil;self.poster.image=[UIImage systemImageNamed:directory?@"folder.fill":@"film"];self.poster.contentMode=UIViewContentModeCenter;self.poster.tintColor=HostSecondaryText();
    self.nameLabel.text=MediaFeedString(item[@"name"]).length?item[@"name"]:@"影片";
    NSString *remarks=MediaFeedString(item[@"remarks"]),*subtitle=MediaFeedString(item[@"feedSubtitle"]);
    NSString *badgeText=remarks;
    if([remarks containsString:@" · "]&&!subtitle.length){NSArray<NSString *> *parts=[remarks componentsSeparatedByString:@" · "];badgeText=parts.firstObject?:remarks;subtitle=[[parts subarrayWithRange:NSMakeRange(1,parts.count-1)] componentsJoinedByString:@" · "];}
    NSString *candidateDetail=subtitle.length?subtitle:(MediaFeedString(item[@"type"]).length?item[@"type"]:(MediaFeedString(item[@"year"]).length?item[@"year"]:MediaFeedString(item[@"area"])));
    if([candidateDetail isEqualToString:badgeText])candidateDetail=@"";
    self.detailLabel.text=candidateDetail;self.detailLabel.hidden=!candidateDetail.length;
    self.badgeLabel.text=directory?@"文件夹":badgeText;self.badgeLabel.hidden=directory?NO:!badgeText.length;
    NSString *poster=MediaFeedString(item[@"poster"]);if(!directory&&poster.length)MediaFeedLoadPosterWithRetry(poster,self.poster,1);
    self.accessibilityLabel=[@[self.nameLabel.text?:@"",remarks,self.detailLabel.text?:@""] componentsJoinedByString:@"，"];self.accessibilityHint=directory?@"打开文件夹":@"打开影片详情";[self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];CGFloat width=CGRectGetWidth(self.contentView.bounds),height=CGRectGetHeight(self.contentView.bounds);CGFloat titleHeight=ceil(self.nameLabel.font.lineHeight)*2,detailHeight=ceil(self.detailLabel.font.lineHeight);CGFloat posterHeight=MIN(width*1.5,MAX(44,height-titleHeight-detailHeight-12));
    CGSize fittedName=[self.nameLabel sizeThatFits:CGSizeMake(MAX(0,width-2),titleHeight)];CGFloat actualTitleH=MIN(titleHeight,MAX(ceil(self.nameLabel.font.lineHeight),ceil(fittedName.height)));
    self.poster.frame=CGRectMake(0,0,width,posterHeight);[CATransaction begin];[CATransaction setDisableActions:YES];self.posterScrim.frame=CGRectMake(0,MAX(0,posterHeight-36),width,MIN(36,posterHeight));self.posterScrim.hidden=self.badgeLabel.hidden;[CATransaction commit];self.nameLabel.frame=CGRectMake(1,posterHeight+7,MAX(0,width-2),actualTitleH);self.detailLabel.frame=CGRectMake(1,posterHeight+9+actualTitleH,MAX(0,width-2),detailHeight);
    CGSize badge=[self.badgeLabel sizeThatFits:CGSizeMake(MAX(0,width-12),22)];CGFloat badgeWidth=MIN(MAX(0,width-12),badge.width+12);self.badgeLabel.frame=CGRectMake(MAX(6,width-badgeWidth-6),MAX(0,posterHeight-27),badgeWidth,21);
}
@end

@interface MediaFeedSkeletonCell : UICollectionViewCell
@property(nonatomic,strong) UIView *art;
@property(nonatomic,strong) UIView *line;
@property(nonatomic,strong) UIView *smallLine;
@end
@implementation MediaFeedSkeletonCell
- (instancetype)initWithFrame:(CGRect)frame {if((self=[super initWithFrame:frame])){self.art=[UIView new];self.line=[UIView new];self.smallLine=[UIView new];for(UIView *view in @[self.art,self.line,self.smallLine]){view.backgroundColor=HostNeutralSurface();view.layer.cornerRadius=view==self.art?14:4;view.layer.cornerCurve=kCACornerCurveContinuous;[self.contentView addSubview:view];}self.isAccessibilityElement=YES;self.accessibilityLabel=@"影片加载中";self.accessibilityIdentifier=@"media-feed-skeleton";}return self;}
- (void)layoutSubviews {[super layoutSubviews];for(UIView *view in @[self.art,self.line,self.smallLine])view.backgroundColor=HostNeutralSurface();CGFloat width=CGRectGetWidth(self.bounds),art=MIN(width*1.5,MAX(0,CGRectGetHeight(self.bounds)-46));self.art.frame=CGRectMake(0,0,width,art);self.line.frame=CGRectMake(1,art+9,width*.84,12);self.smallLine.frame=CGRectMake(1,art+29,width*.55,8);}
@end

@interface MediaFeedStatusCell : UICollectionViewCell
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UILabel *subtitleLabel;
@property(nonatomic,strong) UIButton *actionButton;
@property(nonatomic,copy) dispatch_block_t onAction;
- (void)configureSection:(NSDictionary *)section;
@end
@implementation MediaFeedStatusCell
- (instancetype)initWithFrame:(CGRect)frame {if((self=[super initWithFrame:frame])){
    HostStyleGlassCard(self.contentView,18);self.contentView.layer.borderWidth=0.6;HostSetLayerBorderColor(self.contentView,HostBorder());
    self.titleLabel=[UILabel new];self.titleLabel.textColor=HostText();self.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];self.titleLabel.adjustsFontForContentSizeCategory=YES;self.titleLabel.numberOfLines=0;
    self.subtitleLabel=[UILabel new];self.subtitleLabel.textColor=HostSecondaryText();self.subtitleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.subtitleLabel.adjustsFontForContentSizeCategory=YES;self.subtitleLabel.numberOfLines=0;
    self.actionButton=[UIButton buttonWithType:UIButtonTypeSystem];HostStylePillButton(self.actionButton,NO);self.actionButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.actionButton.titleLabel.adjustsFontForContentSizeCategory=YES;[self.actionButton addTarget:self action:@selector(performAction) forControlEvents:UIControlEventTouchUpInside];HostInstallPressFeedback(self.actionButton);
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel,self.subtitleLabel,self.actionButton]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=8;stack.translatesAutoresizingMaskIntoConstraints=NO;[self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],[stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],[stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],[stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],[self.actionButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
}return self;}
- (void)prepareForReuse {[super prepareForReuse];self.onAction=nil;}
- (void)configureSection:(NSDictionary *)section {HostStyleGlassCard(self.contentView,18);self.titleLabel.textColor=HostText();self.subtitleLabel.textColor=HostSecondaryText();HostStylePillButton(self.actionButton,NO);self.actionButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.actionButton.titleLabel.adjustsFontForContentSizeCategory=YES;self.titleLabel.text=MediaFeedString(section[@"title"]);self.subtitleLabel.text=MediaFeedString(section[@"subtitle"]);self.subtitleLabel.hidden=!self.subtitleLabel.text.length;NSString *action=MediaFeedString(section[@"actionTitle"]);[self.actionButton setTitle:action forState:UIControlStateNormal];self.actionButton.hidden=!action.length;self.accessibilityIdentifier=MediaFeedString(section[@"id"]);}
- (void)performAction {if(self.onAction)self.onAction();}
@end

@interface MediaFeedHeader : UICollectionReusableView
@property(nonatomic,strong) UIView *accentBar;
@property(nonatomic,strong) UILabel *titleLabel;
@property(nonatomic,strong) UIButton *actionButton;
@property(nonatomic,copy) dispatch_block_t onAction;
@end
@implementation MediaFeedHeader
- (instancetype)initWithFrame:(CGRect)frame {if((self=[super initWithFrame:frame])){self.accentBar=[UIView new];self.accentBar.backgroundColor=HostAccent();self.accentBar.layer.cornerRadius=1.75;self.accentBar.layer.cornerCurve=kCACornerCurveContinuous;[self addSubview:self.accentBar];self.titleLabel=[UILabel new];self.titleLabel.textColor=HostText();self.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];self.titleLabel.adjustsFontForContentSizeCategory=YES;self.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;[self addSubview:self.titleLabel];self.actionButton=[UIButton buttonWithType:UIButtonTypeSystem];self.actionButton.titleLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold]];self.actionButton.tintColor=HostSecondaryText();self.actionButton.titleLabel.adjustsFontForContentSizeCategory=YES;[self.actionButton addTarget:self action:@selector(performAction) forControlEvents:UIControlEventTouchUpInside];[self addSubview:self.actionButton];}return self;}
- (void)prepareForReuse {[super prepareForReuse];self.onAction=nil;self.titleLabel.text=nil;self.actionButton.hidden=YES;}
- (void)performAction {if(self.onAction)self.onAction();}
- (void)layoutSubviews {[super layoutSubviews];self.accentBar.backgroundColor=HostAccent();CGFloat width=CGRectGetWidth(self.bounds),height=CGRectGetHeight(self.bounds);self.accentBar.frame=CGRectMake(0,floor((height-16)/2),3.5,16);CGFloat actionWidth=self.actionButton.hidden?0:MAX(64,MIN(width*.4,[self.actionButton sizeThatFits:CGSizeMake(width*.4,height)].width+8));self.actionButton.frame=CGRectMake(width-actionWidth,0,actionWidth,MAX(44,height));self.titleLabel.frame=CGRectMake(10,0,MAX(0,width-actionWidth-18),height);}
@end

@interface MediaFeedHeroCell : UICollectionViewCell
@property(nonatomic,strong) UIImageView *poster;
@property(nonatomic,strong) CAGradientLayer *fade;
@property(nonatomic,strong) UILabel *heroBadgeLabel;
@property(nonatomic,strong) UILabel *playHintPill;
@property(nonatomic,strong) UILabel *nameLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UIPageControl *pages;
@property(nonatomic,copy) NSArray<NSDictionary *> *items;
@property(nonatomic) NSUInteger page;
@property(nonatomic) BOOL feedVisible;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) void (^onSelect)(NSDictionary *item);
- (void)configureItems:(NSArray *)items;
- (void)updateTimer;
- (BOOL)canAnimate;
@end
@implementation MediaFeedHeroCell
- (instancetype)initWithFrame:(CGRect)frame {if((self=[super initWithFrame:frame])){
    self.clipsToBounds=YES;self.contentView.backgroundColor=HostBackground();self.poster=[UIImageView new];self.poster.clipsToBounds=YES;self.poster.contentMode=UIViewContentModeScaleAspectFill;[self.contentView addSubview:self.poster];
    self.fade=[CAGradientLayer layer];self.fade.colors=@[(id)UIColor.clearColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:.3].CGColor,(id)HostBackground().CGColor];self.fade.locations=@[@0,@.35,@1];[self.contentView.layer addSublayer:self.fade];
    self.heroBadgeLabel=[UILabel new];self.heroBadgeLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightBold];self.heroBadgeLabel.textColor=HostOnAccent();self.heroBadgeLabel.backgroundColor=[HostAccent() colorWithAlphaComponent:0.88];self.heroBadgeLabel.textAlignment=NSTextAlignmentCenter;self.heroBadgeLabel.layer.cornerRadius=10;self.heroBadgeLabel.layer.cornerCurve=kCACornerCurveContinuous;self.heroBadgeLabel.clipsToBounds=YES;self.heroBadgeLabel.accessibilityIdentifier=@"media-hero-badge";[self.contentView addSubview:self.heroBadgeLabel];
    self.playHintPill=[UILabel new];self.playHintPill.text=@"▶︎ 立即观看";self.playHintPill.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];self.playHintPill.textColor=UIColor.whiteColor;self.playHintPill.backgroundColor=[UIColor colorWithWhite:1 alpha:0.18];self.playHintPill.textAlignment=NSTextAlignmentCenter;self.playHintPill.layer.cornerRadius=14;self.playHintPill.layer.cornerCurve=kCACornerCurveContinuous;self.playHintPill.layer.borderWidth=0.7;self.playHintPill.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.28].CGColor;self.playHintPill.clipsToBounds=YES;self.playHintPill.accessibilityIdentifier=@"media-hero-play-pill";[self.contentView addSubview:self.playHintPill];
    self.nameLabel=[UILabel new];self.nameLabel.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont systemFontOfSize:27 weight:UIFontWeightBold]];self.nameLabel.adjustsFontForContentSizeCategory=YES;self.nameLabel.textColor=UIColor.whiteColor;self.nameLabel.numberOfLines=2;self.nameLabel.layer.shadowColor=UIColor.blackColor.CGColor;self.nameLabel.layer.shadowOpacity=0.58;self.nameLabel.layer.shadowRadius=6.0;self.nameLabel.layer.shadowOffset=CGSizeMake(0,2);[self.contentView addSubview:self.nameLabel];
    self.detailLabel=[UILabel new];self.detailLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.detailLabel.adjustsFontForContentSizeCategory=YES;self.detailLabel.textColor=[UIColor.whiteColor colorWithAlphaComponent:.86];self.detailLabel.numberOfLines=1;self.detailLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.detailLabel.layer.shadowColor=UIColor.blackColor.CGColor;self.detailLabel.layer.shadowOpacity=0.48;self.detailLabel.layer.shadowRadius=4.0;self.detailLabel.layer.shadowOffset=CGSizeMake(0,1);[self.contentView addSubview:self.detailLabel];
    self.pages=[UIPageControl new];self.pages.currentPageIndicatorTintColor=HostAccent();self.pages.pageIndicatorTintColor=[UIColor.whiteColor colorWithAlphaComponent:.35];self.pages.hidesForSinglePage=YES;[self.pages addTarget:self action:@selector(pageChanged) forControlEvents:UIControlEventValueChanged];[self.contentView addSubview:self.pages];
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(selectCurrent)];[self.contentView addGestureRecognizer:tap];for(NSNumber *direction in @[@(UISwipeGestureRecognizerDirectionLeft),@(UISwipeGestureRecognizerDirectionRight)]){UISwipeGestureRecognizer *swipe=[[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(swiped:)];swipe.direction=direction.unsignedIntegerValue;[self.contentView addGestureRecognizer:swipe];}
    self.isAccessibilityElement=YES;self.accessibilityIdentifier=@"media-home-banner";self.accessibilityTraits=UIAccessibilityTraitButton;self.accessibilityCustomActions=@[[[UIAccessibilityCustomAction alloc] initWithName:@"下一部" target:self selector:@selector(accessibilityNext)],[[UIAccessibilityCustomAction alloc] initWithName:@"上一部" target:self selector:@selector(accessibilityPrevious)]];
    for(NSString *name in @[UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification,UIAccessibilityReduceMotionStatusDidChangeNotification,UIAccessibilityVoiceOverStatusDidChangeNotification])[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
}return self;}
- (void)dealloc {[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)prepareForReuse {[super prepareForReuse];self.feedVisible=NO;[self.timer invalidate];self.timer=nil;self.poster.accessibilityIdentifier=nil;self.poster.image=nil;self.onSelect=nil;self.items=@[];self.page=0;}
- (void)configureItems:(NSArray *)items {BOOL changed=![self.items isEqual:items];self.items=items?:@[];if(changed||self.page>=items.count)self.page=0;self.pages.numberOfPages=self.items.count;self.pages.currentPage=(NSInteger)self.page;[self displayCurrent:NO];[self updateTimer];}
- (void)setFeedVisible:(BOOL)feedVisible {_feedVisible=feedVisible;[self updateTimer];}
- (void)environmentChanged:(NSNotification *)notification {[self updateTimer];}
- (BOOL)canAnimate {
    if(!self.feedVisible||!self.window||self.items.count<2||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||UIAccessibilityIsReduceMotionEnabled()||UIAccessibilityIsVoiceOverRunning())return NO;
    for(UIView *view=self;view;view=view.superview)if(view.hidden||view.alpha<.01)return NO;
    return CGRectIntersectsRect([self convertRect:self.bounds toView:self.window],self.window.bounds);
}
- (void)updateTimer {
    BOOL active=[self canAnimate];
    if(!active){[self.timer invalidate];self.timer=nil;return;}if(self.timer)return;
    __weak typeof(self) weakSelf=self;self.timer=[NSTimer timerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer){MediaFeedHeroCell *owner=weakSelf;if(!owner)return;if(![owner canAnimate]){[owner updateTimer];return;}owner.page=(owner.page+1)%owner.items.count;[owner displayCurrent:YES];}];[NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)didMoveToWindow {[super didMoveToWindow];[self updateTimer];}
- (void)pageChanged {self.page=(NSUInteger)MAX(0,MIN(self.pages.currentPage,(NSInteger)self.items.count-1));[self displayCurrent:YES];}
- (void)swiped:(UISwipeGestureRecognizer *)swipe {if(self.items.count<2)return;self.page=(self.page+self.items.count+(swipe.direction==UISwipeGestureRecognizerDirectionLeft?1:-1))%self.items.count;[self displayCurrent:YES];}
- (void)selectCurrent {if(self.items.count&&self.onSelect)self.onSelect(self.items[self.page]);}
- (BOOL)accessibilityActivate {[self selectCurrent];return YES;}
- (BOOL)accessibilityNext {if(self.items.count<2)return NO;self.page=(self.page+1)%self.items.count;[self displayCurrent:NO];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.accessibilityLabel);return YES;}
- (BOOL)accessibilityPrevious {if(self.items.count<2)return NO;self.page=(self.page+self.items.count-1)%self.items.count;[self displayCurrent:NO];UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.accessibilityLabel);return YES;}
- (void)displayCurrent:(BOOL)animated {
    self.contentView.backgroundColor=HostBackground();
    self.fade.colors=@[(id)UIColor.clearColor.CGColor,(id)[UIColor colorWithWhite:0 alpha:.3].CGColor,(id)HostBackground().CGColor];
    self.heroBadgeLabel.textColor=HostOnAccent();
    self.heroBadgeLabel.backgroundColor=[HostAccent() colorWithAlphaComponent:0.88];
    self.pages.currentPageIndicatorTintColor=HostAccent();
    if(!self.items.count)return;NSDictionary *item=self.items[self.page];NSString *poster=MediaFeedString(item[@"banner"]);if(!poster.length)poster=MediaFeedString(item[@"poster"]);
    if(!poster.length||![self.poster.accessibilityIdentifier isEqualToString:poster]||!self.poster.image){
        self.poster.accessibilityIdentifier=nil;self.poster.image=nil;
        if(poster.length)MediaFeedLoadPosterWithRetry(poster,self.poster,1);else{self.poster.image=[UIImage systemImageNamed:@"film"];self.poster.tintColor=HostSecondaryText();}
    }
    void (^labels)(void)=^{self.nameLabel.text=MediaFeedString(item[@"name"]);NSString *remarks=MediaFeedString(item[@"remarks"]);NSString *heroSub=MediaFeedString(item[@"feedSubtitle"]);if(!heroSub.length||[heroSub isEqualToString:remarks]){NSMutableArray<NSString *> *meta=[NSMutableArray array];for(NSString *k in @[@"type",@"year",@"area"]){NSString *v=MediaFeedString(item[k]);if(v.length&&![v isEqualToString:remarks])[meta addObject:v];}heroSub=meta.count?[meta componentsJoinedByString:@" · "]:@"精选热播 · 点按查看详情";}self.detailLabel.text=heroSub;self.heroBadgeLabel.text=[NSString stringWithFormat:@"  %@  ",remarks.length?remarks:@"精选热播"];self.pages.currentPage=(NSInteger)self.page;self.accessibilityLabel=[NSString stringWithFormat:@"%@，%@，第 %lu 页，共 %lu 页",self.nameLabel.text,self.detailLabel.text,(unsigned long)self.page+1,(unsigned long)self.items.count];};
    if(animated&&!UIAccessibilityIsReduceMotionEnabled()){self.poster.transform=CGAffineTransformMakeScale(1.03,1.03);[UIView transitionWithView:self.contentView duration:.28 options:UIViewAnimationOptionTransitionCrossDissolve|UIViewAnimationOptionAllowAnimatedContent animations:^{labels();self.poster.transform=CGAffineTransformIdentity;} completion:nil];}else labels();[self setNeedsLayout];
}
- (void)layoutSubviews {[super layoutSubviews];CGFloat width=CGRectGetWidth(self.bounds),height=CGRectGetHeight(self.bounds);self.poster.frame=self.contentView.bounds;[CATransaction begin];[CATransaction setDisableActions:YES];self.fade.frame=CGRectMake(0,height*.30,width,height*.70);[CATransaction commit];self.pages.frame=CGRectMake(14,height-44,MAX(0,width-28),44);CGFloat detail=ceil(self.detailLabel.font.lineHeight);self.detailLabel.frame=CGRectMake(18,height-57-detail,MAX(0,width-124),detail);self.playHintPill.frame=CGRectMake(MAX(18,width-102),height-61-detail,84,28);CGFloat title=MIN(ceil(self.nameLabel.font.lineHeight)*2,MAX(0,height-120-detail));self.nameLabel.frame=CGRectMake(18,height-65-detail-title,MAX(0,width-36),title);CGSize badgeSize=[self.heroBadgeLabel sizeThatFits:CGSizeMake(width-36,22)];self.heroBadgeLabel.frame=CGRectMake(18,MAX(16,CGRectGetMinY(self.nameLabel.frame)-26),MIN(width-36,MAX(54,badgeSize.width+10)),20);}
@end

@interface MediaFeedView () <UICollectionViewDataSource,UICollectionViewDelegate>
@property(nonatomic,copy,readwrite) NSArray<NSDictionary *> *sections;
@property(nonatomic) CGFloat lastLayoutWidth;
@property(nonatomic,copy) NSArray<NSString *> *visibleCategoryIDs;
@property(nonatomic) BOOL categoryNotificationScheduled;
@property(nonatomic) CGFloat previousScrollOffset;
@property(nonatomic) NSUInteger renderSerial;
@property(nonatomic) NSUInteger configuredRenderSerial;
@property(nonatomic) NSUInteger visibleRenderSerial;
- (NSDictionary *)diagnosticFieldsForIndexPath:(NSIndexPath *)indexPath;
- (UICollectionViewCell *)configuredCellAtIndexPath:(NSIndexPath *)indexPath;
@end
@implementation MediaFeedView
- (instancetype)initWithFrame:(CGRect)frame {return [self initWithFrame:frame collectionViewLayout:[UICollectionViewFlowLayout new]];}
- (instancetype)initWithFrame:(CGRect)frame collectionViewLayout:(UICollectionViewLayout *)layout {
    if((self=[super initWithFrame:frame collectionViewLayout:layout])){
        self.sections=@[];self.backgroundColor=HostBackground();self.alwaysBounceVertical=YES;self.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;self.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;self.dataSource=self;self.delegate=self;self.accessibilityIdentifier=@"media-feed";
        [self registerClass:MediaFeedPosterCell.class forCellWithReuseIdentifier:@"feed.poster"];[self registerClass:MediaFeedHeroCell.class forCellWithReuseIdentifier:@"feed.hero"];[self registerClass:MediaFeedStatusCell.class forCellWithReuseIdentifier:@"feed.status"];[self registerClass:MediaFeedSkeletonCell.class forCellWithReuseIdentifier:@"feed.skeleton"];[self registerClass:MediaFeedHeader.class forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"feed.header"];
        __weak typeof(self) weakSelf=self;self.collectionViewLayout=[[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger index,id<NSCollectionLayoutEnvironment> environment){return [weakSelf layoutForSection:index environment:environment];}];
    }return self;
}
- (NSDictionary *)sectionAt:(NSInteger)section {return section>=0&&section<self.sections.count?self.sections[(NSUInteger)section]:@{};}
- (NSCollectionLayoutSection *)layoutForSection:(NSInteger)index environment:(id<NSCollectionLayoutEnvironment>)environment {
    NSDictionary *definition=[self sectionAt:index];NSString *kind=MediaFeedString(definition[@"kind"]);CGFloat width=environment.container.effectiveContentSize.width;BOOL large=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);NSCollectionLayoutSection *section;
    if([kind isEqual:@"hero"]){CGFloat titleHeight=ceil([[[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle1] scaledFontForFont:[UIFont systemFontOfSize:27 weight:UIFontWeightBold]] lineHeight])*2;CGFloat detailHeight=ceil([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].lineHeight);CGFloat textTop=[definition[@"heroTopInset"] respondsToSelector:@selector(doubleValue)]?[definition[@"heroTopInset"] doubleValue]:HostStatusBarSafeTop(self,self.safeAreaInsets.top)+100;CGFloat height=MAX(MAX(300,MIN(460,CGRectGetHeight(self.bounds)*.5)),textTop+titleHeight+detailHeight+72);NSCollectionLayoutSize *size=[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1] heightDimension:[NSCollectionLayoutDimension absoluteDimension:height]];NSCollectionLayoutItem *item=[NSCollectionLayoutItem itemWithLayoutSize:size];section=[NSCollectionLayoutSection sectionWithGroup:[NSCollectionLayoutGroup verticalGroupWithLayoutSize:size subitems:@[item]]];section.contentInsets=NSDirectionalEdgeInsetsMake(0,0,12,0);}
    else if([kind isEqual:@"status"]){NSCollectionLayoutSize *size=[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1] heightDimension:[NSCollectionLayoutDimension estimatedDimension:170]];NSCollectionLayoutItem *item=[NSCollectionLayoutItem itemWithLayoutSize:size];section=[NSCollectionLayoutSection sectionWithGroup:[NSCollectionLayoutGroup verticalGroupWithLayoutSize:size subitems:@[item]]];section.contentInsets=NSDirectionalEdgeInsetsMake(8,14,12,14);}
    else {
        BOOL grid=[kind isEqual:@"grid"];NSInteger columns=large?2:([NSUserDefaults.standardUserDefaults integerForKey:@"cctv.mediaGridColumns.v1"]==4?4:3);CGFloat cardWidth=grid?floor((width-28-(columns-1)*10)/columns):floor((width-28)/2.5);if(large&&!grid)cardWidth=floor((width-28)/1.6);cardWidth=MAX(44,cardWidth);
        CGFloat title=ceil([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].lineHeight)*2,detail=ceil([UIFont preferredFontForTextStyle:UIFontTextStyleCaption1].lineHeight);CGFloat height=ceil(cardWidth*1.5)+title+detail+12;
        NSCollectionLayoutSize *itemSize=[NSCollectionLayoutSize sizeWithWidthDimension:grid?[NSCollectionLayoutDimension fractionalWidthDimension:1.0/columns]:[NSCollectionLayoutDimension absoluteDimension:cardWidth] heightDimension:[NSCollectionLayoutDimension absoluteDimension:height]];NSCollectionLayoutItem *item=[NSCollectionLayoutItem itemWithLayoutSize:itemSize];
        NSCollectionLayoutSize *groupSize=[NSCollectionLayoutSize sizeWithWidthDimension:grid?[NSCollectionLayoutDimension fractionalWidthDimension:1]:[NSCollectionLayoutDimension absoluteDimension:cardWidth] heightDimension:[NSCollectionLayoutDimension absoluteDimension:height]];
        NSCollectionLayoutGroup *group=grid?[NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitem:item count:columns]:[NSCollectionLayoutGroup verticalGroupWithLayoutSize:groupSize subitems:@[item]];group.interItemSpacing=[NSCollectionLayoutSpacing fixedSpacing:10];section=[NSCollectionLayoutSection sectionWithGroup:group];section.interGroupSpacing=grid?16:10;section.contentInsets=NSDirectionalEdgeInsetsMake(0,14,22,14);if(!grid)section.orthogonalScrollingBehavior=UICollectionLayoutSectionOrthogonalScrollingBehaviorContinuous;
    }
    if(MediaFeedString(definition[@"title"]).length&&![kind isEqual:@"status"]&&![kind isEqual:@"hero"]){NSCollectionLayoutBoundarySupplementaryItem *header=[NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1] heightDimension:[NSCollectionLayoutDimension estimatedDimension:48]] elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];section.boundarySupplementaryItems=@[header];}
    return section;
}
- (void)reloadData {
    self.renderSerial++;
    // Pending visibility work belongs to the old render. It must not clear or
    // replace the visible-category state of a newly selected source or category.
    self.categoryNotificationScheduled=NO;self.visibleCategoryIDs=nil;
    if(self.sectionsProvider){NSArray *sections=self.sectionsProvider();NSMutableArray *valid=[NSMutableArray array];for(id section in sections)if([section isKindOfClass:NSDictionary.class])[valid addObject:section];self.sections=valid;}
    [self.collectionViewLayout invalidateLayout];[super reloadData];
}
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {return self.sections.count;}
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {NSDictionary *definition=[self sectionAt:section];NSString *kind=MediaFeedString(definition[@"kind"]);if([kind isEqual:@"hero"]||[kind isEqual:@"status"])return 1;if([kind isEqual:@"skeleton"])return 6;return MediaFeedItems(definition).count;}
- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BOOL first=self.configuredRenderSerial!=self.renderSerial;NSDictionary *fields=first?[self diagnosticFieldsForIndexPath:indexPath]:nil;
    if(first){self.configuredRenderSerial=self.renderSerial;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_cell_configuration_started" fields:fields];}
    UICollectionViewCell *cell=[self configuredCellAtIndexPath:indexPath];
    if(first)[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_cell_configuration_completed" fields:fields];
    return cell;
}
- (NSDictionary *)diagnosticFieldsForIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *section=[self sectionAt:indexPath.section];NSString *kind=MediaFeedString(section[@"kind"]);
    if(![@[@"hero",@"posters",@"grid",@"status",@"skeleton"] containsObject:kind])kind=@"unknown";
    NSUInteger itemCount=0;for(NSDictionary *definition in self.sections)itemCount+=MediaFeedItems(definition).count;
    NSString *sourceID=MediaFeedString(section[@"sourceID"]);
    if(sourceID.length>80||[sourceID containsString:@"://"]||[sourceID containsString:@"?"])sourceID=@"";
    return @{@"content_kind":kind,@"section_count":@(self.sections.count),@"item_count":@(itemCount),@"render_serial":@(self.renderSerial),@"service_id":sourceID,@"item_index":@(indexPath.item),@"section_index":@(indexPath.section)};
}
- (UICollectionViewCell *)configuredCellAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *section=[self sectionAt:indexPath.section];NSString *kind=MediaFeedString(section[@"kind"]);__weak typeof(self) weakSelf=self;
    if([kind isEqual:@"hero"]){MediaFeedHeroCell *cell=[self dequeueReusableCellWithReuseIdentifier:@"feed.hero" forIndexPath:indexPath];[cell configureItems:MediaFeedItems(section)];cell.onSelect=^(NSDictionary *item){MediaFeedView *owner=weakSelf;if(owner.onSelectItem)owner.onSelectItem(item,section);};return cell;}
    if([kind isEqual:@"status"]){MediaFeedStatusCell *cell=[self dequeueReusableCellWithReuseIdentifier:@"feed.status" forIndexPath:indexPath];[cell configureSection:section];cell.onAction=^{MediaFeedView *owner=weakSelf;if(owner.onSelectSection)owner.onSelectSection(section);};return cell;}
    if([kind isEqual:@"skeleton"])return [self dequeueReusableCellWithReuseIdentifier:@"feed.skeleton" forIndexPath:indexPath];
    MediaFeedPosterCell *cell=[self dequeueReusableCellWithReuseIdentifier:@"feed.poster" forIndexPath:indexPath];NSArray *items=MediaFeedItems(section);NSDictionary *item=indexPath.item<items.count&&[items[indexPath.item] isKindOfClass:NSDictionary.class]?items[indexPath.item]:@{};[cell configureItem:item];cell.accessibilityIdentifier=[NSString stringWithFormat:@"media-feed-item-%@-%ld",MediaFeedString(section[@"id"]),(long)indexPath.item];return cell;
}
- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {MediaFeedHeader *header=[self dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"feed.header" forIndexPath:indexPath];NSDictionary *section=[self sectionAt:indexPath.section];header.titleLabel.textColor=HostText();header.actionButton.tintColor=HostSecondaryText();header.titleLabel.text=MediaFeedString(section[@"title"]);NSString *action=MediaFeedString(section[@"actionTitle"]);[header.actionButton setTitle:action forState:UIControlStateNormal];header.actionButton.hidden=!action.length;header.actionButton.accessibilityLabel=[NSString stringWithFormat:@"%@%@",action,header.titleLabel.text?:@""];__weak typeof(self) weakSelf=self;header.onAction=^{MediaFeedView *owner=weakSelf;if(owner.onSelectSection)owner.onSelectSection(section);};return header;}
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {NSDictionary *section=[self sectionAt:indexPath.section];NSString *kind=MediaFeedString(section[@"kind"]);if([@[@"hero",@"status",@"skeleton"] containsObject:kind])return;NSArray *items=MediaFeedItems(section);if(indexPath.item<items.count&&self.onSelectItem)self.onSelectItem(items[indexPath.item],section);}
- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {if(self.visibleRenderSerial!=self.renderSerial){self.visibleRenderSerial=self.renderSerial;[RuntimeDiagnostics.shared recordLifecycleCheckpoint:@"media_grid_first_cell_will_display" fields:[self diagnosticFieldsForIndexPath:indexPath]];}if([cell isKindOfClass:MediaFeedHeroCell.class])((MediaFeedHeroCell *)cell).feedVisible=YES;[self notifyVisibleCategories];}
- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {if([cell isKindOfClass:MediaFeedHeroCell.class])((MediaFeedHeroCell *)cell).feedVisible=NO;}
- (void)notifyVisibleCategories {
    if(!self.onVisibleCategories)return;
    NSMutableOrderedSet<NSString *> *identifiers=[NSMutableOrderedSet orderedSet];
    NSArray<NSIndexPath *> *paths=[self.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)];
    for(NSIndexPath *path in paths){NSString *identifier=MediaFeedString([self sectionAt:path.section][@"categoryID"]);if(identifier.length)[identifiers addObject:identifier];}
    if([self.visibleCategoryIDs isEqual:identifiers.array])return;
    self.visibleCategoryIDs=identifiers.array;
    if(self.categoryNotificationScheduled)return;self.categoryNotificationScheduled=YES;
    NSUInteger renderSerial=self.renderSerial;__weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{MediaFeedView *owner=weakSelf;if(!owner||owner.renderSerial!=renderSerial)return;owner.categoryNotificationScheduled=NO;if(owner.onVisibleCategories)owner.onVisibleCategories(owner.visibleCategoryIDs?:@[]);});
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    BOOL movingDown=scrollView.contentOffset.y>self.previousScrollOffset+.1;self.previousScrollOffset=scrollView.contentOffset.y;
    if(self.onScroll)self.onScroll(scrollView);[self notifyVisibleCategories];
    if(!movingDown||!(scrollView.dragging||scrollView.decelerating)||!self.onNearEnd)return;BOOL hasGrid=NO;for(NSDictionary *section in self.sections)if([section[@"kind"] isEqual:@"grid"]){hasGrid=YES;break;}
    if(hasGrid&&scrollView.contentOffset.y+CGRectGetHeight(scrollView.bounds)>=scrollView.contentSize.height-MAX(360,CGRectGetHeight(scrollView.bounds)*.85))self.onNearEnd();
}
- (void)layoutSubviews {[super layoutSubviews];CGFloat width=CGRectGetWidth(self.bounds);if(width>0&&fabs(width-self.lastLayoutWidth)>.5){self.lastLayoutWidth=width;[self.collectionViewLayout invalidateLayout];}for(UICollectionViewCell *cell in self.visibleCells)if([cell isKindOfClass:MediaFeedHeroCell.class])[(MediaFeedHeroCell *)cell updateTimer];}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {[super traitCollectionDidChange:previous];if(![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory])[self.collectionViewLayout invalidateLayout];}
@end
