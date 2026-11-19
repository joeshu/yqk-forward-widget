#import "ConfigCenterViewController.h"
#import "HostTheme.h"
#import "HostGlassActionSheetViewController.h"
#import "HostLogRedactor.h"
#import "ProfileStore.h"
#import "MediaAdaptationMonitor.h"
#import "PyHost.h"
#import <math.h>

static NSString *CCTVResourceDisplayEndpoint(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length <= 180) return [value isKindOfClass:NSString.class] ? value : @"";
    NSRange prefix = [value rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 179)];
    return [[value substringWithRange:prefix] stringByAppendingString:@"…"];
}

static NSString *CCTVResourceUnifiedKeyForProfile(NSDictionary *profile) {
    if (![profile isKindOfClass:NSDictionary.class]) return @"";
    NSString *source = [profile[@"source"] isKindOfClass:NSString.class] ? profile[@"source"] : @"";
    if (source.length) return source;
    if ([profile[@"native"] boolValue]) return @"__native_cctv__";
    return @"";
}

@interface HostResourceActionLabel : UILabel
@property(nonatomic,copy) BOOL (^activation)(void);
@end
@implementation HostResourceActionLabel
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {CGFloat dy=MAX(0,(44-self.bounds.size.height)/2);return CGRectContainsPoint(CGRectInset(self.bounds,0,-dy),point);}
- (BOOL)accessibilityActivate {return self.activation?self.activation():NO;}
@end

@interface CCTVResourceProfileCell : UITableViewCell
@property(nonatomic,strong) UIView *topSpecularLine;
@property(nonatomic,strong) UIView *iconBadgeContainer;
@property(nonatomic,strong) UIImageView *profileIconView;
@property(nonatomic,strong) UIView *leadingAccentBar;
@property(nonatomic,strong) UIImageView *dragHandleView;
@property(nonatomic,strong) UILabel *profileTitleLabel;
@property(nonatomic,strong) UILabel *profileDetailLabel;
@property(nonatomic,strong) UILabel *protocolBadge;
@property(nonatomic,strong) UILabel *latencyBadge;
@property(nonatomic,strong) UILabel *statusBadge;
@property(nonatomic,strong) UILabel *capabilityBadge;
@property(nonatomic,strong) UIView *detailDivider;
@property(nonatomic,copy) NSString *profileSource;
@property(nonatomic,copy) void (^onTapLatency)(NSString *source);
@end

@interface CCTVResourceProfileCell ()
- (void)handleLatencyBadgeTap;
@end

@implementation CCTVResourceProfileCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if((self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.topSpecularLine=[UIView new];self.topSpecularLine.translatesAutoresizingMaskIntoConstraints=NO;self.topSpecularLine.backgroundColor=[UIColor colorWithWhite:1.0 alpha:0.08];self.topSpecularLine.userInteractionEnabled=NO;
        self.iconBadgeContainer=[UIView new];self.iconBadgeContainer.translatesAutoresizingMaskIntoConstraints=NO;self.iconBadgeContainer.backgroundColor=[HostAccent() colorWithAlphaComponent:0.14];self.iconBadgeContainer.layer.cornerRadius=10.5;self.iconBadgeContainer.layer.cornerCurve=kCACornerCurveContinuous;self.iconBadgeContainer.layer.borderWidth=0.65;HostSetLayerBorderColor(self.iconBadgeContainer,[HostAccent() colorWithAlphaComponent:0.28]);self.iconBadgeContainer.hidden=YES;self.iconBadgeContainer.alpha=0.0;self.iconBadgeContainer.userInteractionEnabled=NO;
        self.profileIconView=[UIImageView new];self.profileIconView.translatesAutoresizingMaskIntoConstraints=NO;self.profileIconView.contentMode=UIViewContentModeScaleAspectFit;
        [self.iconBadgeContainer addSubview:self.profileIconView];
        self.leadingAccentBar=[UIView new];self.leadingAccentBar.translatesAutoresizingMaskIntoConstraints=NO;self.leadingAccentBar.backgroundColor=HostAccent();self.leadingAccentBar.layer.cornerRadius=1.75;self.leadingAccentBar.layer.cornerCurve=kCACornerCurveContinuous;self.leadingAccentBar.userInteractionEnabled=NO;
        self.dragHandleView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium]]];self.dragHandleView.translatesAutoresizingMaskIntoConstraints=NO;self.dragHandleView.tintColor=HostMutedText();self.dragHandleView.alpha=0.52;self.dragHandleView.contentMode=UIViewContentModeScaleAspectFit;self.dragHandleView.userInteractionEnabled=NO;self.dragHandleView.accessibilityIdentifier=@"resource.drag.handle";
        self.profileTitleLabel=[UILabel new];self.profileTitleLabel.translatesAutoresizingMaskIntoConstraints=NO;self.profileTitleLabel.numberOfLines=2;self.profileTitleLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.profileTitleLabel.adjustsFontForContentSizeCategory=YES;
        self.profileDetailLabel=[UILabel new];self.profileDetailLabel.translatesAutoresizingMaskIntoConstraints=NO;self.profileDetailLabel.numberOfLines=0;self.profileDetailLabel.lineBreakMode=NSLineBreakByCharWrapping;self.profileDetailLabel.adjustsFontForContentSizeCategory=YES;
        self.protocolBadge=[UILabel new];self.protocolBadge.translatesAutoresizingMaskIntoConstraints=NO;self.protocolBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightBold,UIFontTextStyleCaption2);self.protocolBadge.textAlignment=NSTextAlignmentCenter;self.protocolBadge.layer.cornerRadius=6.5;self.protocolBadge.layer.cornerCurve=kCACornerCurveContinuous;self.protocolBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.protocolBadge,[HostAccent() colorWithAlphaComponent:0.32]);self.protocolBadge.clipsToBounds=YES;self.protocolBadge.backgroundColor=HostSelectedSurface();self.protocolBadge.textColor=HostAccent();self.protocolBadge.accessibilityIdentifier=@"resource.protocol.badge";
        self.latencyBadge=[HostResourceActionLabel new];self.latencyBadge.translatesAutoresizingMaskIntoConstraints=NO;self.latencyBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2);self.latencyBadge.textAlignment=NSTextAlignmentCenter;self.latencyBadge.layer.cornerRadius=6.5;self.latencyBadge.layer.cornerCurve=kCACornerCurveContinuous;self.latencyBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.latencyBadge,HostBorder());self.latencyBadge.clipsToBounds=YES;self.latencyBadge.backgroundColor=HostRaisedSurface();self.latencyBadge.textColor=HostSecondaryText();self.latencyBadge.userInteractionEnabled=YES;self.latencyBadge.accessibilityIdentifier=@"resource.latency.badge";
        self.latencyBadge.isAccessibilityElement=YES;self.latencyBadge.accessibilityTraits=UIAccessibilityTraitButton;__weak typeof(self) weakLatencyCell=self;
        ((HostResourceActionLabel *)self.latencyBadge).activation=^BOOL{CCTVResourceProfileCell *owner=weakLatencyCell;if(!owner.onTapLatency||!owner.profileSource.length)return NO;[owner handleLatencyBadgeTap];return YES;};
        UITapGestureRecognizer *latencyTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleLatencyBadgeTap)];[self.latencyBadge addGestureRecognizer:latencyTap];
        self.statusBadge=[UILabel new];self.statusBadge.translatesAutoresizingMaskIntoConstraints=NO;self.statusBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2);self.statusBadge.textAlignment=NSTextAlignmentCenter;self.statusBadge.layer.cornerRadius=6.5;self.statusBadge.layer.cornerCurve=kCACornerCurveContinuous;self.statusBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.statusBadge,HostBorder());self.statusBadge.clipsToBounds=YES;self.statusBadge.backgroundColor=HostNeutralSurface();self.statusBadge.textColor=HostSecondaryText();self.statusBadge.accessibilityIdentifier=@"resource.status.badge";
        self.capabilityBadge=[UILabel new];self.capabilityBadge.translatesAutoresizingMaskIntoConstraints=NO;self.capabilityBadge.font=HostMonospacedDigitFont(10.0,UIFontWeightMedium,UIFontTextStyleCaption2);self.capabilityBadge.textAlignment=NSTextAlignmentCenter;self.capabilityBadge.layer.cornerRadius=6.5;self.capabilityBadge.layer.cornerCurve=kCACornerCurveContinuous;self.capabilityBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.capabilityBadge,HostBorder());self.capabilityBadge.clipsToBounds=YES;self.capabilityBadge.backgroundColor=HostRaisedSurface();self.capabilityBadge.textColor=HostSecondaryText();self.capabilityBadge.accessibilityIdentifier=@"resource.capability.badge";
        self.detailDivider=[UIView new];self.detailDivider.translatesAutoresizingMaskIntoConstraints=NO;self.detailDivider.backgroundColor=[HostSeparator() colorWithAlphaComponent:0.42];
        [self.contentView addSubview:self.topSpecularLine];[self.contentView addSubview:self.iconBadgeContainer];[self.contentView addSubview:self.leadingAccentBar];[self.contentView addSubview:self.dragHandleView];[self.contentView addSubview:self.profileTitleLabel];[self.contentView addSubview:self.protocolBadge];[self.contentView addSubview:self.latencyBadge];[self.contentView addSubview:self.statusBadge];[self.contentView addSubview:self.capabilityBadge];[self.contentView addSubview:self.detailDivider];[self.contentView addSubview:self.profileDetailLabel];
        [self.profileTitleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
        [self.profileDetailLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
        [self.capabilityBadge setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [NSLayoutConstraint activateConstraints:@[
            [self.topSpecularLine.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [self.topSpecularLine.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [self.topSpecularLine.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [self.topSpecularLine.heightAnchor constraintEqualToConstant:0.5],
            [self.iconBadgeContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [self.iconBadgeContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [self.iconBadgeContainer.widthAnchor constraintEqualToConstant:0],
            [self.iconBadgeContainer.heightAnchor constraintEqualToConstant:0],
            [self.profileIconView.centerXAnchor constraintEqualToAnchor:self.iconBadgeContainer.centerXAnchor],
            [self.profileIconView.centerYAnchor constraintEqualToAnchor:self.iconBadgeContainer.centerYAnchor],
            [self.profileIconView.widthAnchor constraintEqualToConstant:0],
            [self.profileIconView.heightAnchor constraintEqualToConstant:0],
            [self.leadingAccentBar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [self.leadingAccentBar.centerYAnchor constraintEqualToAnchor:self.profileTitleLabel.centerYAnchor],
            [self.leadingAccentBar.widthAnchor constraintEqualToConstant:3.5],
            [self.leadingAccentBar.heightAnchor constraintEqualToConstant:16],
            [self.profileTitleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:22],
            [self.profileTitleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [self.profileTitleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
            [self.protocolBadge.leadingAnchor constraintEqualToAnchor:self.profileTitleLabel.leadingAnchor],
            [self.protocolBadge.topAnchor constraintEqualToAnchor:self.profileTitleLabel.bottomAnchor constant:6],
            [self.protocolBadge.heightAnchor constraintEqualToConstant:20],
            [self.latencyBadge.leadingAnchor constraintEqualToAnchor:self.protocolBadge.trailingAnchor constant:4],
            [self.latencyBadge.centerYAnchor constraintEqualToAnchor:self.protocolBadge.centerYAnchor],
            [self.latencyBadge.widthAnchor constraintGreaterThanOrEqualToConstant:40],
            [self.latencyBadge.heightAnchor constraintEqualToConstant:20],
            [self.statusBadge.leadingAnchor constraintEqualToAnchor:self.latencyBadge.trailingAnchor constant:4],
            [self.statusBadge.centerYAnchor constraintEqualToAnchor:self.protocolBadge.centerYAnchor],
            [self.statusBadge.heightAnchor constraintEqualToConstant:20],
            [self.capabilityBadge.leadingAnchor constraintEqualToAnchor:self.statusBadge.trailingAnchor constant:4],
            [self.capabilityBadge.centerYAnchor constraintEqualToAnchor:self.protocolBadge.centerYAnchor],
            [self.capabilityBadge.heightAnchor constraintEqualToConstant:20],
            [self.capabilityBadge.trailingAnchor constraintLessThanOrEqualToAnchor:self.dragHandleView.leadingAnchor constant:-4],
            [self.statusBadge.trailingAnchor constraintLessThanOrEqualToAnchor:self.dragHandleView.leadingAnchor constant:-4],
            [self.dragHandleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [self.dragHandleView.centerYAnchor constraintEqualToAnchor:self.protocolBadge.centerYAnchor],
            [self.dragHandleView.widthAnchor constraintEqualToConstant:16],
            [self.dragHandleView.heightAnchor constraintEqualToConstant:16],
            [self.detailDivider.leadingAnchor constraintEqualToAnchor:self.profileTitleLabel.leadingAnchor],
            [self.detailDivider.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [self.detailDivider.topAnchor constraintEqualToAnchor:self.protocolBadge.bottomAnchor constant:7],
            [self.detailDivider.heightAnchor constraintEqualToConstant:0.5],
            [self.profileDetailLabel.leadingAnchor constraintEqualToAnchor:self.profileTitleLabel.leadingAnchor],
            [self.profileDetailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-8],
            [self.profileDetailLabel.topAnchor constraintEqualToAnchor:self.protocolBadge.bottomAnchor constant:12],
            [self.profileDetailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-14]
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if(self.capabilityBadge.text.length){
        CGFloat needed=ceil(self.capabilityBadge.intrinsicContentSize.width);
        self.capabilityBadge.hidden=(CGRectGetWidth(self.capabilityBadge.frame)<needed-2.0);
    }else{
        self.capabilityBadge.hidden=YES;
    }
}
- (void)handleLatencyBadgeTap {
    if(!self.profileSource.length||!self.onTapLatency)return;
    HostAnimateSelection(self.latencyBadge);
    self.onTapLatency(self.profileSource);
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.backgroundColor=highlighted?HostHighlightedSurface():HostCard();
}
- (UILabel *)textLabel { return self.profileTitleLabel; }
- (UILabel *)detailTextLabel { return self.profileDetailLabel; }
- (UIImageView *)imageView { return self.profileIconView; }
@end

static NSDateFormatter *CCTVResourceListDateFormatter(void) {
    // heightForRow 与 cellForRow 每行都会调 resourceDetailForProfile：
    // NSDateFormatter 创建昂贵，复用同一实例，避免滚动时反复分配。
    // 只在主线程调用（列表渲染），无需加锁。
    static NSDateFormatter *formatter;static dispatch_once_t once;
    dispatch_once(&once,^{formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"zh_CN"];formatter.dateFormat=@"MM-dd HH:mm";});
    return formatter;
}

@interface ConfigCenterViewController () <UITextFieldDelegate, UITableViewDragDelegate, UITableViewDropDelegate>
@property(nonatomic, strong) NSArray<NSDictionary *> *profiles;
@property(nonatomic, strong) NSArray<NSDictionary *> *allProfiles;
@property(nonatomic, strong) UIScrollView *kindScroll;
@property(nonatomic, strong) UIStackView *kindStack;
@property(nonatomic, copy) NSArray<UIButton *> *kindFilterButtons;
@property(nonatomic, strong) UIView *resourceHeader;
@property(nonatomic, strong) UIStackView *topActionsStack;
@property(nonatomic, strong) UILabel *resourceTitleLabel;
@property(nonatomic, strong) UITextField *resourceSearchField;
@property(nonatomic, copy) NSString *searchQuery;
@property(nonatomic, strong) NSLayoutConstraint *kindScrollHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *resourceHeaderTopConstraint;
@property(nonatomic) CGFloat statusBarSafeInset;
@property(nonatomic) CGFloat bottomOverlayInset;
@property(nonatomic) BOOL updatingResourceHeaderLayout;
@property(nonatomic) CGPoint navigationReturnContentOffset;
@property(nonatomic) CGFloat navigationReturnHeaderHeight;
@property(nonatomic) BOOL hasNavigationReturnPosition;
@property(nonatomic, copy) NSString *selectedKind;
@property(nonatomic, copy) NSString *sortMode;
@property(nonatomic, strong) UIView *emptyContainerView;
@property(nonatomic, strong) UIImageView *emptyIconView;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) UIButton *emptyActionButton;
@property(nonatomic, strong) UILabel *toastLabel;
@property(nonatomic, assign) NSUInteger searchGeneration;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *latencyResults;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *detailSummaryCache;
@property(nonatomic,strong) NSCache<NSString *,NSNumber *> *rowHeightCache;
@property(nonatomic) BOOL probingResources;
@property(nonatomic,strong) UIButton *importTaskButton;
@property(nonatomic,strong) UIButton *importTaskToggleButton;
@property(nonatomic,strong) UILabel *importTaskDetailLabel;
@property(nonatomic,strong) UIView *importTaskContainer;
@property(nonatomic,strong) NSLayoutConstraint *importTaskHeight;
@property(nonatomic,strong) NSLayoutConstraint *importTaskButtonHeight;
@property(nonatomic,strong) NSLayoutConstraint *importTaskToggleHeight;
@property(nonatomic,strong) NSLayoutConstraint *importTaskDetailHeight;
@property(nonatomic) BOOL importTaskExpanded;
@property(nonatomic,strong) UIButton *sortFilterButton;
@property(nonatomic,strong) UIView *compactHeader;
@property(nonatomic,strong) UIVisualEffectView *compactBlur;
@property(nonatomic,strong) UIView *compactSeparator;
@property(nonatomic,strong) UILabel *compactTitle;
@property(nonatomic,strong) UIButton *compactAdd;
@property(nonatomic,strong) UIButton *compactMore;
@property(nonatomic,strong) UIView *dashboardCard;
@property(nonatomic,strong) UILabel *dashboardSummaryLabel;
@property(nonatomic,strong) UILabel *dashboardHealthBadge;
@property(nonatomic,strong) UIStackView *dashboardMetricsStack;
@property(nonatomic,strong) UIStackView *dashboardActionsStack;
@property(nonatomic,copy) NSArray<UILabel *> *dashboardMetricValueLabels;
@property(nonatomic,copy) NSArray<UILabel *> *dashboardMetricTitleLabels;
@property(nonatomic,copy) NSArray<UIButton *> *dashboardMetricButtons;
@property(nonatomic,copy) NSArray<UIButton *> *dashboardQuickActionButtons;
- (void)buildDashboardCard;
- (void)updateDashboardCard;
- (void)handleDashboardMetricTap:(UIButton *)sender;
- (NSAttributedString *)attributedDetailForText:(NSString *)detailText font:(UIFont *)font;
- (NSString *)capabilityTagForProfile:(NSDictionary *)profile;
- (NSString *)semanticIconNameForProfile:(NSDictionary *)profile tintColor:(UIColor * __autoreleasing *)tintColorOut;
- (void)updateSortPillButton;
- (NSString *)statusBadgeTextForProfile:(NSDictionary *)profile textColor:(UIColor * __autoreleasing *)textColorOut backgroundColor:(UIColor * __autoreleasing *)bgColorOut borderColor:(UIColor * __autoreleasing *)borderColorOut;
- (void)layoutCompactHeader;
- (void)updateResourceHeaderLayout;
- (void)updateResourceHeaderLayoutReattaching:(BOOL)reattach;
- (void)confirmRemoveProfile:(NSString *)source;
- (NSString *)resourceTitleForProfile:(NSDictionary *)profile;
- (NSString *)resourceDetailForProfile:(NSDictionary *)profile;
- (BOOL)profile:(NSDictionary *)profile matchesSearchQuery:(NSString *)query;
- (void)selectKind:(UIButton *)sender;
- (void)searchTextChanged;
- (BOOL)textFieldShouldReturn:(UITextField *)textField;
- (void)refreshHomeContent;
- (void)probeResources;
- (NSString *)latencyTextForProfile:(NSDictionary *)profile color:(UIColor * __autoreleasing *)color;
- (void)updateKindFilters;
- (void)showResourceFilters;
- (UISwitch *)compactSwitchForRow:(NSInteger)row enabled:(BOOL)enabled label:(NSString *)label source:(NSString *)source;
- (UIView *)switchAccessoryForSwitch:(UISwitch *)toggle width:(CGFloat)width;
- (void)moveProfileFromIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath updateTableView:(BOOL)updateTableView;
- (void)persistUnifiedOrderWithProfiles:(NSArray<NSDictionary *> *)orderedProfiles;
- (void)openServices;
- (void)openAdaptationMonitor;
- (void)reloadVisibleRowForSource:(NSString *)source;
- (void)showResourceToast:(NSString *)message;
- (void)add;
- (void)handleEmptyActionTap;
- (void)scrollToTopFromCompactHeader;
@end
@implementation ConfigCenterViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.title = @"";
    self.tableView.backgroundColor = HostBackground();
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    // Resource rows vary greatly in height (native lists, scripts and service
    // endpoints). Estimating them creates visible scroll jumps when returning
    // to this page and UITableView replaces estimates with measured heights.
    self.tableView.estimatedRowHeight = 0;
    self.tableView.estimatedSectionHeaderHeight = 0;
    self.tableView.estimatedSectionFooterHeight = 0;
    self.tableView.sectionHeaderTopPadding = 0;
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
    self.selectedKind=@"all";NSString *savedSort=[NSUserDefaults.standardUserDefaults stringForKey:@"resourceListSortMode"];self.sortMode=(savedSort.length&&[@[@"manual",@"name",@"recent",@"attention",@"latency"] containsObject:savedSort])?savedSort:@"manual";self.latencyResults=[NSMutableDictionary dictionary];self.detailSummaryCache=[NSMutableDictionary dictionary];self.rowHeightCache=[NSCache new];self.rowHeightCache.countLimit=256;
    self.resourceHeader=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),220)];
    self.resourceHeader.backgroundColor=HostBackground();

    self.topActionsStack=[UIStackView new];self.topActionsStack.translatesAutoresizingMaskIntoConstraints=NO;self.topActionsStack.axis=UILayoutConstraintAxisHorizontal;self.topActionsStack.alignment=UIStackViewAlignmentCenter;self.topActionsStack.distribution=UIStackViewDistributionFillEqually;self.topActionsStack.spacing=0;self.topActionsStack.backgroundColor=HostRaisedSurface();self.topActionsStack.layer.cornerRadius=23;self.topActionsStack.layer.cornerCurve=kCACornerCurveContinuous;self.topActionsStack.layer.borderWidth=.7;HostSetLayerBorderColor(self.topActionsStack,HostBorder());[self.resourceHeader addSubview:self.topActionsStack];
    NSArray *actions=@[@{ @"icon":@"plus", @"label":@"添加资源", @"selector":NSStringFromSelector(@selector(add)) }];
    for(NSDictionary *item in actions){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityLabel=item[@"label"];button.accessibilityIdentifier=[@"resource-action." stringByAppendingString:item[@"label"]];UIButtonConfiguration *config=[UIButtonConfiguration plainButtonConfiguration];config.image=[UIImage systemImageNamed:item[@"icon"]];config.baseForegroundColor=HostText();config.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);button.configuration=config;HostInstallPressFeedback(button);SEL selector=NSSelectorFromString(item[@"selector"]);[button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];[self.topActionsStack addArrangedSubview:button];[button.widthAnchor constraintEqualToConstant:44].active=YES;[button.heightAnchor constraintEqualToConstant:44].active=YES;}
    UIButton *moreButton=[UIButton buttonWithType:UIButtonTypeSystem];moreButton.translatesAutoresizingMaskIntoConstraints=NO;moreButton.accessibilityLabel=@"更多资源操作";moreButton.accessibilityIdentifier=@"resource-action.more";UIButtonConfiguration *moreConfig=[UIButtonConfiguration plainButtonConfiguration];moreConfig.image=[UIImage systemImageNamed:@"ellipsis"];moreConfig.baseForegroundColor=HostText();moreConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);moreButton.configuration=moreConfig;HostInstallPressFeedback(moreButton);[moreButton.widthAnchor constraintEqualToConstant:44].active=YES;[moreButton.heightAnchor constraintEqualToConstant:44].active=YES;__weak typeof(self) weakSelf=self;UIAction *servicesAction=[UIAction actionWithTitle:@"脚本与服务" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *action){[weakSelf openServices];}];UIAction *filterAction=[UIAction actionWithTitle:@"筛选与排序" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] identifier:nil handler:^(UIAction *action){[weakSelf showResourceFilters];}];UIAction *probeAction=[UIAction actionWithTitle:@"检查全部资源连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *action){[weakSelf probeResources];}];UIAction *monitorAction=[UIAction actionWithTitle:@"站点与播放适配监测" image:[UIImage systemImageNamed:@"waveform.path.ecg"] identifier:nil handler:^(UIAction *action){[weakSelf openAdaptationMonitor];}];moreButton.menu=[UIMenu menuWithChildren:@[filterAction,probeAction,monitorAction,servicesAction]];moreButton.showsMenuAsPrimaryAction=YES;[self.topActionsStack addArrangedSubview:moreButton];

    self.resourceTitleLabel=[UILabel new];self.resourceTitleLabel.translatesAutoresizingMaskIntoConstraints=NO;self.resourceTitleLabel.text=@"资源";self.resourceTitleLabel.textColor=HostText();self.resourceTitleLabel.font=HostRoundedFont(34,UIFontWeightBold,UIFontTextStyleLargeTitle);self.resourceTitleLabel.adjustsFontForContentSizeCategory=YES;[self.resourceHeader addSubview:self.resourceTitleLabel];
    self.resourceSearchField=[UITextField new];self.resourceSearchField.translatesAutoresizingMaskIntoConstraints=NO;self.resourceSearchField.accessibilityIdentifier=@"resource-search-field";self.resourceSearchField.accessibilityLabel=@"搜索资源";self.resourceSearchField.placeholder=@"搜索资源";self.resourceSearchField.clearButtonMode=UITextFieldViewModeWhileEditing;self.resourceSearchField.returnKeyType=UIReturnKeySearch;self.resourceSearchField.delegate=self;self.resourceSearchField.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.resourceSearchField.adjustsFontForContentSizeCategory=YES;self.resourceSearchField.textColor=HostText();self.resourceSearchField.tintColor=HostAccent();self.resourceSearchField.backgroundColor=HostRaisedSurface();self.resourceSearchField.layer.cornerRadius=14;self.resourceSearchField.layer.cornerCurve=kCACornerCurveContinuous;self.resourceSearchField.layer.borderWidth=0.65;HostSetLayerBorderColor(self.resourceSearchField,HostBorder());self.resourceSearchField.leftViewMode=UITextFieldViewModeAlways;UIView *searchIconContainer=[[UIView alloc] initWithFrame:CGRectMake(0,0,38,44)];UIImageView *searchIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];searchIcon.tintColor=HostMutedText();searchIcon.frame=CGRectMake(12,13,18,18);searchIconContainer.userInteractionEnabled=NO;[searchIconContainer addSubview:searchIcon];self.resourceSearchField.leftView=searchIconContainer;
    self.sortFilterButton=[UIButton buttonWithType:UIButtonTypeSystem];self.sortFilterButton.accessibilityIdentifier=@"resource-sort-pill";self.sortFilterButton.titleLabel.font=HostMonospacedDigitFont(11.5,UIFontWeightSemibold,UIFontTextStyleCaption1);self.sortFilterButton.backgroundColor=HostNeutralSurface();self.sortFilterButton.tintColor=HostSecondaryText();self.sortFilterButton.layer.cornerRadius=11;self.sortFilterButton.layer.cornerCurve=kCACornerCurveContinuous;self.sortFilterButton.layer.borderWidth=0.55;HostSetLayerBorderColor(self.sortFilterButton,HostBorder());self.sortFilterButton.contentEdgeInsets=UIEdgeInsetsMake(4,9,4,9);self.sortFilterButton.showsMenuAsPrimaryAction=YES;HostInstallPressFeedback(self.sortFilterButton);
    UIView *sortRightContainer=[[UIView alloc] initWithFrame:CGRectMake(0,0,82,44)];self.sortFilterButton.frame=CGRectMake(0,5,74,34);[sortRightContainer addSubview:self.sortFilterButton];self.resourceSearchField.rightView=sortRightContainer;self.resourceSearchField.rightViewMode=UITextFieldViewModeUnlessEditing;
    [self updateSortPillButton];
    [self.resourceSearchField addTarget:self action:@selector(searchTextChanged) forControlEvents:UIControlEventEditingChanged];[self.resourceHeader addSubview:self.resourceSearchField];

    [self buildDashboardCard];
    self.kindScroll=[UIScrollView new];self.kindScroll.translatesAutoresizingMaskIntoConstraints=NO;self.kindScroll.showsHorizontalScrollIndicator=NO;self.kindScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.kindStack=[UIStackView new];self.kindStack.translatesAutoresizingMaskIntoConstraints=NO;self.kindStack.axis=UILayoutConstraintAxisHorizontal;self.kindStack.spacing=8;[self.kindScroll addSubview:self.kindStack];[self.resourceHeader addSubview:self.kindScroll];
    self.kindScrollHeightConstraint=[self.kindScroll.heightAnchor constraintEqualToConstant:48];
    self.resourceHeaderTopConstraint=[self.topActionsStack.topAnchor constraintEqualToAnchor:self.resourceHeader.topAnchor constant:4];
    [NSLayoutConstraint activateConstraints:@[self.resourceHeaderTopConstraint,[self.topActionsStack.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-16],[self.topActionsStack.widthAnchor constraintEqualToConstant:88],[self.topActionsStack.heightAnchor constraintEqualToConstant:44],[self.resourceTitleLabel.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.resourceTitleLabel.topAnchor constraintEqualToAnchor:self.topActionsStack.topAnchor],[self.resourceTitleLabel.heightAnchor constraintGreaterThanOrEqualToConstant:42],[self.resourceSearchField.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.resourceSearchField.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-20],[self.resourceSearchField.topAnchor constraintEqualToAnchor:self.resourceTitleLabel.bottomAnchor constant:6],[self.resourceSearchField.heightAnchor constraintGreaterThanOrEqualToConstant:44],[self.dashboardCard.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.dashboardCard.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-20],[self.dashboardCard.topAnchor constraintEqualToAnchor:self.resourceSearchField.bottomAnchor constant:10],[self.kindScroll.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:10],[self.kindScroll.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor],[self.kindScroll.topAnchor constraintEqualToAnchor:self.dashboardCard.bottomAnchor constant:10],self.kindScrollHeightConstraint,[self.kindStack.leadingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.leadingAnchor],[self.kindStack.trailingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.trailingAnchor constant:-10],[self.kindStack.topAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.topAnchor],[self.kindStack.bottomAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.bottomAnchor],[self.kindStack.heightAnchor constraintEqualToAnchor:self.kindScroll.frameLayoutGuide.heightAnchor]]];
    self.importTaskContainer=[UIView new];self.importTaskContainer.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskContainer.backgroundColor=HostRaisedSurface();self.importTaskContainer.layer.cornerRadius=14;self.importTaskContainer.layer.cornerCurve=kCACornerCurveContinuous;self.importTaskContainer.layer.borderWidth=0.65;HostSetLayerBorderColor(self.importTaskContainer,[HostAccent() colorWithAlphaComponent:0.32]);self.importTaskContainer.clipsToBounds=YES;[self.resourceHeader addSubview:self.importTaskContainer];self.importTaskHeight=[self.importTaskContainer.heightAnchor constraintEqualToConstant:0];
    self.importTaskButton=[UIButton buttonWithType:UIButtonTypeSystem];self.importTaskButton.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.importTaskButton.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.importTaskButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;self.importTaskButton.contentEdgeInsets=UIEdgeInsetsMake(0,12,0,8);self.importTaskButton.tintColor=HostAccent();self.importTaskButton.accessibilityIdentifier=@"resource-import-task";[self.importTaskButton addTarget:self action:@selector(add) forControlEvents:UIControlEventTouchUpInside];[self.importTaskContainer addSubview:self.importTaskButton];
    self.importTaskToggleButton=[UIButton buttonWithType:UIButtonTypeSystem];self.importTaskToggleButton.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskToggleButton.accessibilityLabel=@"展开或收起导入任务";[self.importTaskToggleButton setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];self.importTaskToggleButton.tintColor=HostSecondaryText();[self.importTaskToggleButton addTarget:self action:@selector(toggleImportTaskExpanded) forControlEvents:UIControlEventTouchUpInside];[self.importTaskContainer addSubview:self.importTaskToggleButton];
    self.importTaskDetailLabel=[UILabel new];self.importTaskDetailLabel.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskDetailLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];self.importTaskDetailLabel.textColor=HostSecondaryText();self.importTaskDetailLabel.numberOfLines=2;self.importTaskDetailLabel.hidden=YES;[self.importTaskContainer addSubview:self.importTaskDetailLabel];
    self.importTaskButtonHeight=[self.importTaskButton.heightAnchor constraintEqualToConstant:0];self.importTaskToggleHeight=[self.importTaskToggleButton.heightAnchor constraintEqualToConstant:0];
    self.importTaskDetailHeight=[self.importTaskDetailLabel.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[[self.importTaskContainer.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.importTaskContainer.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-20],[self.importTaskContainer.topAnchor constraintEqualToAnchor:self.kindScroll.bottomAnchor constant:4],[self.importTaskContainer.bottomAnchor constraintEqualToAnchor:self.resourceHeader.bottomAnchor constant:-6],self.importTaskHeight,[self.importTaskButton.leadingAnchor constraintEqualToAnchor:self.importTaskContainer.leadingAnchor],[self.importTaskButton.trailingAnchor constraintEqualToAnchor:self.importTaskToggleButton.leadingAnchor],[self.importTaskButton.topAnchor constraintEqualToAnchor:self.importTaskContainer.topAnchor],self.importTaskButtonHeight,[self.importTaskToggleButton.trailingAnchor constraintEqualToAnchor:self.importTaskContainer.trailingAnchor],[self.importTaskToggleButton.topAnchor constraintEqualToAnchor:self.importTaskContainer.topAnchor],[self.importTaskToggleButton.widthAnchor constraintEqualToConstant:44],self.importTaskToggleHeight,[self.importTaskDetailLabel.leadingAnchor constraintEqualToAnchor:self.importTaskContainer.leadingAnchor constant:12],[self.importTaskDetailLabel.trailingAnchor constraintEqualToAnchor:self.importTaskContainer.trailingAnchor constant:-12],[self.importTaskDetailLabel.topAnchor constraintEqualToAnchor:self.importTaskButton.bottomAnchor],self.importTaskDetailHeight]];
    self.tableView.tableHeaderView=self.resourceHeader;
    CGFloat tableBottomInset=MAX(8,self.bottomOverlayInset);self.tableView.contentInset=UIEdgeInsetsMake(0,0,tableBottomInset,0);self.tableView.scrollIndicatorInsets=self.tableView.contentInset;
    self.emptyContainerView=[UIView new];self.emptyContainerView.accessibilityIdentifier=@"resource.empty.view";
    UIStackView *emptyStack=[UIStackView new];emptyStack.translatesAutoresizingMaskIntoConstraints=NO;emptyStack.axis=UILayoutConstraintAxisVertical;emptyStack.alignment=UIStackViewAlignmentCenter;emptyStack.spacing=10;
    self.emptyIconView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"tray" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightLight]]];self.emptyIconView.tintColor=HostMutedText();
    self.emptyLabel=[UILabel new];self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.numberOfLines=0;self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];self.emptyLabel.adjustsFontForContentSizeCategory=YES;
    self.emptyActionButton=[UIButton buttonWithType:UIButtonTypeSystem];self.emptyActionButton.accessibilityIdentifier=@"resource.empty.action";HostStylePillButton(self.emptyActionButton,NO);self.emptyActionButton.contentEdgeInsets=UIEdgeInsetsMake(8,16,8,16);self.emptyActionButton.layer.cornerRadius=16;HostInstallPressFeedback(self.emptyActionButton);[self.emptyActionButton addTarget:self action:@selector(handleEmptyActionTap) forControlEvents:UIControlEventTouchUpInside];
    [emptyStack addArrangedSubview:self.emptyIconView];[emptyStack addArrangedSubview:self.emptyLabel];[emptyStack addArrangedSubview:self.emptyActionButton];
    [self.emptyContainerView addSubview:emptyStack];
    [NSLayoutConstraint activateConstraints:@[
        [emptyStack.centerXAnchor constraintEqualToAnchor:self.emptyContainerView.centerXAnchor],
        [emptyStack.centerYAnchor constraintEqualToAnchor:self.emptyContainerView.centerYAnchor constant:70],
        [emptyStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.emptyContainerView.leadingAnchor constant:32],
        [emptyStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.emptyContainerView.trailingAnchor constant:-32],
        [self.emptyActionButton.heightAnchor constraintGreaterThanOrEqualToConstant:36]
    ]];
    self.tableView.backgroundView=self.emptyContainerView;
    UIRefreshControl *r = [UIRefreshControl new];
    [r addTarget:self action:@selector(refreshProfiles) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = r;
    self.navigationItem.rightBarButtonItems=nil;self.navigationItem.rightBarButtonItem=nil;
    self.compactHeader=[UIView new];self.compactHeader.backgroundColor=[HostBackground() colorWithAlphaComponent:.94];self.compactHeader.hidden=YES;[self.tableView addSubview:self.compactHeader];
    self.compactBlur=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];HostRegisterGlassEffectView(self.compactBlur);self.compactBlur.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.compactBlur.userInteractionEnabled=NO;[self.compactHeader addSubview:self.compactBlur];
    self.compactSeparator=[UIView new];self.compactSeparator.backgroundColor=HostSeparator();self.compactSeparator.userInteractionEnabled=NO;[self.compactHeader addSubview:self.compactSeparator];
    self.compactTitle=[UILabel new];self.compactTitle.text=@"资源";self.compactTitle.font=HostRoundedFont(17,UIFontWeightSemibold,UIFontTextStyleHeadline);self.compactTitle.textColor=HostText();self.compactTitle.userInteractionEnabled=YES;self.compactTitle.accessibilityHint=@"轻点返回页面顶部";UITapGestureRecognizer *compactTopTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(scrollToTopFromCompactHeader)];[self.compactTitle addGestureRecognizer:compactTopTap];[self.compactHeader addSubview:self.compactTitle];self.compactAdd=[UIButton buttonWithType:UIButtonTypeSystem];[self.compactAdd setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];self.compactAdd.accessibilityLabel=@"添加资源";[self.compactAdd addTarget:self action:@selector(add) forControlEvents:UIControlEventTouchUpInside];self.compactMore=[UIButton buttonWithType:UIButtonTypeSystem];[self.compactMore setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];self.compactMore.menu=moreButton.menu;self.compactMore.showsMenuAsPrimaryAction=YES;self.compactMore.accessibilityLabel=@"更多资源操作";for(UIButton *button in @[self.compactAdd,self.compactMore]){button.tintColor=HostText();button.backgroundColor=HostRaisedSurface();button.layer.cornerRadius=18;button.layer.cornerCurve=kCACornerCurveContinuous;button.layer.borderWidth=0.6;HostSetLayerBorderColor(button,HostBorder());HostInstallPressFeedback(button);[self.compactHeader addSubview:button];}
    [self reloadProfiles];
}
- (void)reloadThemeAppearance {
    if(!self.isViewLoaded)return;
    self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();
    self.tableView.backgroundColor=HostBackground();
    self.resourceHeader.backgroundColor=HostBackground();
    self.topActionsStack.backgroundColor=HostRaisedSurface();
    HostSetLayerBorderColor(self.topActionsStack,HostBorder());
    for(UIView *sub in self.topActionsStack.arrangedSubviews){
        if([sub isKindOfClass:UIButton.class]){
            UIButton *btn=(UIButton *)sub;
            UIButtonConfiguration *cfg=btn.configuration;
            if(cfg){cfg.baseForegroundColor=HostText();btn.configuration=cfg;}
        }
    }
    self.resourceTitleLabel.textColor=HostText();
    self.resourceSearchField.textColor=HostText();
    self.resourceSearchField.tintColor=HostAccent();
    self.resourceSearchField.backgroundColor=HostRaisedSurface();
    HostSetLayerBorderColor(self.resourceSearchField,HostBorder());
    self.importTaskContainer.backgroundColor=HostRaisedSurface();
    HostSetLayerBorderColor(self.importTaskContainer,[HostAccent() colorWithAlphaComponent:0.32]);
    self.importTaskButton.tintColor=HostAccent();
    self.importTaskToggleButton.tintColor=HostSecondaryText();
    self.importTaskDetailLabel.textColor=HostSecondaryText();
    self.emptyLabel.textColor=HostSecondaryText();
    self.compactHeader.backgroundColor=[HostBackground() colorWithAlphaComponent:.94];
    self.compactSeparator.backgroundColor=HostSeparator();
    self.compactTitle.textColor=HostText();
    for(UIButton *button in @[self.compactAdd,self.compactMore]){
        button.tintColor=HostText();
        button.backgroundColor=HostRaisedSurface();
        HostSetLayerBorderColor(button,HostBorder());
    }
    self.dashboardCard.backgroundColor=HostRaisedSurface();
    HostSetLayerBorderColor(self.dashboardCard,HostBorder());
    self.dashboardSummaryLabel.textColor=HostText();
    for(UILabel *valLbl in self.dashboardMetricValueLabels)valLbl.textColor=HostText();
    for(UILabel *ttlLbl in self.dashboardMetricTitleLabels)ttlLbl.textColor=HostSecondaryText();
    for(UIButton *metricBtn in self.dashboardMetricButtons){
        metricBtn.backgroundColor=HostCard();
        HostSetLayerBorderColor(metricBtn,HostBorder());
    }
    for(UIButton *quickBtn in self.dashboardQuickActionButtons){
        quickBtn.backgroundColor=HostNeutralSurface();
        quickBtn.tintColor=HostText();
        HostSetLayerBorderColor(quickBtn,HostBorder());
    }
    [self updateDashboardCard];
    [self updateSortPillButton];
    self.emptyIconView.tintColor=HostMutedText();
    HostStylePillButton(self.emptyActionButton,NO);
    [self updateKindFilters];
    [self.tableView reloadData];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if(!previousTraitCollection||!self.isViewLoaded)return;
    if([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]){
        [self.rowHeightCache removeAllObjects];
        HostRefreshAppearanceLayers(self.view.window);
        [self reloadThemeAppearance];
    }
    if(![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]){
        [self updateKindFilters];
        [self updateResourceHeaderLayoutReattaching:YES];
        [self.tableView reloadData];
    }
}
- (void)scrollToTopFromCompactHeader {
    CGFloat minY=-self.tableView.adjustedContentInset.top;
    [self.tableView setContentOffset:CGPointMake(0,minY) animated:YES];
}
- (void)handleEmptyActionTap {
    if(self.searchQuery.length){
        self.resourceSearchField.text=@"";
        self.searchQuery=@"";
        [self.resourceSearchField resignFirstResponder];
        [self reloadProfiles];
    }else if(![self.selectedKind isEqual:@"all"]){
        self.selectedKind=@"all";
        [self reloadProfiles];
    }else{
        [self add];
    }
}
- (void)showResourceToast:(NSString *)message {
    if(!message.length||!self.isViewLoaded)return;
    if(!self.toastLabel){
        UILabel *t=[UILabel new];
        t.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        t.textAlignment=NSTextAlignmentCenter;
        t.layer.cornerRadius=16;t.layer.cornerCurve=kCACornerCurveContinuous;
        t.clipsToBounds=YES;t.layer.borderWidth=0.6;
        t.alpha=0;t.userInteractionEnabled=NO;
        t.accessibilityIdentifier=@"resource.toast";
        [self.view addSubview:t];
        self.toastLabel=t;
    }
    self.toastLabel.text=[NSString stringWithFormat:@"  %@  ",message];
    self.toastLabel.textColor=HostText();
    self.toastLabel.backgroundColor=[HostCard() colorWithAlphaComponent:0.96];
    HostSetLayerBorderColor(self.toastLabel,HostBorder());
    [self.toastLabel sizeToFit];
    CGFloat w=MIN(self.view.bounds.size.width-40,MAX(120,self.toastLabel.bounds.size.width+20));
    CGFloat h=34;
    CGFloat y=MAX(self.statusBarSafeInset+56,self.tableView.contentOffset.y+self.statusBarSafeInset+58);
    self.toastLabel.frame=CGRectMake((self.view.bounds.size.width-w)/2.0,y,w,h);
    [self.view bringSubviewToFront:self.toastLabel];
    __weak typeof(self) weakSelf=self;
    NSString *captured=[message copy];
    [UIView animateWithDuration:0.18 animations:^{weakSelf.toastLabel.alpha=1.0;} completion:^(__unused BOOL f){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            if([owner.toastLabel.text containsString:captured]){
                [UIView animateWithDuration:0.22 animations:^{owner.toastLabel.alpha=0.0;}];
            }
        });
    }];
}
- (void)reloadVisibleRowForSource:(NSString *)source {
    if(!source.length||!self.isViewLoaded)return;
    NSUInteger row=[self.profiles indexOfObjectPassingTest:^BOOL(NSDictionary *profile,NSUInteger index,BOOL *stop){return [profile[@"source"] isEqual:source];}];
    if(row!=NSNotFound){
        NSIndexPath *path=[NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
        if([self.tableView.indexPathsForVisibleRows containsObject:path]){
            [UIView performWithoutAnimation:^{[self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];}];
        }
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadProfiles];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    // Child viewWillAppear runs before the navigation pop completes. Re-measure
    // the header here, but leave the saved offset for RootViewController's
    // didShow callback, after the final bar and safe-area layout has settled.
    [self updateResourceHeaderLayoutReattaching:YES];
    [NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runtimeStateDidChange) name:PyHostRuntimeStateDidChangeNotification object:nil];
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[NSNotificationCenter.defaultCenter removeObserver:self name:PyHostRuntimeStateDidChangeNotification object:nil];}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)runtimeStateDidChange {if(!NSThread.isMainThread){__weak typeof(self) weakSelf=self;dispatch_async(dispatch_get_main_queue(),^{[weakSelf runtimeStateDidChange];});return;}if(!self.isViewLoaded)return;[self reloadProfiles];}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateResourceHeaderLayout];[self layoutCompactHeader];
}
- (void)layoutCompactHeader {
    if(!self.compactHeader)return;CGFloat width=self.tableView.bounds.size.width,top=HostStatusBarSafeTop(self.view,MAX(self.statusBarSafeInset,self.view.safeAreaInsets.top));CGFloat offset=self.tableView.contentOffset.y;self.compactHeader.frame=CGRectMake(0,offset,width,top+52);self.compactBlur.frame=self.compactHeader.bounds;self.compactSeparator.frame=CGRectMake(0,top+51.5,width,0.5);self.compactTitle.frame=CGRectMake(20,top+4,MAX(1,width-132),44);self.compactAdd.frame=CGRectMake(width-104,top+4,44,44);self.compactMore.frame=CGRectMake(width-56,top+4,44,44);self.compactHeader.hidden=offset<=CGRectGetMaxY(self.topActionsStack.frame)-top;[self.tableView bringSubviewToFront:self.compactHeader];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {[self layoutCompactHeader];}
- (void)updateResourceHeaderLayout {
    [self updateResourceHeaderLayoutReattaching:NO];
}
- (void)prepareForNavigationTransition {
    if(!self.isViewLoaded)return;
    // Capture the offset at the source action, before UINavigationController
    // starts changing safe-area geometry. The navigation delegate may run
    // after UIKit has already begun adjusting the table's scroll position.
    if(self.hasNavigationReturnPosition)return;
    self.navigationReturnContentOffset=self.tableView.contentOffset;
    self.navigationReturnHeaderHeight=CGRectGetHeight(self.tableView.tableHeaderView.frame);
    self.hasNavigationReturnPosition=YES;
}
- (void)refreshHeaderAfterNavigationTransition {
    if(!self.isViewLoaded)return;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self updateResourceHeaderLayoutReattaching:YES];
    if(self.hasNavigationReturnPosition){
        UITableView *table=self.tableView;
        CGFloat minimum=-table.adjustedContentInset.top;
        CGFloat maximum=MAX(minimum,table.contentSize.height-table.bounds.size.height+table.adjustedContentInset.bottom);
        BOOL wasAtTop=self.navigationReturnContentOffset.y<=minimum+1;
        CGFloat y=wasAtTop?minimum:self.navigationReturnContentOffset.y+(CGRectGetHeight(table.tableHeaderView.frame)-self.navigationReturnHeaderHeight);
        CGPoint restored=CGPointMake(self.navigationReturnContentOffset.x,MIN(MAX(y,minimum),maximum));
        if(fabs(table.contentOffset.y-restored.y)>0.5||fabs(table.contentOffset.x-restored.x)>0.5)[table setContentOffset:restored animated:NO];
        self.hasNavigationReturnPosition=NO;
    }
}
- (void)updateResourceHeaderLayoutReattaching:(BOOL)reattach {
    UIView *header=self.resourceHeader;
    UITableView *table=self.tableView;
    CGFloat width=CGRectGetWidth(table.bounds);
    if(!header||width<=0||self.updatingResourceHeaderLayout)return;
    self.updatingResourceHeaderLayout=YES;
    UIView *oldHeader=table.tableHeaderView;
    CGFloat oldHeight=CGRectGetHeight(oldHeader.frame);
    CGPoint oldOffset=table.contentOffset;
    BOOL wasAtTop=oldOffset.y<=-table.adjustedContentInset.top+1;
    self.resourceHeaderTopConstraint.constant=MAX(0,self.statusBarSafeInset)+4;
    // UITableView caches tableHeaderView's frame independently from its Auto
    // Layout subtree. Re-measure after width/safe-area changes and explicitly
    // reattach after navigation transitions; this controller is embedded below
    // the root controller, so UIKit does not send it appearance callbacks when
    // a services/detail page is pushed and popped above the root.
    header.frame=CGRectMake(0,0,width,MAX(1,CGRectGetHeight(header.frame)));
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize fitting=[header systemLayoutSizeFittingSize:CGSizeMake(width,UIViewNoIntrinsicMetric)
                         withHorizontalFittingPriority:UILayoutPriorityRequired
                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat measured=ceil(fitting.height);
    if(measured>0&&fabs(CGRectGetHeight(header.frame)-measured)>0.5){CGRect frame=header.frame;frame.size.height=measured;header.frame=frame;}
    CGFloat newHeight=CGRectGetHeight(header.frame);
    BOOL needsAttach=reattach||oldHeader!=header||fabs(CGRectGetWidth(oldHeader.frame)-width)>0.5||fabs(oldHeight-newHeight)>0.5;
    if(needsAttach){
        table.tableHeaderView=header;
        if(oldHeader==header){
            CGFloat minimum=-table.adjustedContentInset.top;
            CGFloat maximum=MAX(minimum,table.contentSize.height-table.bounds.size.height+table.adjustedContentInset.bottom);
            CGFloat y=wasAtTop?minimum:oldOffset.y+(newHeight-oldHeight);
            CGPoint restored=CGPointMake(oldOffset.x,MIN(MAX(y,minimum),maximum));
            if(fabs(table.contentOffset.y-restored.y)>0.5||fabs(table.contentOffset.x-restored.x)>0.5)[table setContentOffset:restored animated:NO];
        }
    }
    self.updatingResourceHeaderLayout=NO;
}
- (void)setTopSafeAreaInset:(CGFloat)inset {if(!isfinite(inset))inset=0;inset=HostStatusBarSafeTop(self.view,MAX(0,inset));if(fabs(self.statusBarSafeInset-inset)<0.5)return;self.statusBarSafeInset=inset;if(self.isViewLoaded)[self updateResourceHeaderLayout];}
- (void)setBottomOverlayInset:(CGFloat)inset {
    if(!isfinite(inset))inset=0;
    inset=MAX(8,inset);
    if(fabs(_bottomOverlayInset-inset)<0.01)return;
    _bottomOverlayInset=inset;
    if(!self.isViewLoaded)return;
    self.tableView.contentInset=UIEdgeInsetsMake(0,0,inset,0);
    self.tableView.scrollIndicatorInsets=self.tableView.contentInset;
}
- (BOOL)profile:(NSDictionary *)profile matchesKind:(NSString *)kind {
    NSString *resourceKind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"unknown";
    NSString *status=[profile[@"status"] isKindOfClass:NSString.class]?profile[@"status"]:@"";
    NSString *playlistStatus=[profile[@"subscriptionStatus"] isKindOfClass:NSString.class]?profile[@"subscriptionStatus"]:@"";
    BOOL pending=[resourceKind isEqual:@"unknown"]||[status containsString:@"失败"]||[status containsString:@"异常"]||[status containsString:@"错误"]||[playlistStatus containsString:@"失败"]||[playlistStatus containsString:@"异常"]||[playlistStatus containsString:@"错误"];
    if([kind isEqual:@"all"])return YES;
    if([kind isEqual:@"vod"])return [resourceKind isEqual:@"vod"]||[resourceKind isEqual:@"both"];
    if([kind isEqual:@"live"])return [resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"];
    if([kind isEqual:@"catalog"])return [profile[@"type"] isEqual:@"tvbox"];
    if([kind isEqual:@"script"])return [profile[@"type"] isEqual:@"plugin"];
    if([kind isEqual:@"enabled"])return [profile[@"enabled"] boolValue];
    if([kind isEqual:@"attention"])return pending;
    if([kind hasPrefix:@"domain:"]){NSArray *parts=[[kind substringFromIndex:7] componentsSeparatedByString:@"|"];NSString *expectedHost=parts.firstObject?:@"",*expectedKind=parts.count>1?parts[1]:@"";NSString *raw=[profile[@"url"] isKindOfClass:NSString.class]?profile[@"url"]:@"";if(!raw.length)raw=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";NSString *host=[NSURLComponents componentsWithString:raw].host.lowercaseString?:@"";if(![host isEqual:expectedHost])return NO;if([expectedKind isEqual:@"live"])return [resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"];if([expectedKind isEqual:@"vod"])return [resourceKind isEqual:@"vod"]||[resourceKind isEqual:@"both"]||[profile[@"type"] isEqual:@"tvbox"];return YES;}
    return YES;
}
- (NSString *)resourceDomainForProfile:(NSDictionary *)profile {
    NSString *raw=[profile[@"url"] isKindOfClass:NSString.class]?profile[@"url"]:@"";if(!raw.length)raw=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";NSString *host=[NSURLComponents componentsWithString:raw].host.lowercaseString;return host?:@"";
}
- (void)updateKindFilters {
    if(!self.kindStack)return;
    NSMutableArray *definitions=[@[@{@"id":@"all",@"name":@"全部"},@{@"id":@"vod",@"name":@"影视"},@{@"id":@"live",@"name":@"直播"},@{@"id":@"catalog",@"name":@"合集"},@{@"id":@"attention",@"name":@"待处理"}] mutableCopy];
    NSMutableDictionary<NSString *,NSMutableDictionary *> *domains=[NSMutableDictionary dictionary];
    for(NSDictionary *profile in self.allProfiles){NSString *host=[self resourceDomainForProfile:profile];if(!host.length)continue;NSString *resourceKind=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"unknown";NSString *kind=([resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"])?@"live":([resourceKind isEqual:@"vod"]||[profile[@"type"] isEqual:@"tvbox"]?@"vod":@"unknown");NSString *identifier=[NSString stringWithFormat:@"domain:%@|%@",host,kind];NSMutableDictionary *entry=domains[identifier]?:[NSMutableDictionary dictionaryWithDictionary:@{@"id":identifier,@"host":host,@"kind":kind,@"count":@0}];entry[@"count"]=@([entry[@"count"] unsignedIntegerValue]+1);domains[identifier]=entry;}
    NSArray *domainEntries=[domains.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"host"] localizedStandardCompare:b[@"host"]];}];
    if([self.selectedKind isEqual:@"script"])[definitions addObject:@{@"id":@"script",@"name":@"脚本"}];
    if([self.selectedKind isEqual:@"enabled"])[definitions addObject:@{@"id":@"enabled",@"name":@"已启用"}];
    for(NSDictionary *entry in domainEntries)if([entry[@"id"] isEqual:self.selectedKind]){[definitions addObject:@{@"id":entry[@"id"],@"name":entry[@"host"],@"fixedCount":entry[@"count"]}];break;}
    if([self.selectedKind hasPrefix:@"domain:"]&&![self.selectedKind containsString:@"|"])[definitions addObject:@{@"id":self.selectedKind,@"name":[self.selectedKind substringFromIndex:7]}];
    BOOL selectionExists=NO;for(NSDictionary *definition in definitions)if([definition[@"id"] isEqual:self.selectedKind]){selectionExists=YES;break;}if(!selectionExists)self.selectedKind=@"all";
    if(self.kindFilterButtons.count!=definitions.count){
        for(UIView *view in self.kindStack.arrangedSubviews.copy){[self.kindStack removeArrangedSubview:view];[view removeFromSuperview];}
        NSMutableArray<UIButton *> *buttons=[NSMutableArray arrayWithCapacity:definitions.count];
        for(NSDictionary *definition in definitions){
            NSString *identifier=definition[@"id"];
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            button.accessibilityIdentifier=[@"resource-filter-" stringByAppendingString:identifier];
            button.titleLabel.adjustsFontForContentSizeCategory=YES;
            button.contentEdgeInsets=UIEdgeInsetsMake(7,12,7,12);
            button.layer.cornerRadius=16;
            [button addTarget:self action:@selector(selectKind:) forControlEvents:UIControlEventTouchUpInside];
            [self.kindStack addArrangedSubview:button];
            [buttons addObject:button];
        }
        self.kindFilterButtons=buttons;
    }
    for(NSUInteger index=0;index<definitions.count;index++){
        NSDictionary *definition=definitions[index];
        NSString *identifier=definition[@"id"];
        NSUInteger count=[definition[@"fixedCount"] unsignedIntegerValue];
        if(!definition[@"fixedCount"])for(NSDictionary *profile in self.allProfiles)if([self profile:profile matchesKind:identifier])count++;
        UIButton *button=self.kindFilterButtons[index];
        button.accessibilityIdentifier=[@"resource-filter-" stringByAppendingString:identifier];
        BOOL selected=[identifier isEqual:self.selectedKind];
        HostStylePillButton(button,selected);
        button.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        button.titleLabel.adjustsFontForContentSizeCategory=YES;
        button.contentEdgeInsets=UIEdgeInsetsMake(7,12,7,12);
        button.layer.cornerRadius=16;
        button.accessibilityLabel=[NSString stringWithFormat:@"%@，%lu 项",definition[@"name"],(unsigned long)count];
        button.accessibilityTraits=selected?(UIAccessibilityTraitButton|UIAccessibilityTraitSelected):UIAccessibilityTraitButton;
        [button setTitle:[NSString stringWithFormat:@"%@ %lu",definition[@"name"],(unsigned long)count] forState:UIControlStateNormal];
    }
    CGFloat pillHeight=MAX(44,ceil([UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline].lineHeight)+18);
    self.kindScrollHeightConstraint.constant=pillHeight+4;
    for(UIButton *button in self.kindFilterButtons)button.layer.cornerRadius=MIN(20,pillHeight/2);
}
- (void)copyResourceDiagnosticSummary {
    NSUInteger enabledSubscriptions=0,enabledServices=0,catalogs=0,runningServices=0,attentionCount=0;
    for(NSDictionary *p in self.allProfiles){
        if([self profile:p matchesKind:@"attention"])attentionCount++;
        if([p[@"type"] isEqual:@"plugin"]){if([p[@"enabled"] boolValue])enabledServices++;NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";NSString *identifier=[source hasPrefix:@"plugin:"]?[source substringFromIndex:7]:@"";if(identifier.length&&[PyHost isRunningServiceIdentifier:identifier])runningServices++;}
        else if([p[@"type"] isEqual:@"tvbox"])catalogs++;
        else if([p[@"enabled"] boolValue])enabledSubscriptions++;
    }
    NSMutableArray<NSString *> *lines=[NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"CCTVHost 资源概览 · 共 %lu 项（合集 %lu · 订阅启用 %lu · 服务启用 %lu · 运行中 %lu · 待处理 %lu）",(unsigned long)self.allProfiles.count,(unsigned long)catalogs,(unsigned long)enabledSubscriptions,(unsigned long)enabledServices,(unsigned long)runningServices,(unsigned long)attentionCount]];
    for(NSDictionary *p in self.profiles){
        NSString *name=[self resourceTitleForProfile:p];
        NSString *type=[p[@"type"] isEqual:@"plugin"]?@"服务":([p[@"type"] isEqual:@"tvbox"]?@"合集":@"订阅");
        NSString *latency=[self latencyTextForProfile:p color:NULL];
        NSString *status=[p[@"status"] isKindOfClass:NSString.class]&&[p[@"status"] length]?p[@"status"]:([p[@"enabled"] boolValue]?@"已启用":@"未启用");
        [lines addObject:[NSString stringWithFormat:@"- [%@] %@ · %@ · 测速:%@",type,name,status,latency]];
    }
    UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:[lines componentsJoinedByString:@"\n"]];
    [self showResourceToast:@"资源概览摘要已复制"];
}
- (void)buildDashboardCard {
    self.dashboardCard=[UIView new];
    self.dashboardCard.translatesAutoresizingMaskIntoConstraints=NO;
    self.dashboardCard.backgroundColor=HostRaisedSurface();
    self.dashboardCard.layer.cornerRadius=16;
    self.dashboardCard.layer.cornerCurve=kCACornerCurveContinuous;
    self.dashboardCard.layer.borderWidth=0.65;
    HostSetLayerBorderColor(self.dashboardCard,HostBorder());
    self.dashboardCard.accessibilityIdentifier=@"resource.dashboard.card";
    [self.resourceHeader addSubview:self.dashboardCard];

    self.dashboardSummaryLabel=[UILabel new];
    self.dashboardSummaryLabel.translatesAutoresizingMaskIntoConstraints=NO;
    self.dashboardSummaryLabel.font=HostRoundedFont(13,UIFontWeightSemibold,UIFontTextStyleSubheadline);
    self.dashboardSummaryLabel.textColor=HostText();
    self.dashboardSummaryLabel.text=@"资源架构总览";
    [self.dashboardCard addSubview:self.dashboardSummaryLabel];

    self.dashboardHealthBadge=[UILabel new];
    self.dashboardHealthBadge.translatesAutoresizingMaskIntoConstraints=NO;
    self.dashboardHealthBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightBold,UIFontTextStyleCaption2);
    self.dashboardHealthBadge.textAlignment=NSTextAlignmentCenter;
    self.dashboardHealthBadge.layer.cornerRadius=7;
    self.dashboardHealthBadge.layer.cornerCurve=kCACornerCurveContinuous;
    self.dashboardHealthBadge.layer.borderWidth=0.5;
    self.dashboardHealthBadge.clipsToBounds=YES;
    self.dashboardHealthBadge.accessibilityIdentifier=@"resource.dashboard.health";
    [self.dashboardCard addSubview:self.dashboardHealthBadge];

    self.dashboardMetricsStack=[UIStackView new];
    self.dashboardMetricsStack.translatesAutoresizingMaskIntoConstraints=NO;
    self.dashboardMetricsStack.axis=UILayoutConstraintAxisHorizontal;
    self.dashboardMetricsStack.distribution=UIStackViewDistributionFillEqually;
    self.dashboardMetricsStack.spacing=8;
    [self.dashboardCard addSubview:self.dashboardMetricsStack];

    NSArray<NSDictionary *> *metricSpecs=@[
        @{@"id":@"all",@"title":@"总资源"},
        @{@"id":@"script",@"title":@"运行服务"},
        @{@"id":@"catalog",@"title":@"合集/接口"},
        @{@"id":@"attention",@"title":@"待处理"}
    ];
    NSMutableArray<UILabel *> *valLabels=[NSMutableArray arrayWithCapacity:4];
    NSMutableArray<UILabel *> *ttlLabels=[NSMutableArray arrayWithCapacity:4];
    NSMutableArray<UIButton *> *mButtons=[NSMutableArray arrayWithCapacity:4];
    for(NSUInteger i=0;i<metricSpecs.count;i++){
        NSDictionary *spec=metricSpecs[i];
        UIButton *tile=[UIButton buttonWithType:UIButtonTypeCustom];
        tile.translatesAutoresizingMaskIntoConstraints=NO;
        tile.tag=(NSInteger)i;
        tile.backgroundColor=HostCard();
        tile.layer.cornerRadius=11;
        tile.layer.cornerCurve=kCACornerCurveContinuous;
        tile.layer.borderWidth=0.55;
        HostSetLayerBorderColor(tile,HostBorder());
        tile.accessibilityIdentifier=[@"resource-metric-" stringByAppendingString:spec[@"id"]];
        HostInstallPressFeedback(tile);
        [tile addTarget:self action:@selector(handleDashboardMetricTap:) forControlEvents:UIControlEventTouchUpInside];

        UILabel *vLbl=[UILabel new];
        vLbl.translatesAutoresizingMaskIntoConstraints=NO;
        vLbl.font=HostMonospacedDigitFont(16,UIFontWeightBold,UIFontTextStyleHeadline);
        vLbl.textColor=HostText();
        vLbl.textAlignment=NSTextAlignmentCenter;
        vLbl.text=@"0";
        vLbl.userInteractionEnabled=NO;
        [tile addSubview:vLbl];

        UILabel *tLbl=[UILabel new];
        tLbl.translatesAutoresizingMaskIntoConstraints=NO;
        tLbl.font=[UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
        tLbl.textColor=HostSecondaryText();
        tLbl.textAlignment=NSTextAlignmentCenter;
        tLbl.text=spec[@"title"];
        tLbl.userInteractionEnabled=NO;
        [tile addSubview:tLbl];

        [NSLayoutConstraint activateConstraints:@[
            [vLbl.topAnchor constraintEqualToAnchor:tile.topAnchor constant:7],
            [vLbl.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:2],
            [vLbl.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-2],
            [tLbl.topAnchor constraintEqualToAnchor:vLbl.bottomAnchor constant:2],
            [tLbl.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:2],
            [tLbl.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-2],
            [tLbl.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-6]
        ]];
        [self.dashboardMetricsStack addArrangedSubview:tile];
        [valLabels addObject:vLbl];
        [ttlLabels addObject:tLbl];
        [mButtons addObject:tile];
    }
    self.dashboardMetricValueLabels=valLabels;
    self.dashboardMetricTitleLabels=ttlLabels;
    self.dashboardMetricButtons=mButtons;

    self.dashboardActionsStack=[UIStackView new];
    self.dashboardActionsStack.translatesAutoresizingMaskIntoConstraints=NO;
    self.dashboardActionsStack.axis=UILayoutConstraintAxisHorizontal;
    self.dashboardActionsStack.distribution=UIStackViewDistributionFillEqually;
    self.dashboardActionsStack.spacing=8;
    [self.dashboardCard addSubview:self.dashboardActionsStack];

    NSArray<NSDictionary *> *quickSpecs=@[
        @{@"id":@"probe",@"title":@"⚡ 一键测速",@"sel":NSStringFromSelector(@selector(probeResources))},
        @{@"id":@"services",@"title":@"🎛 脚本服务",@"sel":NSStringFromSelector(@selector(openServices))},
        @{@"id":@"monitor",@"title":@"📈 适配监测",@"sel":NSStringFromSelector(@selector(openAdaptationMonitor))},
        @{@"id":@"summary",@"title":@"📋 复制摘要",@"sel":NSStringFromSelector(@selector(copyResourceDiagnosticSummary))}
    ];
    NSMutableArray<UIButton *> *qButtons=[NSMutableArray arrayWithCapacity:4];
    for(NSDictionary *qSpec in quickSpecs){
        UIButton *qBtn=[UIButton buttonWithType:UIButtonTypeSystem];
        qBtn.translatesAutoresizingMaskIntoConstraints=NO;
        [qBtn setTitle:qSpec[@"title"] forState:UIControlStateNormal];
        qBtn.titleLabel.font=[UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        qBtn.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        qBtn.tintColor=HostText();
        qBtn.backgroundColor=HostNeutralSurface();
        qBtn.layer.cornerRadius=9.5;
        qBtn.layer.cornerCurve=kCACornerCurveContinuous;
        qBtn.layer.borderWidth=0.55;
        HostSetLayerBorderColor(qBtn,HostBorder());
        qBtn.accessibilityIdentifier=[@"resource-quick." stringByAppendingString:qSpec[@"id"]];
        HostInstallPressFeedback(qBtn);
        [qBtn addTarget:self action:NSSelectorFromString(qSpec[@"sel"]) forControlEvents:UIControlEventTouchUpInside];
        [qBtn.heightAnchor constraintEqualToConstant:31].active=YES;
        [self.dashboardActionsStack addArrangedSubview:qBtn];
        [qButtons addObject:qBtn];
    }
    self.dashboardQuickActionButtons=qButtons;

    [NSLayoutConstraint activateConstraints:@[
        [self.dashboardSummaryLabel.leadingAnchor constraintEqualToAnchor:self.dashboardCard.leadingAnchor constant:13],
        [self.dashboardSummaryLabel.topAnchor constraintEqualToAnchor:self.dashboardCard.topAnchor constant:11],
        [self.dashboardHealthBadge.trailingAnchor constraintEqualToAnchor:self.dashboardCard.trailingAnchor constant:-12],
        [self.dashboardHealthBadge.centerYAnchor constraintEqualToAnchor:self.dashboardSummaryLabel.centerYAnchor],
        [self.dashboardHealthBadge.heightAnchor constraintEqualToConstant:20],
        [self.dashboardSummaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.dashboardHealthBadge.leadingAnchor constant:-8],
        [self.dashboardMetricsStack.leadingAnchor constraintEqualToAnchor:self.dashboardCard.leadingAnchor constant:11],
        [self.dashboardMetricsStack.trailingAnchor constraintEqualToAnchor:self.dashboardCard.trailingAnchor constant:-11],
        [self.dashboardMetricsStack.topAnchor constraintEqualToAnchor:self.dashboardSummaryLabel.bottomAnchor constant:9],
        [self.dashboardActionsStack.leadingAnchor constraintEqualToAnchor:self.dashboardCard.leadingAnchor constant:11],
        [self.dashboardActionsStack.trailingAnchor constraintEqualToAnchor:self.dashboardCard.trailingAnchor constant:-11],
        [self.dashboardActionsStack.topAnchor constraintEqualToAnchor:self.dashboardMetricsStack.bottomAnchor constant:8],
        [self.dashboardActionsStack.bottomAnchor constraintEqualToAnchor:self.dashboardCard.bottomAnchor constant:-11]
    ]];
}

- (void)handleDashboardMetricTap:(UIButton *)sender {
    NSArray<NSString *> *kinds=@[@"all",@"script",@"catalog",@"attention"];
    if(sender.tag<0||sender.tag>=(NSInteger)kinds.count)return;
    NSString *targetKind=kinds[(NSUInteger)sender.tag];
    self.selectedKind=([self.selectedKind isEqualToString:targetKind]&&![targetKind isEqualToString:@"all"])?@"all":targetKind;
    HostAnimateSelection(sender);
    [self reloadProfiles];
}

- (void)updateDashboardCard {
    if(!self.dashboardCard)return;
    NSUInteger total=self.allProfiles.count,enabledSubs=0,totalServices=0,runningServices=0,catalogs=0,attention=0;
    for(NSDictionary *p in self.allProfiles){
        if([self profile:p matchesKind:@"attention"])attention++;
        if([p[@"type"] isEqual:@"plugin"]){
            totalServices++;
            NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
            NSString *identifier=[source hasPrefix:@"plugin:"]?[source substringFromIndex:7]:@"";
            if(identifier.length&&[PyHost isRunningServiceIdentifier:identifier])runningServices++;
        }else if([p[@"type"] isEqual:@"tvbox"]){
            catalogs++;
        }else if([p[@"enabled"] boolValue]){
            enabledSubs++;
        }
    }
    self.dashboardSummaryLabel.text=[NSString stringWithFormat:@"资源架构总览 · 订阅启用 %lu 项",(unsigned long)enabledSubs];
    if(self.probingResources){
        self.dashboardHealthBadge.text=@"  ⚡ 测速中…  ";
        self.dashboardHealthBadge.textColor=UIColor.systemOrangeColor;
        self.dashboardHealthBadge.backgroundColor=[UIColor.systemOrangeColor colorWithAlphaComponent:0.14];
        HostSetLayerBorderColor(self.dashboardHealthBadge,[UIColor.systemOrangeColor colorWithAlphaComponent:0.35]);
    }else if(attention>0){
        self.dashboardHealthBadge.text=[NSString stringWithFormat:@"  ⚠ %lu 待处理  ",(unsigned long)attention];
        self.dashboardHealthBadge.textColor=UIColor.systemOrangeColor;
        self.dashboardHealthBadge.backgroundColor=[UIColor.systemOrangeColor colorWithAlphaComponent:0.14];
        HostSetLayerBorderColor(self.dashboardHealthBadge,[UIColor.systemOrangeColor colorWithAlphaComponent:0.35]);
    }else{
        self.dashboardHealthBadge.text=@"  ● 状态良好  ";
        UIColor *okColor=[UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1.0];
        self.dashboardHealthBadge.textColor=okColor;
        self.dashboardHealthBadge.backgroundColor=HostSuccessSurface();
        HostSetLayerBorderColor(self.dashboardHealthBadge,[okColor colorWithAlphaComponent:0.36]);
    }
    NSArray<NSString *> *values=@[
        [NSString stringWithFormat:@"%lu",(unsigned long)total],
        [NSString stringWithFormat:@"%lu/%lu",(unsigned long)runningServices,(unsigned long)totalServices],
        [NSString stringWithFormat:@"%lu",(unsigned long)catalogs],
        [NSString stringWithFormat:@"%lu",(unsigned long)attention]
    ];
    NSArray<NSString *> *kinds=@[@"all",@"script",@"catalog",@"attention"];
    for(NSUInteger i=0;i<self.dashboardMetricValueLabels.count&&i<values.count;i++){
        self.dashboardMetricValueLabels[i].text=values[i];
        BOOL active=[self.selectedKind isEqualToString:kinds[i]];
        UIButton *tile=self.dashboardMetricButtons[i];
        tile.backgroundColor=active?HostSelectedSurface():HostCard();
        HostSetLayerBorderColor(tile,active?[HostAccent() colorWithAlphaComponent:0.45]:HostBorder());
        self.dashboardMetricValueLabels[i].textColor=active?HostAccent():(i==3&&attention>0?UIColor.systemOrangeColor:HostText());
    }
    if(self.dashboardQuickActionButtons.count>0){
        UIButton *probeBtn=self.dashboardQuickActionButtons[0];
        [probeBtn setTitle:self.probingResources?@"⚡ 测速中…":@"⚡ 一键测速" forState:UIControlStateNormal];
    }
}

- (NSString *)capabilityTagForProfile:(NSDictionary *)profile {
    if([profile[@"native"] boolValue])return @"  官方直连  ";
    BOOL plugin=[profile[@"type"] isEqual:@"plugin"],tvbox=[profile[@"type"] isEqual:@"tvbox"];
    if(tvbox){
        BOOL macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];
        return macCMS?@"  影视接口  ":@"  多站合集  ";
    }
    NSString *rk=[profile[@"resourceKind"] isKindOfClass:NSString.class]?profile[@"resourceKind"]:@"";
    if([rk isEqual:@"both"])return @"  影视+直播  ";
    if([rk isEqual:@"vod"])return @"  影视点播  ";
    if([rk isEqual:@"live"]||!plugin)return @"  直播频道  ";
    return @"  智能扩展  ";
}

- (NSString *)semanticIconNameForProfile:(NSDictionary *)profile tintColor:(UIColor * __autoreleasing *)tintColorOut {
    UIColor *tint=HostAccent();
    NSString *icon=@"dot.radiowaves.left.and.right";
    if([profile[@"native"] boolValue]){
        icon=@"sparkles.tv";
        tint=HostAccent();
    }else if([profile[@"type"] isEqual:@"tvbox"]){
        BOOL macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];
        icon=macCMS?@"film.stack.fill":@"square.stack.3d.up.fill";
        tint=macCMS?[UIColor colorWithRed:0.96 green:0.58 blue:0.14 alpha:1.0]:[UIColor colorWithRed:0.42 green:0.46 blue:0.98 alpha:1.0];
    }else if([profile[@"type"] isEqual:@"plugin"]){
        NSString *runtime=[[profile[@"runtime"] description] lowercaseString]?:@"";
        icon=([runtime containsString:@"js"]||[runtime containsString:@"node"])?@"bolt.horizontal.circle.fill":@"terminal.fill";
        NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
        NSString *identifier=[source hasPrefix:@"plugin:"]?[source substringFromIndex:7]:@"";
        BOOL running=identifier.length&&[PyHost isRunningServiceIdentifier:identifier];
        tint=running?[UIColor colorWithRed:0.18 green:0.80 blue:0.44 alpha:1.0]:HostAccent();
    }else{
        icon=@"dot.radiowaves.left.and.right";
        tint=[profile[@"enabled"] boolValue]?[UIColor colorWithRed:0.20 green:0.66 blue:0.98 alpha:1.0]:HostMutedText();
    }
    if(tintColorOut)*tintColorOut=tint;
    return icon;
}

- (NSAttributedString *)attributedDetailForText:(NSString *)detailText font:(UIFont *)font {
    if(!detailText.length)return nil;
    NSMutableParagraphStyle *detailPara=[NSMutableParagraphStyle new];
    detailPara.lineBreakMode=NSLineBreakByCharWrapping;
    detailPara.lineSpacing=3.4;
    detailPara.paragraphSpacing=2.5;
    UIFont *baseFont=font?:HostMonospacedDigitFont(12.5,UIFontWeightRegular,UIFontTextStyleFootnote);
    UIFont *firstLineFont=HostMonospacedDigitFont(12.5,UIFontWeightSemibold,UIFontTextStyleFootnote);
    NSMutableAttributedString *attrDetail=[[NSMutableAttributedString alloc] initWithString:detailText attributes:@{
        NSFontAttributeName:baseFont,
        NSForegroundColorAttributeName:HostSecondaryText(),
        NSParagraphStyleAttributeName:detailPara
    }];
    NSRange firstNewline=[detailText rangeOfString:@"\n"];
    NSRange firstLineRange=firstNewline.location!=NSNotFound?NSMakeRange(0,firstNewline.location):NSMakeRange(0,detailText.length);
    [attrDetail addAttributes:@{
        NSForegroundColorAttributeName:[HostText() colorWithAlphaComponent:0.90],
        NSFontAttributeName:firstLineFont
    } range:firstLineRange];
    for(NSString *okWord in @[@"运行中",@"已启用",@"健康",@"内置官方源 · 实时同步"]){
        NSRange r=[detailText rangeOfString:okWord];
        if(r.location!=NSNotFound)[attrDetail addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:0.95] range:r];
    }
    for(NSString *warnWord in @[@"失败",@"异常",@"错误",@"超时",@"不可用"]){
        NSRange r=[detailText rangeOfString:warnWord];
        if(r.location!=NSNotFound)[attrDetail addAttribute:NSForegroundColorAttributeName value:UIColor.systemOrangeColor range:r];
    }
    NSRange currentRange=[detailText rangeOfString:@"当前使用"];
    if(currentRange.location!=NSNotFound)[attrDetail addAttribute:NSForegroundColorAttributeName value:HostAccent() range:currentRange];
    return attrDetail;
}

- (void)updateSortPillButton {
    if(!self.sortFilterButton)return;
    NSDictionary *shortLabels=@{@"manual":@"⇅ 手动",@"name":@"⇅ A–Z",@"recent":@"⇅ 最近",@"attention":@"⇅ 待处理",@"latency":@"⇅ 测速"};
    NSString *shortTitle=shortLabels[self.sortMode]?:@"⇅ 手动";
    BOOL customSort=![self.sortMode isEqual:@"manual"];
    [self.sortFilterButton setTitle:shortTitle forState:UIControlStateNormal];
    self.sortFilterButton.backgroundColor=customSort?HostSelectedSurface():HostNeutralSurface();
    self.sortFilterButton.tintColor=customSort?HostAccent():HostSecondaryText();
    HostSetLayerBorderColor(self.sortFilterButton,customSort?[HostAccent() colorWithAlphaComponent:0.35]:HostBorder());
    self.sortFilterButton.accessibilityLabel=[NSString stringWithFormat:@"资源排序：%@",shortTitle];
    __weak typeof(self) weakSelf=self;
    NSArray *sortOptions=@[@{@"id":@"manual",@"name":@"手动顺序",@"icon":@"line.3.horizontal"},@{@"id":@"name",@"name":@"名称 A–Z",@"icon":@"textformat.abc"},@{@"id":@"recent",@"name":@"最近更新",@"icon":@"clock"},@{@"id":@"attention",@"name":@"待处理优先",@"icon":@"exclamationmark.triangle"},@{@"id":@"latency",@"name":@"测速最快优先",@"icon":@"gauge.with.needle"}];
    NSMutableArray<UIMenuElement *> *children=[NSMutableArray array];
    for(NSDictionary *option in sortOptions){
        NSString *identifier=option[@"id"],*name=option[@"name"],*icon=option[@"icon"];
        UIAction *action=[UIAction actionWithTitle:name image:[UIImage systemImageNamed:icon] identifier:nil handler:^(__unused UIAction *a){
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            owner.sortMode=identifier;
            [NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"resourceListSortMode"];
            [owner reloadProfiles];
        }];
        action.state=[identifier isEqual:self.sortMode]?UIMenuElementStateOn:UIMenuElementStateOff;
        [children addObject:action];
    }
    UIAction *moreFilter=[UIAction actionWithTitle:@"筛选与诊断摘要…" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] identifier:nil handler:^(__unused UIAction *a){[weakSelf showResourceFilters];}];
    [children addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[moreFilter]]];
    self.sortFilterButton.menu=[UIMenu menuWithTitle:@"资源排序方式" children:children];
}
- (NSString *)statusBadgeTextForProfile:(NSDictionary *)profile textColor:(UIColor * __autoreleasing *)textColorOut backgroundColor:(UIColor * __autoreleasing *)bgColorOut borderColor:(UIColor * __autoreleasing *)borderColorOut {
    BOOL isCurrent=[profile[@"current"] boolValue];
    BOOL plugin=[profile[@"type"] isEqual:@"plugin"],tvbox=[profile[@"type"] isEqual:@"tvbox"];
    BOOL attention=[self profile:profile matchesKind:@"attention"];
    UIColor *textColor=HostSecondaryText(),*bgColor=HostNeutralSurface(),*borderColor=HostBorder();
    NSString *text=@"  ● 就绪  ";
    if(isCurrent){
        text=@"  ● 当前使用  ";
        textColor=HostAccent();
        bgColor=HostSelectedSurface();
        borderColor=[HostAccent() colorWithAlphaComponent:0.38];
    }else if(attention){
        text=@"  ⚠ 待处理  ";
        textColor=UIColor.systemOrangeColor;
        bgColor=[UIColor.systemOrangeColor colorWithAlphaComponent:0.14];
        borderColor=[UIColor.systemOrangeColor colorWithAlphaComponent:0.35];
    }else if(plugin){
        NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
        NSString *identifier=[source hasPrefix:@"plugin:"]?[source substringFromIndex:7]:@"";
        BOOL running=identifier.length&&[PyHost isRunningServiceIdentifier:identifier];
        if(running){
            text=@"  ● 运行中  ";
            textColor=[UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1.0];
            bgColor=HostSuccessSurface();
            borderColor=[textColor colorWithAlphaComponent:0.36];
        }else if([profile[@"enabled"] boolValue]){
            text=@"  ● 已启用  ";
            textColor=HostAccent();
            bgColor=HostSelectedSurface();
            borderColor=[HostAccent() colorWithAlphaComponent:0.28];
        }else{
            text=@"  ○ 按需启动  ";
            textColor=HostMutedText();
            bgColor=HostNeutralSurface();
            borderColor=HostBorder();
        }
    }else if(tvbox){
        NSUInteger supported=[profile[@"supportedCount"] unsignedIntegerValue];
        text=supported>0?[NSString stringWithFormat:@"  ● %lu 可用  ",(unsigned long)supported]:@"  ● 按需加载  ";
        textColor=HostSecondaryText();
        bgColor=HostRaisedSurface();
        borderColor=HostBorder();
    }else{
        BOOL enabled=[profile[@"enabled"] boolValue];
        text=enabled?@"  ● 已启用  ":@"  ○ 已停用  ";
        textColor=enabled?HostAccent():HostMutedText();
        bgColor=enabled?HostSelectedSurface():HostNeutralSurface();
        borderColor=enabled?[HostAccent() colorWithAlphaComponent:0.28]:HostBorder();
    }
    if(textColorOut)*textColorOut=textColor;
    if(bgColorOut)*bgColorOut=bgColor;
    if(borderColorOut)*borderColorOut=borderColor;
    return text;
}
- (void)showResourceFilters {
    NSString *sortName=@{@"manual":@"手动顺序",@"name":@"名称 A–Z",@"recent":@"最近更新",@"attention":@"待处理优先",@"latency":@"测速最快优先"}[self.sortMode]?:@"手动顺序";
    NSArray *sortOptions=@[@{@"id":@"manual",@"name":@"手动顺序",@"icon":@"line.3.horizontal"},@{@"id":@"name",@"name":@"名称 A–Z",@"icon":@"textformat.abc"},@{@"id":@"recent",@"name":@"最近更新",@"icon":@"clock"},@{@"id":@"attention",@"name":@"待处理优先",@"icon":@"exclamationmark.triangle"},@{@"id":@"latency",@"name":@"测速最快优先",@"icon":@"gauge.with.needle"}];
    __weak typeof(self) weakSelf=self;
    NSMutableArray<HostGlassSheetAction *> *sortActions=[NSMutableArray array];
    for(NSDictionary *option in sortOptions){
        NSString *identifier=option[@"id"],*name=option[@"name"],*icon=option[@"icon"];
        [sortActions addObject:[HostGlassSheetAction actionWithTitle:name subtitle:nil value:nil icon:icon tint:HostAccent() destructive:NO selected:[identifier isEqual:self.sortMode] handler:^{
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            owner.sortMode=identifier;[NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"resourceListSortMode"];[owner reloadProfiles];
        }]];
    }
    NSMutableArray *options=[NSMutableArray arrayWithArray:@[@{@"id":@"all",@"name":@"全部来源",@"icon":@"tray.full"},@{@"id":@"enabled",@"name":@"仅已启用资源",@"icon":@"checkmark.circle"},@{@"id":@"script",@"name":@"脚本资源",@"icon":@"terminal"}]];
    NSMutableSet *seen=[NSMutableSet set];for(NSDictionary *profile in self.allProfiles){NSString *domain=[self resourceDomainForProfile:profile];if(!domain.length||[seen containsObject:domain])continue;[seen addObject:domain];[options addObject:@{@"id":[@"domain:" stringByAppendingString:domain],@"name":domain,@"icon":@"globe"}];}
    NSMutableArray<HostGlassSheetAction *> *sourceActions=[NSMutableArray array];
    for(NSDictionary *option in options){
        NSString *identifier=option[@"id"],*name=option[@"name"],*icon=option[@"icon"];
        [sourceActions addObject:[HostGlassSheetAction actionWithTitle:name subtitle:nil value:nil icon:icon tint:UIColor.systemBlueColor destructive:NO selected:[identifier isEqual:self.selectedKind] handler:^{
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            owner.selectedKind=identifier;[owner reloadProfiles];
        }]];
    }
    NSMutableArray<HostGlassSheetAction *> *toolActions=[NSMutableArray arrayWithObject:[HostGlassSheetAction actionWithTitle:@"复制资源概览摘要" subtitle:@"复制当前合集、订阅与运行态统计" value:nil icon:@"doc.on.doc" tint:UIColor.systemTealColor destructive:NO selected:NO handler:^{
        [weakSelf copyResourceDiagnosticSummary];
    }]];
    if(self.latencyResults.count){
        [toolActions addObject:[HostGlassSheetAction actionWithTitle:@"清除连接测速结果" subtitle:@"重置所有节点的响应延迟记录" value:nil icon:@"arrow.counterclockwise" tint:UIColor.systemOrangeColor destructive:NO selected:NO handler:^{
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            [owner.latencyResults removeAllObjects];[owner updateDashboardCard];[owner.tableView reloadData];[owner showResourceToast:@"已清除连接测速结果"];
        }]];
    }
    NSArray<HostGlassSheetSection *> *sections=@[
        [HostGlassSheetSection sectionWithTitle:@"排序方式" actions:sortActions],
        [HostGlassSheetSection sectionWithTitle:@"来源筛选" actions:sourceActions],
        [HostGlassSheetSection sectionWithTitle:@"诊断与测速" actions:toolActions]
    ];
    [HostGlassActionSheetViewController presentOn:self title:@"筛选与排序" subtitle:[NSString stringWithFormat:@"当前筛选：%@ · 排序：%@",[self.selectedKind isEqual:@"all"]?@"全部来源":self.selectedKind,sortName] badgeText:sortName badgeColor:HostAccent() sections:sections sourceView:(self.topActionsStack?:self.view)];
}
- (void)selectKind:(UIButton *)sender {NSString *kind=[sender.accessibilityIdentifier stringByReplacingOccurrencesOfString:@"resource-filter-" withString:@""];if(!kind.length||[kind isEqual:self.selectedKind])return;self.selectedKind=kind;[self reloadProfiles];}
- (BOOL)profile:(NSDictionary *)profile matchesSearchQuery:(NSString *)query {
    if(!query.length)return YES;
    NSString *title=[[self resourceTitleForProfile:profile] lowercaseString]?:@"";
    if([title containsString:query])return YES;
    NSString *detail=[[self resourceDetailForProfile:profile] lowercaseString]?:@"";
    if([detail containsString:query])return YES;
    for(NSString *key in @[@"name",@"source",@"url",@"runtime",@"protocol",@"subscriptionStatus",@"status",@"healthResult"]){
        id val=profile[key];
        if([val isKindOfClass:NSString.class]&&[[(NSString *)val lowercaseString] containsString:query])return YES;
    }
    return [[profile description].lowercaseString containsString:query];
}
- (void)reloadProfiles {
    NSString *task=self.importTaskSummaryProvider?self.importTaskSummaryProvider():nil;BOOL hasTask=task.length>0;self.importTaskContainer.hidden=!hasTask;self.importTaskHeight.constant=hasTask?(self.importTaskExpanded?76:44):0;self.importTaskButtonHeight.constant=hasTask?44:0;self.importTaskToggleHeight.constant=hasTask?44:0;self.importTaskDetailHeight.constant=hasTask&&self.importTaskExpanded?28:0;self.importTaskDetailLabel.hidden=!hasTask||!self.importTaskExpanded;self.importTaskDetailLabel.text=task?:@"";[self.importTaskButton setTitle:!hasTask?@"":(self.importTaskExpanded?@"继续查看导入任务":[@"导入任务 · " stringByAppendingString:task]) forState:UIControlStateNormal];[self.importTaskToggleButton setImage:[UIImage systemImageNamed:self.importTaskExpanded?@"chevron.up":@"chevron.down"] forState:UIControlStateNormal];[self.importTaskToggleButton setAccessibilityValue:self.importTaskExpanded?@"已展开":@"已收起"];[self updateResourceHeaderLayout];
    [self.detailSummaryCache removeAllObjects];
    [self.rowHeightCache removeAllObjects];
    NSArray *rawAll = self.profilesProvider ? self.profilesProvider() : @[];
    NSArray *savedOrder=[NSUserDefaults.standardUserDefaults arrayForKey:@"resourceUnifiedOrder"];
    NSMutableArray *all=[rawAll mutableCopy];
    if([savedOrder isKindOfClass:NSArray.class]&&savedOrder.count){
        NSMutableDictionary<NSString *,NSNumber *> *orderMap=[NSMutableDictionary dictionaryWithCapacity:savedOrder.count];
        for(NSUInteger idx=0;idx<savedOrder.count;idx++){
            id key=savedOrder[idx];
            if([key isKindOfClass:NSString.class]&&!orderMap[key])orderMap[key]=@(idx);
        }
        [all sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
            NSNumber *ia=orderMap[CCTVResourceUnifiedKeyForProfile(a)],*ib=orderMap[CCTVResourceUnifiedKeyForProfile(b)];
            if(ia&&ib)return [ia compare:ib];
            if(ia)return NSOrderedAscending;
            if(ib)return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    self.allProfiles=all.copy;
    [self updateDashboardCard];
    [self updateSortPillButton];
    [self updateKindFilters];
    NSArray *matchedProfiles=[self.allProfiles filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,NSDictionary *bindings){
        NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
        if(![self profile:p matchesKind:self.selectedKind?:@"all"])return NO;
        NSString *query=self.searchQuery?:@"";if(query.length&&![self profile:p matchesSearchQuery:query])return NO;
        return [p[@"type"] isEqual:@"plugin"]||[p[@"type"] isEqual:@"tvbox"]||source.length>0||[p[@"native"] boolValue];
    }]];
    NSArray *profiles=matchedProfiles;
    if([self.sortMode isEqual:@"name"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[self resourceTitleForProfile:a] localizedStandardCompare:[self resourceTitleForProfile:b]];}];}
    else if([self.sortMode isEqual:@"recent"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSTimeInterval at=MAX([a[@"updatedAt"] doubleValue],[a[@"playlistUpdatedAt"] doubleValue]),bt=MAX([b[@"updatedAt"] doubleValue],[b[@"playlistUpdatedAt"] doubleValue]);if(at>bt)return NSOrderedAscending;if(at<bt)return NSOrderedDescending;return [[self resourceTitleForProfile:a] localizedStandardCompare:[self resourceTitleForProfile:b]];}];}
    else if([self.sortMode isEqual:@"attention"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){BOOL aa=[self profile:a matchesKind:@"attention"],ba=[self profile:b matchesKind:@"attention"];if(aa!=ba)return aa?NSOrderedAscending:NSOrderedDescending;NSUInteger ai=[matchedProfiles indexOfObjectIdenticalTo:a],bi=[matchedProfiles indexOfObjectIdenticalTo:b];return ai<bi?NSOrderedAscending:(ai>bi?NSOrderedDescending:NSOrderedSame);}];}
    else if([self.sortMode isEqual:@"latency"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        NSString *sa=[a[@"source"] isKindOfClass:NSString.class]?a[@"source"]:@"",*sb=[b[@"source"] isKindOfClass:NSString.class]?b[@"source"]:@"";
        NSDictionary *ra=self.latencyResults[sa],*rb=self.latencyResults[sb];
        double ma=([ra[@"ok"] boolValue]&&[ra[@"milliseconds"] doubleValue]>=0)?[ra[@"milliseconds"] doubleValue]:([a[@"native"] boolValue]?1.0:1e9);
        double mb=([rb[@"ok"] boolValue]&&[rb[@"milliseconds"] doubleValue]>=0)?[rb[@"milliseconds"] doubleValue]:([b[@"native"] boolValue]?1.0:1e9);
        if(ma!=mb)return ma<mb?NSOrderedAscending:NSOrderedDescending;
        return [[self resourceTitleForProfile:a] localizedStandardCompare:[self resourceTitleForProfile:b]];
    }];}
    BOOL isEmpty=profiles.count==0;
    NSString *emptyText=!isEmpty?@"":(self.searchQuery.length?@"没有找到匹配的导入资源，请尝试其他搜索词":(![self.selectedKind isEqual:@"all"]?@"当前筛选分类下暂无资源\n可切换顶部筛选胶囊查看全部":@"还没有导入资源\n点顶部“添加”导入影视脚本、直播服务或订阅列表"));
    self.emptyContainerView.hidden=!isEmpty;
    self.emptyLabel.text=emptyText;
    if(isEmpty){
        NSString *iconName=self.searchQuery.length?@"magnifyingglass":(![self.selectedKind isEqual:@"all"]?@"line.3.horizontal.decrease.circle":@"tray");
        self.emptyIconView.image=[UIImage systemImageNamed:iconName withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightLight]];
        NSString *btnTitle=self.searchQuery.length?@"清除搜索":(![self.selectedKind isEqual:@"all"]?@"查看全部资源":@"添加资源");
        [self.emptyActionButton setTitle:btnTitle forState:UIControlStateNormal];
        self.emptyActionButton.hidden=NO;
    }
    if([self.profiles isEqualToArray:profiles]){return;}self.profiles=profiles;
    [self.tableView reloadData];
}
- (void)kindChanged {[self reloadProfiles];}
- (void)searchTextChanged {
    if(self.resourceSearchField.markedTextRange)return;
    NSString *trimmed=[[self.resourceSearchField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString]?:@"";
    if([trimmed isEqualToString:self.searchQuery?:@""])return;
    self.searchQuery=trimmed;
    NSUInteger gen=++self.searchGeneration;
    if(!trimmed.length){[self reloadProfiles];return;}
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(80*NSEC_PER_MSEC)),dispatch_get_main_queue(),^{
        ConfigCenterViewController *owner=weakSelf;
        if(owner&&gen==owner.searchGeneration)[owner reloadProfiles];
    });
}
- (NSString *)resourceTitleForProfile:(NSDictionary *)profile {
    NSString *name=[profile[@"name"] isKindOfClass:NSString.class]?profile[@"name"]:@"";
    if(name.length)return name;
    NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
    NSString *host=[NSURL URLWithString:source].host;
    return host.length?host:([source hasPrefix:@"local-playlist:"]?@"本地播放列表":@"未命名资源");
}
- (BOOL)isLiveCapableProfile:(NSDictionary *)profile {
    if (![profile isKindOfClass:NSDictionary.class]) return NO;
    if ([profile[@"native"] boolValue]) return YES;
    NSString *kind = [profile[@"resourceKind"] isKindOfClass:NSString.class] ? profile[@"resourceKind"] : @"";
    if ([kind isEqual:@"live"] || [kind isEqual:@"both"]) return YES;
    if ([profile[@"type"] isEqual:@"tvbox"]) return [profile[@"liveCount"] unsignedIntegerValue] > 0;
    return !profile[@"type"] && [profile[@"source"] isKindOfClass:NSString.class] && [profile[@"source"] length] > 0;
}
- (void)toggleChannelLogoForSource:(NSString *)source enabled:(BOOL)enabled {
    [ProfileStore setChannelLogoEnabled:enabled forSource:source];
    if (self.onToggleChannelLogo) self.onToggleChannelLogo(source ?: @"", enabled);
    [self reloadProfiles];
}
- (void)togglePlayerCornerLogoForSource:(NSString *)source enabled:(BOOL)enabled {
    [ProfileStore setPlayerCornerLogoEnabled:enabled forSource:source];
    if (self.onTogglePlayerCornerLogo) self.onTogglePlayerCornerLogo(source ?: @"", enabled);
    [self reloadProfiles];
}
- (void)toggleChannelPreviewForSource:(NSString *)source enabled:(BOOL)enabled {
    [ProfileStore setChannelPreviewEnabled:enabled forSource:source];
    if (self.onToggleChannelPreview) self.onToggleChannelPreview(source ?: @"", enabled);
    [self reloadProfiles];
}
- (void)toggleChannelTelemetryForSource:(NSString *)source enabled:(BOOL)enabled {
    [ProfileStore setChannelTelemetryEnabled:enabled forSource:source];
    if (self.onToggleChannelTelemetry) self.onToggleChannelTelemetry(source ?: @"", enabled);
    [self reloadProfiles];
}
- (NSString *)resourceDetailForProfile:(NSDictionary *)profile {
    NSString *rawSourceKey=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
    BOOL logoOn=profile[@"showChannelLogo"]?[profile[@"showChannelLogo"] boolValue]:[ProfileStore isChannelLogoEnabledForSource:rawSourceKey];
    BOOL cornerOn=profile[@"showPlayerCornerLogo"]?[profile[@"showPlayerCornerLogo"] boolValue]:[ProfileStore isPlayerCornerLogoEnabledForSource:rawSourceKey];
    BOOL previewOn=profile[@"showChannelPreview"]?[profile[@"showChannelPreview"] boolValue]:[ProfileStore isChannelPreviewEnabledForSource:rawSourceKey];
    BOOL telemetryOn=profile[@"showChannelTelemetry"]?[profile[@"showChannelTelemetry"] boolValue]:[ProfileStore isChannelTelemetryEnabledForSource:rawSourceKey];
    NSString *cacheKey=[NSString stringWithFormat:@"%@|%@|%@|%@|%@|%d|%d|%d|%d",rawSourceKey,profile[@"status"]?:@"",profile[@"updatedAt"]?:@0,profile[@"playlistUpdatedAt"]?:@0,profile[@"current"]?:@0,logoOn,cornerOn,previewOn,telemetryOn];
    NSString *cached=self.detailSummaryCache[cacheKey];if(cached)return cached;
    BOOL plugin=[profile[@"type"] isEqual:@"plugin"],tvbox=[profile[@"type"] isEqual:@"tvbox"];
    NSString *current=[profile[@"current"] boolValue]?@"当前使用 · ":@"";
    if(plugin){
        NSString *kind=[profile[@"resourceKind"] isEqual:@"live"]?@"直播服务":([profile[@"resourceKind"] isEqual:@"vod"]?@"影视服务":([profile[@"resourceKind"] isEqual:@"both"]?@"影视 / 直播服务":@"待识别能力"));
        NSString *rawStatus=[profile[@"status"] isKindOfClass:NSString.class]?profile[@"status"]:@"未启动";
        if([rawStatus isEqualToString:@"已停止 · HTTP 健康状态未知"])rawStatus=@"已停止 · 按需启动";
        NSMutableArray *lines=[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@%@ · %@ · %@",current,kind,profile[@"runtime"]?:@"引擎未知",rawStatus]];
        NSTimeInterval updated=[profile[@"updatedAt"] doubleValue];if(updated>0){NSDateFormatter *formatter=CCTVResourceListDateFormatter();[lines addObject:[NSString stringWithFormat:@"最近更新 %@",[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]]];}
        if([profile[@"subscriptionURL"] length]){
            [lines addObject:[NSString stringWithFormat:@"%@ 个缓存频道 · %@",profile[@"channelCount"]?:@0,profile[@"subscriptionStatus"]?:@"尚未读取清单"]];
            NSTimeInterval last=[profile[@"playlistUpdatedAt"] doubleValue];
            if(last>0){NSDateFormatter *formatter=CCTVResourceListDateFormatter();[lines addObject:[NSString stringWithFormat:@"最近成功：%@",[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:last]]]];}
            [lines addObject:[NSString stringWithFormat:@"订阅：%@",CCTVResourceDisplayEndpoint(profile[@"subscriptionURL"])]];
        }
        if([profile[@"healthResult"] isKindOfClass:NSString.class]){NSTimeInterval checked=[profile[@"healthCheckedAt"] doubleValue];NSDateFormatter *formatter=CCTVResourceListDateFormatter();NSString *time=checked>0?[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:checked]]:@"未知时间";[lines addObject:[NSString stringWithFormat:@"最近接口检测 %@ · %@",time,profile[@"healthResult"]]];}
        if([profile[@"epgURL"] length])[lines addObject:[NSString stringWithFormat:@"节目单：%@",CCTVResourceDisplayEndpoint(profile[@"epgURL"])]];
        NSString *pluginResult=[lines componentsJoinedByString:@"\n"];if(cacheKey.length)self.detailSummaryCache[cacheKey]=pluginResult;return pluginResult;
    }
    if(tvbox){
        BOOL macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];NSString *catalogTitle=macCMS?@"MacCMS 影视接口":@"资源合集";
        NSTimeInterval updated=[profile[@"updatedAt"] doubleValue];NSDateFormatter *savedFormatter=CCTVResourceListDateFormatter();NSString *saved=updated>0?[NSString stringWithFormat:@"最近保存 %@",[savedFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]]:@"尚无保存时间";
        NSString *tvboxResult=macCMS?[NSString stringWithFormat:@"%@%@ · 选中后浏览 · 仅请求当前接口\n%@",current,catalogTitle,saved]:[NSString stringWithFormat:@"%@%@ · %lu 个站点 · %lu 个已识别 · %lu 个直播列表\n%@",current,catalogTitle,(unsigned long)[profile[@"siteCount"] unsignedIntegerValue],(unsigned long)[profile[@"supportedCount"] unsignedIntegerValue],(unsigned long)[profile[@"liveCount"] unsignedIntegerValue],saved];if(cacheKey.length)self.detailSummaryCache[cacheKey]=tvboxResult;return tvboxResult;
    }
    NSTimeInterval updated=[profile[@"updatedAt"] doubleValue];NSString *refreshInfo=[profile[@"native"] boolValue]?@"内置官方源 · 实时同步":@"尚无成功刷新记录";
    if(updated>0){NSDateFormatter *formatter=CCTVResourceListDateFormatter();refreshInfo=[NSString stringWithFormat:@"最近成功 %@",[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]];}
    NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
    NSString *location=[source hasPrefix:@"local-playlist:"]?@"本机文件":(source.length?[NSURL URLWithString:source].host?:@"直播订阅":@"官方频道目录");
    NSString *summary=[NSString stringWithFormat:@"%@ 个频道 · EPG %@\n%@ · %@",profile[@"count"]?:@0,profile[@"epgStatus"]?:@"自动匹配",location,refreshInfo];
    if([profile[@"status"] isKindOfClass:NSString.class]&&[profile[@"status"] length])summary=[summary stringByAppendingFormat:@"\n%@",profile[@"status"]];
    NSString *logoBadge=!logoOn?@"台标已关闭":(cornerOn?@"台标：列表+右上角":@"台标：仅列表");
    NSString *previewBadge=previewOn?@"预览图:开":@"预览图:关";
    NSString *telemetryBadge=telemetryOn?@"速率延迟:开":@"速率延迟:关";
    summary=[summary stringByAppendingFormat:@" · %@ · %@ · %@",logoBadge,previewBadge,telemetryBadge];
    NSString *result=[NSString stringWithFormat:@"%@%@",current,summary];
    if(cacheKey.length)self.detailSummaryCache[cacheKey]=result;
    return result;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {[textField resignFirstResponder];return YES;}
- (void)refreshHomeContent {if(self.onRefreshMediaHome)self.onRefreshMediaHome();}
- (void)add {
    if (self.onAdd)
        self.onAdd();
}
- (void)openServices { if(self.onServices)self.onServices(); }
- (void)refreshProfiles {
    [self reloadProfiles];
    [self.refreshControl endRefreshing];
}
- (void)toggleImportTaskExpanded {self.importTaskExpanded=!self.importTaskExpanded;[self reloadProfiles];}
- (NSString *)latencyTextForProfile:(NSDictionary *)profile color:(UIColor * __autoreleasing *)colorOut {
    NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";NSDictionary *result=self.latencyResults[source];UIColor *color=HostSecondaryText();NSString *text=@"未检测";
    if([result[@"probing"] boolValue]){text=@"检测中…";color=UIColor.systemOrangeColor;}
    else if([result[@"notProbeable"] boolValue])text=@"本机";
    else if(result){if(![result[@"ok"] boolValue]){NSInteger status=[result[@"status"] integerValue];text=(status==401||status==403)?@"需授权":(status==405?@"不支持检测":@"连接失败");color=status==405?HostSecondaryText():((status==401||status==403)?UIColor.systemOrangeColor:[UIColor colorWithRed:1 green:.27 blue:.23 alpha:1]);}else{double ms=[result[@"milliseconds"] doubleValue];text=ms>=1000?[NSString stringWithFormat:@"%.1fs",ms/1000.0]:[NSString stringWithFormat:@"%.0fms",ms];color=ms<300?[UIColor colorWithRed:.19 green:.82 blue:.35 alpha:1]:(ms<1000?[UIColor colorWithRed:1 green:.62 blue:.04 alpha:1]:[UIColor colorWithRed:1 green:.27 blue:.23 alpha:1]);}}
    if(colorOut)*colorOut=color;return text;
}
- (NSURL *)probeURLForProfile:(NSDictionary *)profile {
    NSString *raw=[profile[@"url"] isKindOfClass:NSString.class]?profile[@"url"]:@"";if(![ProfileStore isHTTP:raw])raw=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";if(![ProfileStore isHTTP:raw])return nil;NSURLComponents *parts=[NSURLComponents componentsWithString:raw];if(!parts||parts.user.length||parts.password.length)return nil;return parts.URL;
}
- (void)probeSingleProfile:(NSString *)source {
    if(!source.length)return;
    if([self.latencyResults[source][@"probing"] boolValue])return;
    NSDictionary *targetProfile=nil;
    for(NSDictionary *p in self.allProfiles)if([p[@"source"] isEqual:source]){targetProfile=p;break;}
    if(!targetProfile)return;
    NSURL *url=[self probeURLForProfile:targetProfile];
    if(!url){self.latencyResults[source]=@{@"notProbeable":@YES};[self reloadVisibleRowForSource:source];return;}
    self.latencyResults[source]=@{@"probing":@YES};
    [self reloadVisibleRowForSource:source];
    __weak typeof(self) weakSelf=self;
    NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];configuration.timeoutIntervalForRequest=4;configuration.timeoutIntervalForResource=5;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];
    void (^finishProbe)(NSDictionary *) = ^(NSDictionary *result){
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(),^{
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            owner.latencyResults[source]=result;
            [owner updateDashboardCard];
            if([owner.sortMode isEqual:@"latency"])[owner reloadProfiles];
            else [owner reloadVisibleRowForSource:source];
        });
    };
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];request.HTTPMethod=@"HEAD";
    NSDate *start=[NSDate date];
    NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *rawResponse,NSError *error){
        double elapsed=[[NSDate date] timeIntervalSinceDate:start]*1000.0;
        NSHTTPURLResponse *response=[rawResponse isKindOfClass:NSHTTPURLResponse.class]?(id)rawResponse:nil;
        NSInteger status=response.statusCode;
        if(!error&&(status==405||status==501)){
            NSMutableURLRequest *getReq=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
            getReq.HTTPMethod=@"GET";[getReq setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
            NSDate *getStart=[NSDate date];
            [[session dataTaskWithRequest:getReq completionHandler:^(__unused NSData *gd,NSURLResponse *gr,NSError *ge){
                double getElapsed=[[NSDate date] timeIntervalSinceDate:getStart]*1000.0;
                NSHTTPURLResponse *gResp=[gr isKindOfClass:NSHTTPURLResponse.class]?(id)gr:nil;
                NSInteger gStatus=gResp.statusCode;BOOL gOk=!ge&&gStatus>=200&&gStatus<300;
                finishProbe(@{@"ok":@(gOk),@"milliseconds":@(MAX(0,getElapsed)),@"status":@(gStatus)});
            }] resume];
            return;
        }
        BOOL ok=!error&&status>=200&&status<300;
        finishProbe(@{@"ok":@(ok),@"milliseconds":@(MAX(0,elapsed)),@"status":@(status)});
    }];
    [task resume];
}
- (void)openAdaptationMonitor {
    MediaAdaptationMonitorViewController *monitor=[[MediaAdaptationMonitorViewController alloc] initWithContext:nil];
    if(self.navigationController)[self.navigationController pushViewController:monitor animated:YES];
    else{UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:monitor];[self presentViewController:nav animated:YES completion:nil];}
}
- (void)probeResources {
    if(self.probingResources)return;
    self.probingResources=YES;
    NSArray<NSDictionary *> *profiles=[self.allProfiles isKindOfClass:NSArray.class]?self.allProfiles:@[];
    if(!profiles.count){self.probingResources=NO;return;}
    dispatch_group_t group=dispatch_group_create();
    NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];configuration.timeoutIntervalForRequest=4;configuration.timeoutIntervalForResource=5;configuration.HTTPMaximumConnectionsPerHost=4;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];__weak typeof(self) weakSelf=self;
    NSMutableArray<NSDictionary *> *targets=[NSMutableArray array];
    for(NSDictionary *profile in profiles){
        NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";NSURL *url=[self probeURLForProfile:profile];
        if(!url){if(source.length)self.latencyResults[source]=@{@"notProbeable":@YES};continue;}
        if(source.length)self.latencyResults[source]=@{@"probing":@YES};
        [targets addObject:@{@"source":source,@"url":url}];
    }
    [self updateDashboardCard];
    [self.tableView reloadData];
    for(NSDictionary *target in targets){
        dispatch_group_enter(group);
        NSURL *url=target[@"url"];NSString *source=target[@"source"];
        NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];request.HTTPMethod=@"HEAD";
        NSDate *start=[NSDate date];
        void (^recordResult)(NSDictionary *) = ^(NSDictionary *result){
            dispatch_async(dispatch_get_main_queue(),^{
                ConfigCenterViewController *owner=weakSelf;if(!owner||!source.length)return;owner.latencyResults[source]=result;
                [owner reloadVisibleRowForSource:source];
            });
            dispatch_group_leave(group);
        };
        NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(__unused NSData *data,NSURLResponse *rawResponse,NSError *error){
            NSHTTPURLResponse *response=[rawResponse isKindOfClass:NSHTTPURLResponse.class]?(id)rawResponse:nil;
            double elapsed=[[NSDate date] timeIntervalSinceDate:start]*1000.0;NSInteger status=response.statusCode;
            if(!error&&(status==405||status==501)){
                NSMutableURLRequest *getReq=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];
                getReq.HTTPMethod=@"GET";[getReq setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
                NSDate *getStart=[NSDate date];
                [[session dataTaskWithRequest:getReq completionHandler:^(__unused NSData *gd,NSURLResponse *gr,NSError *ge){
                    double getElapsed=[[NSDate date] timeIntervalSinceDate:getStart]*1000.0;
                    NSHTTPURLResponse *gResp=[gr isKindOfClass:NSHTTPURLResponse.class]?(id)gr:nil;
                    NSInteger gStatus=gResp.statusCode;BOOL gOk=!ge&&gStatus>=200&&gStatus<300;
                    recordResult(@{@"ok":@(gOk),@"milliseconds":@(MAX(0,getElapsed)),@"status":@(gStatus)});
                }] resume];
                return;
            }
            BOOL ok=!error&&status>=200&&status<300;
            recordResult(@{@"ok":@(ok),@"milliseconds":@(MAX(0,elapsed)),@"status":@(status)});
        }];
        [task resume];
    }
    dispatch_group_notify(group,dispatch_get_main_queue(),^{
        [session finishTasksAndInvalidate];
        ConfigCenterViewController *owner=weakSelf;if(!owner)return;owner.probingResources=NO;[owner updateDashboardCard];
        if([owner.sortMode isEqual:@"latency"])[owner reloadProfiles];
        else [UIView transitionWithView:owner.tableView duration:.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{[owner.tableView reloadData];} completion:nil];
    });
}
- (UISwitch *)compactSwitchForRow:(NSInteger)row enabled:(BOOL)enabled label:(NSString *)label source:(NSString *)source {
    // 开关用 tag=row 定位配置：筛选/排序后行号会指向另一条配置，静默误操作。
    // 改把配置 source 记在 accessibilityIdentifier 上，toggle: 按 source 查找。
    UISwitch *toggle=[UISwitch new];toggle.onTintColor=HostAccent();toggle.on=enabled;toggle.tag=row;toggle.accessibilityLabel=label;toggle.accessibilityIdentifier=source?:@"";[toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];return toggle;
}
- (UIView *)switchAccessoryForSwitch:(UISwitch *)toggle width:(CGFloat)width {
    UIView *accessory=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,44)];accessory.isAccessibilityElement=NO;toggle.frame=CGRectMake((width-51)/2,6.5,51,31);[accessory addSubview:toggle];return accessory;
}
- (void)persistUnifiedOrderWithProfiles:(NSArray<NSDictionary *> *)orderedProfiles {
    NSMutableArray<NSString *> *keys=[NSMutableArray arrayWithCapacity:orderedProfiles.count];
    NSMutableArray<NSString *> *subOrder=[NSMutableArray array];
    NSMutableArray<NSString *> *pluginIDs=[NSMutableArray array];
    NSMutableArray<NSString *> *catalogIDs=[NSMutableArray array];
    for(NSDictionary *p in orderedProfiles){
        NSString *key=CCTVResourceUnifiedKeyForProfile(p);
        if(key.length)[keys addObject:key];
        NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
        if([source hasPrefix:@"plugin:"])[pluginIDs addObject:[source substringFromIndex:7]];
        else if([source hasPrefix:@"tvbox:"])[catalogIDs addObject:[source substringFromIndex:6]];
        else if(source.length)[subOrder addObject:source];
    }
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if(keys.count)[defaults setObject:keys forKey:@"resourceUnifiedOrder"];
    if(subOrder.count)[defaults setObject:subOrder forKey:@"profileOrder"];
    if(pluginIDs.count){
        NSArray *existingServices=[defaults arrayForKey:@"pythonServices"];
        if([existingServices isKindOfClass:NSArray.class]&&existingServices.count>1){
            NSMutableDictionary<NSString *,NSNumber *> *rank=[NSMutableDictionary dictionary];
            for(NSUInteger i=0;i<pluginIDs.count;i++)rank[pluginIDs[i]]=@(i);
            NSArray *sorted=[existingServices sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
                NSNumber *ra=rank[a[@"id"]?:@""],*rb=rank[b[@"id"]?:@""];
                if(ra&&rb)return [ra compare:rb];
                return NSOrderedSame;
            }];
            [defaults setObject:sorted forKey:@"pythonServices"];
        }
    }
    if(catalogIDs.count){
        NSArray *existingCatalogs=[defaults arrayForKey:@"tvboxCatalogs"];
        if([existingCatalogs isKindOfClass:NSArray.class]&&existingCatalogs.count>1){
            NSMutableDictionary<NSString *,NSNumber *> *rank=[NSMutableDictionary dictionary];
            for(NSUInteger i=0;i<catalogIDs.count;i++)rank[catalogIDs[i]]=@(i);
            NSArray *sorted=[existingCatalogs sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
                NSNumber *ra=rank[a[@"id"]?:@""],*rb=rank[b[@"id"]?:@""];
                if(ra&&rb)return [ra compare:rb];
                return NSOrderedSame;
            }];
            [defaults setObject:sorted forKey:@"tvboxCatalogs"];
        }
    }
}
- (void)moveProfileFromIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath updateTableView:(BOOL)updateTableView {
    if(!sourceIndexPath||!destinationIndexPath)return;
    NSInteger fromRow=sourceIndexPath.row,toRow=destinationIndexPath.row;
    if(fromRow<0||fromRow>=(NSInteger)self.profiles.count||toRow<0||toRow>=(NSInteger)self.profiles.count||fromRow==toRow)return;
    if(![self.sortMode isEqual:@"manual"]){
        self.sortMode=@"manual";
        [NSUserDefaults.standardUserDefaults setObject:@"manual" forKey:@"resourceListSortMode"];
        [self updateSortPillButton];
    }
    NSMutableArray<NSDictionary *> *visible=[self.profiles mutableCopy];
    NSDictionary *moved=visible[fromRow];
    [visible removeObjectAtIndex:fromRow];
    [visible insertObject:moved atIndex:toRow];
    self.profiles=visible.copy;

    NSMutableArray<NSDictionary *> *all=[self.allProfiles mutableCopy]?:[NSMutableArray array];
    NSString *movedKey=CCTVResourceUnifiedKeyForProfile(moved);
    NSUInteger allFrom=[all indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger idx,BOOL *stop){
        return [CCTVResourceUnifiedKeyForProfile(item) isEqualToString:movedKey];
    }];
    if(allFrom!=NSNotFound){
        [all removeObjectAtIndex:allFrom];
        if(toRow==0){
            NSDictionary *afterItem=visible.count>1?visible[1]:nil;
            NSString *afterKey=CCTVResourceUnifiedKeyForProfile(afterItem);
            NSUInteger targetIdx=afterKey.length?[all indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger idx,BOOL *stop){return [CCTVResourceUnifiedKeyForProfile(item) isEqualToString:afterKey];}]:0;
            [all insertObject:moved atIndex:(targetIdx!=NSNotFound?targetIdx:0)];
        }else{
            NSDictionary *beforeItem=visible[toRow-1];
            NSString *beforeKey=CCTVResourceUnifiedKeyForProfile(beforeItem);
            NSUInteger targetIdx=beforeKey.length?[all indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger idx,BOOL *stop){return [CCTVResourceUnifiedKeyForProfile(item) isEqualToString:beforeKey];}]:NSNotFound;
            [all insertObject:moved atIndex:(targetIdx!=NSNotFound?MIN(all.count,targetIdx+1):all.count)];
        }
        self.allProfiles=all.copy;
    }else{
        self.allProfiles=visible.copy;
    }
    [self persistUnifiedOrderWithProfiles:self.allProfiles];
    if(updateTableView){
        [self.tableView performBatchUpdates:^{
            [self.tableView moveRowAtIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
        } completion:^(__unused BOOL finished){
            [self.tableView reloadData];
        }];
    }else{
        [self.tableView reloadData];
    }
}
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.row>=0 && indexPath.row<(NSInteger)self.profiles.count;
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    [self moveProfileFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath updateTableView:NO];
}
- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.row<0||indexPath.row>=(NSInteger)self.profiles.count)return @[];
    NSDictionary *profile=self.profiles[indexPath.row];
    NSString *key=CCTVResourceUnifiedKeyForProfile(profile);
    if(!key.length)return @[];
    NSItemProvider *provider=[[NSItemProvider alloc] initWithObject:key];
    UIDragItem *item=[[UIDragItem alloc] initWithItemProvider:provider];
    item.localObject=profile;
    return @[item];
}
- (UIDragPreviewParameters *)tableView:(UITableView *)tableView dragPreviewParametersForRowAtIndexPath:(NSIndexPath *)indexPath {
    UIDragPreviewParameters *params=[UIDragPreviewParameters new];
    UITableViewCell *cell=[tableView cellForRowAtIndexPath:indexPath];
    if(cell)params.visiblePath=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(cell.bounds,1,1) cornerRadius:14];
    params.backgroundColor=HostCard();
    return params;
}
- (BOOL)tableView:(UITableView *)tableView canHandleDropSession:(id<UIDropSession>)session {
    return session.localDragSession!=nil && session.items.count==1;
}
- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    if(tableView.hasActiveDrag){
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}
- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    id<UITableViewDropItem> dropItem=coordinator.items.firstObject;
    NSIndexPath *sourceIndexPath=dropItem.sourceIndexPath;
    if(!sourceIndexPath)return;
    NSIndexPath *destinationIndexPath=coordinator.destinationIndexPath;
    if(!destinationIndexPath||destinationIndexPath.row>=(NSInteger)self.profiles.count){
        NSInteger lastRow=MAX(0,(NSInteger)self.profiles.count-1);
        destinationIndexPath=[NSIndexPath indexPathForRow:lastRow inSection:0];
    }
    [self moveProfileFromIndexPath:sourceIndexPath toIndexPath:destinationIndexPath updateTableView:YES];
    if(dropItem.dragItem&&destinationIndexPath)[coordinator dropItem:dropItem.dragItem toRowAtIndexPath:destinationIndexPath];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.profiles.count;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.row<0||indexPath.row>=self.profiles.count)return 96;
    NSDictionary *profile=self.profiles[indexPath.row];
    NSString *title=[self resourceTitleForProfile:profile];
    NSString *detail=[self resourceDetailForProfile:profile];
    NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
    CGFloat cardWidth=MAX(1,tableView.bounds.size.width-40);
    NSString *cacheKey=[NSString stringWithFormat:@"%@|%ld|%lu|%lu|%@",source,(long)lrint(cardWidth),(unsigned long)title.hash,(unsigned long)detail.hash,self.traitCollection.preferredContentSizeCategory?:@""];
    NSNumber *cached=[self.rowHeightCache objectForKey:cacheKey];
    if(cached)return cached.doubleValue;
    BOOL plugin=[profile[@"type"] isEqual:@"plugin"],tvbox=[profile[@"type"] isEqual:@"tvbox"],hasExportMenu=plugin||[profile[@"source"] length]||[profile[@"native"] boolValue];
    CGFloat accessoryWidth=plugin?104:(tvbox?44:(hasExportMenu?104:56));
    CGFloat textWidth=MAX(44,cardWidth-22-12-accessoryWidth);
    UIFont *titleFont=HostRoundedFont(16, UIFontWeightBold, UIFontTextStyleHeadline),*detailFont=HostMonospacedDigitFont(12.5, UIFontWeightRegular, UIFontTextStyleFootnote);
    CGRect titleBounds=[title boundingRectWithSize:CGSizeMake(textWidth,ceil(titleFont.lineHeight*2)) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:titleFont} context:nil];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByCharWrapping;paragraph.lineSpacing=3.2;paragraph.paragraphSpacing=2.0;
    CGRect detailBounds=[detail boundingRectWithSize:CGSizeMake(textWidth,CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:detailFont,NSParagraphStyleAttributeName:paragraph} context:nil];
    CGFloat titleHeight=MIN(ceil(titleFont.lineHeight*2),MAX(ceil(titleFont.lineHeight),ceil(titleBounds.size.height)));
    CGFloat detailHeight=MAX(ceil(detailFont.lineHeight),ceil(detailBounds.size.height));
    CGFloat computedHeight=MAX(98,ceil(14+titleHeight+6+20+12+detailHeight+14+4));
    [self.rowHeightCache setObject:@(computedHeight) forKey:cacheKey];
    return computedHeight;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSUInteger enabledSubscriptions=0,enabledServices=0,catalogs=0,runningServices=0;
    for(NSDictionary *p in self.profiles){if([p[@"type"] isEqual:@"plugin"]){if([p[@"enabled"] boolValue])enabledServices++;NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";NSString *identifier=[source hasPrefix:@"plugin:"]?[source substringFromIndex:7]:@"";if(identifier.length&&[PyHost isRunningServiceIdentifier:identifier])runningServices++;}else if([p[@"type"] isEqual:@"tvbox"])catalogs++;else if([p[@"enabled"] boolValue])enabledSubscriptions++;}
    // 这里统计的是“已启用”，不是“正在运行”：已启用 ≠ 进程运行中 ≠ 接口健康 ≠ 能播；运行中单独计数。
    return [NSString stringWithFormat:@"共 %lu 项 · 合集 %lu · 订阅启用 %lu · 服务启用 %lu · 运行中 %lu",(unsigned long)self.profiles.count,(unsigned long)catalogs,(unsigned long)enabledSubscriptions,(unsigned long)enabledServices,(unsigned long)runningServices];
}
- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    HostStyleSectionHeaderView(view);
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    CCTVResourceProfileCell *c = (id)[tableView dequeueReusableCellWithIdentifier:@"profile"];
    if (!c)
        c = [[CCTVResourceProfileCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"profile"];
    if(ip.row<0||ip.row>=self.profiles.count)return c;
    c.backgroundColor = HostCard();
    c.layer.cornerRadius = 14;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(c, HostBorder());
    c.clipsToBounds = YES;
    c.textLabel.textColor = HostText();
    c.textLabel.font = HostRoundedFont(16, UIFontWeightBold, UIFontTextStyleHeadline);
    c.detailTextLabel.font = HostMonospacedDigitFont(12.5, UIFontWeightRegular, UIFontTextStyleFootnote);
    c.textLabel.adjustsFontForContentSizeCategory=YES;
    c.detailTextLabel.adjustsFontForContentSizeCategory=YES;
    c.textLabel.numberOfLines=2;
    c.textLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    c.detailTextLabel.textColor = HostSecondaryText();
    // Subscription endpoints and service health details can wrap to several
    // lines. Let Auto Layout size the cell from the complete, bounded summary
    // so a long URL cannot paint over the following resource row.
    c.detailTextLabel.numberOfLines = 0;
    c.detailTextLabel.lineBreakMode=NSLineBreakByCharWrapping;
    c.imageView.tintColor = HostAccent();
    c.iconBadgeContainer.hidden = YES;
    c.profileIconView.hidden = YES;
    c.imageView.image = nil;
    c.dragHandleView.tintColor = HostMutedText();
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    {
        NSDictionary *p = self.profiles[ip.row];
        if(![p isKindOfClass:NSDictionary.class])return c;
        BOOL plugin=[p[@"type"] isEqual:@"plugin"],tvbox=[p[@"type"] isEqual:@"tvbox"];
        NSString *profileName=[self resourceTitleForProfile:p];
        c.accessibilityIdentifier=[NSString stringWithFormat:@"resource-row-%ld",(long)ip.row];
        c.accessibilityLabel=profileName;
        c.accessibilityHint=plugin?@"轻点查看服务能力与设置，长按拖动可调整排序":@"轻点查看资源，使用开关启用或停用，长按拖动可调整排序";
        c.textLabel.text=profileName;
        c.detailTextLabel.text=[self resourceDetailForProfile:p];
        if(c.detailTextLabel.text.length){c.detailTextLabel.attributedText=[self attributedDetailForText:c.detailTextLabel.text font:c.detailTextLabel.font];}else{c.detailTextLabel.attributedText=nil;}
        c.detailDivider.backgroundColor=[HostSeparator() colorWithAlphaComponent:0.42];
        UIColor *iconTint=nil;
        NSString *iconSymbol=[self semanticIconNameForProfile:p tintColor:&iconTint];
        c.profileIconView.image=[UIImage systemImageNamed:iconSymbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
        c.profileIconView.tintColor=iconTint?:HostAccent();
        c.iconBadgeContainer.backgroundColor=[(iconTint?:HostAccent()) colorWithAlphaComponent:0.14];
        HostSetLayerBorderColor(c.iconBadgeContainer,[(iconTint?:HostAccent()) colorWithAlphaComponent:0.30]);
        UIColor *latencyColor=nil;NSString *rawLatency=[self latencyTextForProfile:p color:&latencyColor];
        if([p[@"native"] boolValue]&&[rawLatency isEqualToString:@"未检测"])rawLatency=@"官方源";
        c.latencyBadge.text=[NSString stringWithFormat:@" %@ ",rawLatency];c.latencyBadge.textColor=latencyColor?:HostSecondaryText();c.latencyBadge.backgroundColor=HostRaisedSurface();HostSetLayerBorderColor(c.latencyBadge,HostBorder());c.latencyBadge.accessibilityLabel=[NSString stringWithFormat:@"资源测速：%@",rawLatency?:@"未测速"];
        NSString *rowSource=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
        c.profileSource=rowSource;
        __weak typeof(self) weakLatencySelf=self;
        c.onTapLatency=^(NSString *tappedSource){[weakLatencySelf probeSingleProfile:tappedSource];};
        UIColor *statusTextColor=nil,*statusBgColor=nil,*statusBorderColor=nil;
        NSString *statusText=[self statusBadgeTextForProfile:p textColor:&statusTextColor backgroundColor:&statusBgColor borderColor:&statusBorderColor];
        c.statusBadge.text=statusText;c.statusBadge.textColor=statusTextColor?:HostSecondaryText();c.statusBadge.backgroundColor=statusBgColor?:HostNeutralSurface();HostSetLayerBorderColor(c.statusBadge,statusBorderColor?:HostBorder());
        c.capabilityBadge.text=[self capabilityTagForProfile:p];c.capabilityBadge.hidden=!c.capabilityBadge.text.length;c.capabilityBadge.textColor=HostSecondaryText();c.capabilityBadge.backgroundColor=HostRaisedSurface();HostSetLayerBorderColor(c.capabilityBadge,HostBorder());
        BOOL isCurrent=[p[@"current"] boolValue];
        c.leadingAccentBar.backgroundColor=isCurrent?HostAccent():([p[@"enabled"] boolValue]?[(iconTint?:HostAccent()) colorWithAlphaComponent:0.82]:[HostMutedText() colorWithAlphaComponent:0.38]);
        c.topSpecularLine.backgroundColor=[UIColor colorWithWhite:1.0 alpha:isCurrent?0.18:0.08];if(isCurrent){c.layer.borderWidth=1.15;HostSetLayerBorderColor(c,HostAccent());c.iconBadgeContainer.backgroundColor=[HostAccent() colorWithAlphaComponent:0.22];}
        c.protocolBadge.backgroundColor=HostSelectedSurface();c.protocolBadge.textColor=HostAccent();HostSetLayerBorderColor(c.protocolBadge,[HostAccent() colorWithAlphaComponent:0.32]);
        NSString *protoTag=plugin?(p[@"runtime"]?:@"插件"):(tvbox?([p[@"catalogKind"] isEqual:@"maccms"]?@"MacCMS":@"合集"):@"M3U");c.protocolBadge.text=[NSString stringWithFormat:@" %@ ",protoTag];
        [c setNeedsLayout];
        if(!plugin&&!tvbox){
            UISwitch *s=[self compactSwitchForRow:ip.row enabled:[p[@"enabled"] boolValue] label:[NSString stringWithFormat:@"加入频道 %@",p[@"name"]?:@"订阅"] source:p[@"source"]];c.accessoryView=[self switchAccessoryForSwitch:s width:56];
        }
        if(plugin||tvbox||[p[@"source"] length]||[p[@"native"] boolValue]){
            __weak typeof(self) weakSelf=self;NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";BOOL macCMS=[p[@"catalogKind"] isEqual:@"maccms"];
            UIAction *manage=[UIAction actionWithTitle:tvbox?(macCMS?@"打开影视接口":@"打开资源合集"): @"资源能力与设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(tvbox){if([source hasPrefix:@"tvbox:"]&&weakSelf.onOpenTVBoxCatalog)weakSelf.onOpenTVBoxCatalog([source substringFromIndex:6]);}else if(weakSelf.onOpenResource)weakSelf.onOpenResource(source);}];
            NSMutableArray<UIAction *> *primaryActions=[NSMutableArray array];
            NSMutableArray<UIAction *> *displayActions=[NSMutableArray array];
            NSMutableArray<UIAction *> *maintActions=[NSMutableArray array];
            NSMutableArray<UIAction *> *orderActions=[NSMutableArray array];
            NSMutableArray<UIAction *> *dangerActions=[NSMutableArray array];
            if(plugin||tvbox)[primaryActions addObject:manage];
            else if([p[@"native"] boolValue]||source.length){
                [primaryActions addObject:[UIAction actionWithTitle:@"资源详情与台标设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(weakSelf.onOpenSubscription)weakSelf.onOpenSubscription(source);}]];
            }
            if(plugin&&self.onUseResource){NSString *resourceKind=p[@"resourceKind"];if([resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"])[primaryActions addObject:[UIAction actionWithTitle:@"添加直播频道" image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"] identifier:nil handler:^(UIAction *a){if(weakSelf.onUseResource)weakSelf.onUseResource(source,@"live");}]];if([resourceKind isEqual:@"vod"]||[resourceKind isEqual:@"both"])[primaryActions addObject:[UIAction actionWithTitle:@"进入影视" image:[UIImage systemImageNamed:@"film"] identifier:nil handler:^(UIAction *a){if(weakSelf.onUseResource)weakSelf.onUseResource(source,@"vod");}]];}
            if([self isLiveCapableProfile:p]){
                BOOL chLogoOn=p[@"showChannelLogo"]?[p[@"showChannelLogo"] boolValue]:[ProfileStore isChannelLogoEnabledForSource:source];
                BOOL cornerLogoOn=p[@"showPlayerCornerLogo"]?[p[@"showPlayerCornerLogo"] boolValue]:[ProfileStore isPlayerCornerLogoEnabledForSource:source];
                UIAction *toggleListLogo=[UIAction actionWithTitle:chLogoOn?@"列表与播放器台标：已开启":@"列表与播放器台标：已关闭" image:[UIImage systemImageNamed:chLogoOn?@"photo.fill":@"photo"] identifier:nil handler:^(UIAction *a){[weakSelf toggleChannelLogoForSource:source enabled:!chLogoOn];}];
                if(chLogoOn)toggleListLogo.state=UIMenuElementStateOn;
                BOOL previewOn=p[@"showChannelPreview"]?[p[@"showChannelPreview"] boolValue]:[ProfileStore isChannelPreviewEnabledForSource:source];
                BOOL telemetryOn=p[@"showChannelTelemetry"]?[p[@"showChannelTelemetry"] boolValue]:[ProfileStore isChannelTelemetryEnabledForSource:source];
                UIAction *toggleCornerLogo=[UIAction actionWithTitle:cornerLogoOn?@"播放器右上角台标：已开启":@"播放器右上角台标：已关闭" image:[UIImage systemImageNamed:cornerLogoOn?@"tv.inset.filled":@"tv"] identifier:nil handler:^(UIAction *a){[weakSelf togglePlayerCornerLogoForSource:source enabled:!cornerLogoOn];}];
                if(cornerLogoOn)toggleCornerLogo.state=UIMenuElementStateOn;
                UIAction *togglePreview=[UIAction actionWithTitle:previewOn?@"频道实时预览图：已开启":@"频道实时预览图：已关闭" image:[UIImage systemImageNamed:previewOn?@"photo.on.rectangle.angled":@"rectangle.slash"] identifier:nil handler:^(UIAction *a){[weakSelf toggleChannelPreviewForSource:source enabled:!previewOn];}];
                if(previewOn)togglePreview.state=UIMenuElementStateOn;
                UIAction *toggleTelemetry=[UIAction actionWithTitle:telemetryOn?@"频道速率与延迟：已开启":@"频道速率与延迟：已关闭" image:[UIImage systemImageNamed:@"speedometer"] identifier:nil handler:^(UIAction *a){[weakSelf toggleChannelTelemetryForSource:source enabled:!telemetryOn];}];
                if(telemetryOn)toggleTelemetry.state=UIMenuElementStateOn;
                [displayActions addObject:toggleListLogo];
                [displayActions addObject:toggleCornerLogo];
                [displayActions addObject:togglePreview];
                [displayActions addObject:toggleTelemetry];
                if(!tvbox&&weakSelf.onMatchStationLogos){
                    [displayActions addObject:[UIAction actionWithTitle:@"智能匹配官方台标与节目单" image:[UIImage systemImageNamed:@"sparkles.tv"] identifier:nil handler:^(UIAction *a){if(weakSelf.onMatchStationLogos)weakSelf.onMatchStationLogos(source);}]];
                }
            }
            if(plugin){
                NSString *subscriptionURL=[p[@"subscriptionURL"] isKindOfClass:NSString.class]?p[@"subscriptionURL"]:@"";
                if(subscriptionURL.length&&weakSelf.onRefreshProfile)[maintActions addObject:[UIAction actionWithTitle:@"刷新订阅清单" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRefreshProfile)weakSelf.onRefreshProfile(source);}]];
                if(weakSelf.onRecheckProfile)[maintActions addObject:[UIAction actionWithTitle:@"重新检测健康" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRecheckProfile)weakSelf.onRecheckProfile(source);}]];
                if(subscriptionURL.length&&weakSelf.onRematchEPGProfile)[maintActions addObject:[UIAction actionWithTitle:@"重新匹配节目单（EPG）" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRematchEPGProfile)weakSelf.onRematchEPGProfile(source);}]];
                if(weakSelf.onRestartProfile)[maintActions addObject:[UIAction actionWithTitle:@"重启服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRestartProfile)weakSelf.onRestartProfile(source);}]];
            }
            if(tvbox&&!macCMS&&weakSelf.onRefreshCatalogProfile){
                NSString *catalogURL=[p[@"url"] isKindOfClass:NSString.class]?p[@"url"]:@"";
                NSURL *catalogURLObject=[NSURL URLWithString:catalogURL];
                if(catalogURLObject&&[@[@"http",@"https"] containsObject:catalogURLObject.scheme.lowercaseString])[maintActions addObject:[UIAction actionWithTitle:@"刷新合集" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRefreshCatalogProfile)weakSelf.onRefreshCatalogProfile(source);}]];
            }
            if([self probeURLForProfile:p]){
                [maintActions addObject:[UIAction actionWithTitle:@"单条测速连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *a){[weakSelf probeSingleProfile:source];}]];
            }
            if(tvbox){
                [maintActions addObject:[UIAction actionWithTitle:@"导出完整 JSON" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(UIAction *a){if(weakSelf.onExportResource)weakSelf.onExportResource(source,@"catalog-json");}]];
                [maintActions addObject:[UIAction actionWithTitle:@"导出资源 ZIP（含可获取的 PY / JS）" image:[UIImage systemImageNamed:@"archivebox"] identifier:nil handler:^(UIAction *a){if(weakSelf.onExportResource)weakSelf.onExportResource(source,@"catalog-zip");}]];
            }else{
                [maintActions addObject:[UIAction actionWithTitle:@"导出单项资源文件" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a){if(weakSelf.onExportResource)weakSelf.onExportResource(source,@"single");}]];
            }
            NSString *copyableURL=[p[@"url"] isKindOfClass:NSString.class]&&[p[@"url"] length]?p[@"url"]:([ProfileStore isHTTP:source]?source:@"");
            if(copyableURL.length){
                [maintActions addObject:[UIAction actionWithTitle:@"复制资源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:copyableURL];[weakSelf showResourceToast:@"资源地址已复制"];}]];
            }
            NSInteger rowIndex=ip.row;
            if(rowIndex>0){
                [orderActions addObject:[UIAction actionWithTitle:@"上移一行" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[weakSelf moveProfileFromIndexPath:[NSIndexPath indexPathForRow:rowIndex inSection:0] toIndexPath:[NSIndexPath indexPathForRow:rowIndex-1 inSection:0] updateTableView:NO];}]];
            }
            if(rowIndex+1<(NSInteger)self.profiles.count){
                [orderActions addObject:[UIAction actionWithTitle:@"下移一行" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[weakSelf moveProfileFromIndexPath:[NSIndexPath indexPathForRow:rowIndex inSection:0] toIndexPath:[NSIndexPath indexPathForRow:rowIndex+1 inSection:0] updateTableView:NO];}]];
            }
            if(source.length){
                UIAction *remove=[UIAction actionWithTitle:tvbox?(macCMS?@"移除影视接口":@"移除资源合集"): @"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[weakSelf confirmRemoveProfile:source];}];
                remove.attributes=UIMenuElementAttributesDestructive;
                [dangerActions addObject:remove];
            }
            NSMutableArray<UIMenuElement *> *menuSections=[NSMutableArray array];
            if(primaryActions.count)[menuSections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"resource.row.menu.primary" options:UIMenuOptionsDisplayInline children:primaryActions]];
            if(displayActions.count)[menuSections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"resource.row.menu.display" options:UIMenuOptionsDisplayInline children:displayActions]];
            if(maintActions.count)[menuSections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"resource.row.menu.maintenance" options:UIMenuOptionsDisplayInline children:maintActions]];
            if(orderActions.count)[menuSections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"resource.row.menu.order" options:UIMenuOptionsDisplayInline children:orderActions]];
            if(dangerActions.count)[menuSections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:@"resource.row.menu.danger" options:UIMenuOptionsDisplayInline children:dangerActions]];
            UIButton *more=[UIButton buttonWithType:UIButtonTypeSystem];more.frame=CGRectMake(0,0,44,44);[more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];more.menu=[UIMenu menuWithChildren:menuSections];more.showsMenuAsPrimaryAction=YES;more.accessibilityLabel=@"更多资源操作";more.accessibilityIdentifier=[NSString stringWithFormat:@"resource-more-%ld",(long)ip.row];more.tintColor=HostSecondaryText();more.backgroundColor=HostNeutralSurface();more.layer.cornerRadius=12;more.layer.cornerCurve=kCACornerCurveContinuous;more.layer.borderWidth=.6;HostSetLayerBorderColor(more,HostBorder());HostInstallPressFeedback(more);
            if(plugin){BOOL runningState=[p[@"enabled"] boolValue];UISwitch *running=[self compactSwitchForRow:ip.row enabled:runningState label:[NSString stringWithFormat:@"%@服务，%@",p[@"name"]?:@"脚本",runningState?@"停止":@"启动"] source:p[@"source"]];UIView *actions=[[UIView alloc] initWithFrame:CGRectMake(0,0,104,44)];actions.isAccessibilityElement=NO;running.frame=CGRectMake(0,6.5,51,31);[actions addSubview:running];more.frame=CGRectMake(58,0,44,44);[actions addSubview:more];c.accessoryView=actions;}else if(!tvbox&&([p[@"source"] length]||[p[@"native"] boolValue])){UIView *actions=[[UIView alloc] initWithFrame:CGRectMake(0,0,104,44)];actions.isAccessibilityElement=NO;UISwitch *toggle=[c.accessoryView.subviews.firstObject isKindOfClass:UISwitch.class]?c.accessoryView.subviews.firstObject:nil;if(toggle){toggle.frame=CGRectMake(0,6.5,51,31);[actions addSubview:toggle];}more.frame=CGRectMake(58,0,44,44);[actions addSubview:more];c.accessoryView=actions;}else c.accessoryView=more;
        }
    }
    c.accessibilityValue=c.detailTextLabel.text;
    return c;
}
- (void)toggle:(UISwitch *)sender {
    // 不再信任 tag=row：按开关携带的 source 查找配置，排序/筛选后也不会误触他行。
    NSString *source=sender.accessibilityIdentifier;NSDictionary *p=nil;
    for(NSDictionary *profile in self.profiles)if([profile[@"source"] isEqual:source]){p=profile;break;}
    // 找不到配置（筛选变化/已被移除）时把开关拨回去，否则界面与实际状态不一致。
    if(!p){sender.on=!sender.on;return;}
    if (self.onToggleProfile)
        self.onToggleProfile(p[@"source"], sender.on);
    if([p[@"type"] isEqual:@"plugin"])return;
    [self reloadProfiles];
}
- (void)tableView:(UITableView *)tableView didHighlightRowAtIndexPath:(NSIndexPath *)ip { UITableViewCell *c=[tableView cellForRowAtIndexPath:ip]; if(!c||UIAccessibilityIsReduceMotionEnabled())return; [UIView animateWithDuration:0.10 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformMakeScale(0.985,0.985);} completion:nil]; }
- (void)tableView:(UITableView *)tableView didUnhighlightRowAtIndexPath:(NSIndexPath *)ip { UITableViewCell *c=[tableView cellForRowAtIndexPath:ip]; if(!c)return; [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.2 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{c.transform=CGAffineTransformIdentity;} completion:nil]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if(ip.row<0||ip.row>=self.profiles.count)return;
    NSDictionary *profile=self.profiles[ip.row];if(![profile isKindOfClass:NSDictionary.class])return;
    NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
    if([profile[@"type"] isEqual:@"plugin"]){if(self.onOpenResource)self.onOpenResource(source);}
    else if([profile[@"type"] isEqual:@"tvbox"]){if([source hasPrefix:@"tvbox:"]&&self.onOpenTVBoxCatalog)self.onOpenTVBoxCatalog([source substringFromIndex:6]);}
    else {
        if(self.onOpenSubscription){self.onOpenSubscription(source);return;}
        NSMutableArray<HostGlassSheetAction *> *primaryActions=[NSMutableArray array];
        if(self.onSelectProfile)[primaryActions addObject:[HostGlassSheetAction actionWithTitle:@"打开频道" subtitle:@"在频道页仅查看此订阅源" value:nil icon:@"tv" tint:HostAccent() destructive:NO selected:NO handler:^{self.onSelectProfile(source);}]];
        if(source.length&&self.onEditProfile)[primaryActions addObject:[HostGlassSheetAction actionWithTitle:@"编辑订阅与节目单" subtitle:@"修改名称、地址、请求头与 EPG" value:nil icon:@"slider.horizontal.3" tint:UIColor.systemBlueColor destructive:NO selected:NO handler:^{self.onEditProfile(source);}]];
        NSMutableArray<HostGlassSheetAction *> *maintActions=[NSMutableArray array];
        if(source.length&&self.onRefreshProfile)[maintActions addObject:[HostGlassSheetAction actionWithTitle:@"刷新此订阅" subtitle:@"重新拉取最新频道列表" value:nil icon:@"arrow.clockwise" tint:HostAccent() destructive:NO selected:NO handler:^{self.onRefreshProfile(source);}]];
        if(source.length&&self.onRecheckProfile)[maintActions addObject:[HostGlassSheetAction actionWithTitle:@"重新检测健康" subtitle:@"检测源站可达性与响应状态" value:nil icon:@"waveform.path.ecg" tint:UIColor.systemTealColor destructive:NO selected:NO handler:^{self.onRecheckProfile(source);}]];
        if(source.length&&self.onRematchEPGProfile)[maintActions addObject:[HostGlassSheetAction actionWithTitle:@"重新匹配节目单（EPG）" subtitle:@"自动关联官方台标与节目预告" value:nil icon:@"calendar.badge.clock" tint:UIColor.systemOrangeColor destructive:NO selected:NO handler:^{self.onRematchEPGProfile(source);}]];
        NSMutableArray<HostGlassSheetSection *> *sections=[NSMutableArray array];
        if(primaryActions.count)[sections addObject:[HostGlassSheetSection sectionWithTitle:@"频道与配置" actions:primaryActions]];
        if(maintActions.count)[sections addObject:[HostGlassSheetSection sectionWithTitle:@"维护与检测" actions:maintActions]];
        UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];
        [HostGlassActionSheetViewController presentOn:self
                                                title:profile[@"name"]?:@"订阅"
                                             subtitle:source.length?source:nil
                                            badgeText:@"直播订阅"
                                           badgeColor:HostAccent()
                                             sections:sections
                                           sourceView:cell?:self.view];
    }
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.row<0||ip.row>=self.profiles.count)return nil;
    NSDictionary *profile=self.profiles[ip.row];
    id rawSource=profile[@"source"];if(![rawSource isKindOfClass:NSString.class]||![rawSource length])
        return nil;
    NSString *source = rawSource;
    BOOL tvbox=[profile[@"type"] isEqual:@"tvbox"];
    UIContextualAction *a = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"删除"
                          handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                            done(NO);
                            [self confirmRemoveProfile:source];
                          }];
    UIContextualAction *edit=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:tvbox?@"打开":@"编辑" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){
        if(tvbox){if([source hasPrefix:@"tvbox:"]&&self.onOpenTVBoxCatalog)self.onOpenTVBoxCatalog([source substringFromIndex:6]);}
        else if(self.onEditProfile)self.onEditProfile(source);
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[a,edit]];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if(ip.row<0||ip.row>=self.profiles.count)return nil;
    NSDictionary *profile=self.profiles[ip.row];
    id rawSource=profile[@"source"];if(![rawSource isKindOfClass:NSString.class]||![rawSource length])return nil;
    NSString *source=rawSource;
    BOOL plugin=[profile[@"type"] isEqual:@"plugin"],tvbox=[profile[@"type"] isEqual:@"tvbox"];
    NSMutableArray<UIContextualAction *> *actions=[NSMutableArray array];
    if(plugin){
        if(self.onRecheckProfile){
            UIContextualAction *recheck=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"健康检测" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){self.onRecheckProfile(source);done(YES);}];
            recheck.backgroundColor=HostAccent();
            [actions addObject:recheck];
        }
    }else if(tvbox){
        BOOL macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];
        if(!macCMS&&self.onRefreshCatalogProfile){
            UIContextualAction *refreshCatalog=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"刷新合集" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){self.onRefreshCatalogProfile(source);done(YES);}];
            refreshCatalog.backgroundColor=HostAccent();
            [actions addObject:refreshCatalog];
        }
    }else{
        UIContextualAction *refresh=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"刷新" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){if(self.onRefreshProfile)self.onRefreshProfile(source);done(YES);}];
        refresh.backgroundColor=HostAccent();
        [actions addObject:refresh];
    }
    if([self probeURLForProfile:profile]){
        UIContextualAction *probe=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"测速" handler:^(UIContextualAction *action,UIView *view,void (^done)(BOOL)){[self probeSingleProfile:source];done(YES);}];
        probe.backgroundColor=HostSecondaryText();
        [actions addObject:probe];
    }
    return actions.count?[UISwipeActionsConfiguration configurationWithActions:actions]:nil;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    if(ip.row<0||ip.row>=self.profiles.count)return nil;
    NSDictionary *profile=self.profiles[ip.row];if(![profile isKindOfClass:NSDictionary.class])return nil;
    id rawSource=profile[@"source"];NSString *source=[rawSource isKindOfClass:NSString.class]?rawSource:@"";
    if(!source.length&&![profile[@"native"] boolValue])return nil;
    __weak typeof(self) w=self;
    BOOL tvbox=[profile[@"type"] isEqual:@"tvbox"];
    BOOL macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];
    NSString *subscriptionURL=[profile[@"subscriptionURL"] isKindOfClass:NSString.class]?profile[@"subscriptionURL"]:@"";
    NSString *catalogURL=[profile[@"url"] isKindOfClass:NSString.class]?profile[@"url"]:@"";
    NSURL *catalogURLObject=[NSURL URLWithString:catalogURL];
    BOOL catalogRefreshable=tvbox&&!macCMS&&catalogURLObject&&[@[@"http",@"https"] containsObject:catalogURLObject.scheme.lowercaseString];
    NSString *profileName=[self resourceTitleForProfile:profile];
    NSString *copyableURL=catalogURL.length?catalogURL:([ProfileStore isHTTP:source]?source:@"");
    BOOL canProbe=[self probeURLForProfile:profile]!=nil;
    NSInteger currentRow=ip.row;
    return [UIContextMenuConfiguration configurationWithIdentifier:source previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){
        if(tvbox){
            NSMutableArray *actions=[NSMutableArray array];
            if(catalogRefreshable)[actions addObject:[UIAction actionWithTitle:@"刷新合集" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshCatalogProfile)w.onRefreshCatalogProfile(source);}]];
            if(canProbe)[actions addObject:[UIAction actionWithTitle:@"单条测速连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *a){[w probeSingleProfile:source];}]];
            if(copyableURL.length)[actions addObject:[UIAction actionWithTitle:@"复制资源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:copyableURL];[w showResourceToast:@"资源地址已复制"];}]];
            [actions addObject:[UIAction actionWithTitle:@"复制资源名称" image:[UIImage systemImageNamed:@"textformat"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=profileName;[w showResourceToast:@"资源名称已复制"];}]];
            if(currentRow>0)[actions addObject:[UIAction actionWithTitle:@"上移" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow-1 inSection:0] updateTableView:NO];}]];
            if(currentRow+1<(NSInteger)w.profiles.count)[actions addObject:[UIAction actionWithTitle:@"下移" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow+1 inSection:0] updateTableView:NO];}]];
            UIAction *rmCat=[UIAction actionWithTitle:macCMS?@"移除影视接口":@"移除资源合集" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}];rmCat.attributes=UIMenuElementAttributesDestructive;[actions addObject:rmCat];
            return [UIMenu menuWithTitle:@"合集操作" children:actions];
        }
        NSMutableArray *actions=[NSMutableArray array];
        if(source.length)[actions addObject:[UIAction actionWithTitle:[source hasPrefix:@"plugin:"]?@"编辑资源":@"编辑配置与 EPG" image:[UIImage systemImageNamed:@"pencil"] identifier:nil handler:^(UIAction *a){if(w.onEditProfile)w.onEditProfile(source);}]];
        if([w isLiveCapableProfile:profile]){
            BOOL chLogoOn=profile[@"showChannelLogo"]?[profile[@"showChannelLogo"] boolValue]:[ProfileStore isChannelLogoEnabledForSource:source];
            BOOL cornerLogoOn=profile[@"showPlayerCornerLogo"]?[profile[@"showPlayerCornerLogo"] boolValue]:[ProfileStore isPlayerCornerLogoEnabledForSource:source];
            UIAction *toggleListLogo=[UIAction actionWithTitle:chLogoOn?@"关闭此资源台标显示":@"开启此资源台标显示" image:[UIImage systemImageNamed:chLogoOn?@"photo.fill":@"photo"] identifier:nil handler:^(UIAction *a){[w toggleChannelLogoForSource:source enabled:!chLogoOn];}];
            BOOL previewOn=profile[@"showChannelPreview"]?[profile[@"showChannelPreview"] boolValue]:[ProfileStore isChannelPreviewEnabledForSource:source];
            BOOL telemetryOn=profile[@"showChannelTelemetry"]?[profile[@"showChannelTelemetry"] boolValue]:[ProfileStore isChannelTelemetryEnabledForSource:source];
            UIAction *toggleCorner=[UIAction actionWithTitle:cornerLogoOn?@"关闭播放器右上角台标":@"开启播放器右上角台标" image:[UIImage systemImageNamed:cornerLogoOn?@"tv.inset.filled":@"tv"] identifier:nil handler:^(UIAction *a){[w togglePlayerCornerLogoForSource:source enabled:!cornerLogoOn];}];
            UIAction *togglePreview=[UIAction actionWithTitle:previewOn?@"关闭频道实时预览图":@"开启频道实时预览图" image:[UIImage systemImageNamed:previewOn?@"photo.on.rectangle.angled":@"rectangle.slash"] identifier:nil handler:^(UIAction *a){[w toggleChannelPreviewForSource:source enabled:!previewOn];}];
            UIAction *toggleTelemetry=[UIAction actionWithTitle:telemetryOn?@"关闭频道速率与延迟":@"开启频道速率与延迟" image:[UIImage systemImageNamed:@"speedometer"] identifier:nil handler:^(UIAction *a){[w toggleChannelTelemetryForSource:source enabled:!telemetryOn];}];
            [actions addObject:toggleListLogo];
            [actions addObject:toggleCorner];
            [actions addObject:togglePreview];
            [actions addObject:toggleTelemetry];
            if(w.onMatchStationLogos)[actions addObject:[UIAction actionWithTitle:@"智能匹配官方台标与节目单" image:[UIImage systemImageNamed:@"sparkles.tv"] identifier:nil handler:^(UIAction *a){w.onMatchStationLogos(source);}]];
        }
        [actions addObject:[UIAction actionWithTitle:@"导出单项资源文件" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a){if(w.onExportResource)w.onExportResource(source,@"single");}]];
        if(canProbe)[actions addObject:[UIAction actionWithTitle:@"单条测速连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *a){[w probeSingleProfile:source];}]];
        if(copyableURL.length)[actions addObject:[UIAction actionWithTitle:@"复制资源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:copyableURL];[w showResourceToast:@"资源地址已复制"];}]];
        [actions addObject:[UIAction actionWithTitle:@"复制资源名称" image:[UIImage systemImageNamed:@"textformat"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=profileName;[w showResourceToast:@"资源名称已复制"];}]];
        if(!source.length)return [UIMenu menuWithTitle:@"资源操作" children:actions];
        if([source hasPrefix:@"plugin:"]){
            if(subscriptionURL.length)[actions addObject:[UIAction actionWithTitle:@"刷新订阅清单" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshProfile)w.onRefreshProfile(source);}]];
            [actions addObject:[UIAction actionWithTitle:@"重新检测健康" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction *a){if(w.onRecheckProfile)w.onRecheckProfile(source);}]];
            if(subscriptionURL.length)[actions addObject:[UIAction actionWithTitle:@"重新匹配节目单（EPG）" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a){if(w.onRematchEPGProfile)w.onRematchEPGProfile(source);}]];
            [actions addObject:[UIAction actionWithTitle:@"重启服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a){if(w.onRestartProfile)w.onRestartProfile(source);}]];
            if(currentRow>0)[actions addObject:[UIAction actionWithTitle:@"上移" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow-1 inSection:0] updateTableView:NO];}]];
            if(currentRow+1<(NSInteger)w.profiles.count)[actions addObject:[UIAction actionWithTitle:@"下移" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow+1 inSection:0] updateTableView:NO];}]];
            UIAction *rmPlug=[UIAction actionWithTitle:@"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}];rmPlug.attributes=UIMenuElementAttributesDestructive;[actions addObject:rmPlug];
            return [UIMenu menuWithTitle:@"资源操作" children:actions];
        }
        [actions addObject:[UIAction actionWithTitle:@"刷新此订阅" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshProfile)w.onRefreshProfile(source);}]];
        [actions addObject:[UIAction actionWithTitle:@"重新检测健康" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction *a){if(w.onRecheckProfile)w.onRecheckProfile(source);}]];
        [actions addObject:[UIAction actionWithTitle:@"重新匹配节目单（EPG）" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a){if(w.onRematchEPGProfile)w.onRematchEPGProfile(source);}]];
        for(NSNumber *offset in @[@(-1),@1]){NSInteger targetRow=currentRow+offset.integerValue;if(targetRow<0||targetRow>=(NSInteger)w.profiles.count)continue;[actions addObject:[UIAction actionWithTitle:offset.integerValue<0?@"上移":@"下移" image:[UIImage systemImageNamed:offset.integerValue<0?@"arrow.up":@"arrow.down"] identifier:nil handler:^(UIAction *a){NSArray *sources=[w.allProfiles valueForKey:@"source"];sources=[sources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id s,NSDictionary *b){return [s isKindOfClass:NSString.class]&&[(NSString *)s length]>0;}]];[ProfileStore move:source offset:offset.integerValue sources:sources];if(targetRow>=0&&targetRow<(NSInteger)w.profiles.count)[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:targetRow inSection:0] updateTableView:NO];else[w reloadProfiles];}]];}
        UIAction *rmSub=[UIAction actionWithTitle:@"移除订阅" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}];rmSub.attributes=UIMenuElementAttributesDestructive;[actions addObject:rmSub];
        return [UIMenu menuWithTitle:@"订阅操作" children:actions];
    }];
}
- (void)confirmRemoveProfile:(NSString *)source {
    BOOL plugin=[source hasPrefix:@"plugin:"],tvbox=[source hasPrefix:@"tvbox:"];
    BOOL macCMS=NO;for(NSDictionary *profile in self.profiles)if([profile[@"source"] isEqual:source]){macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];break;}
    NSString *message=plugin?@"这会从本机移除该服务配置和对应的资源代码。":(tvbox?@"这会移除资源合集；已导入的脚本和直播订阅会保留。":@"这会移除订阅源及仅由它提供的频道；其他订阅源共同提供的频道会保留。");
    if(tvbox&&macCMS)message=@"这会移除 MacCMS 影视接口；其他脚本、影视来源和直播订阅会保留。";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:tvbox?(macCMS?@"移除 MacCMS 影视接口？":@"移除资源合集？"):(plugin?@"移除资源？":@"移除订阅？") message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:tvbox?(macCMS?@"移除接口":@"移除合集"):(plugin?@"移除资源":@"移除订阅") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){ConfigCenterViewController *owner=weakSelf;if(!owner)return;if(owner.onDeleteProfile)owner.onDeleteProfile(source);[owner reloadProfiles];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *container=[UIView new];
    container.backgroundColor=UIColor.clearColor;
    UILabel *label=[UILabel new];
    label.translatesAutoresizingMaskIntoConstraints=NO;
    label.text=[self tableView:tableView titleForHeaderInSection:section];
    label.textColor=HostMutedText();
    label.font=HostMonospacedDigitFont(12.5,UIFontWeightMedium,UIFontTextStyleFootnote);
    label.adjustsFontForContentSizeCategory=YES;
    label.numberOfLines=0;
    label.lineBreakStrategy=NSLineBreakStrategyPushOut;
    label.accessibilityIdentifier=@"resource-list-summary";
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:22],[label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],[label.topAnchor constraintEqualToAnchor:container.topAnchor],[label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]]];
    return container;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // 汇总文案在大字体/窄屏下会换成两行：按实际文本测高，最小 34pt。
    NSString *text=[self tableView:tableView titleForHeaderInSection:section]?:@"";
    CGFloat width=MAX(1,tableView.bounds.size.width-22-16);
    UIFont *font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    CGRect bounds=[text boundingRectWithSize:CGSizeMake(width,CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:font} context:nil];
    return MAX(34,ceil(bounds.size.height)+8);
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {return 4;}
@end
