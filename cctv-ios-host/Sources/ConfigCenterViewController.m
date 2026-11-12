#import "ConfigCenterViewController.h"
#import "HostTheme.h"
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

@interface CCTVResourceProfileCell : UITableViewCell
@property(nonatomic,strong) UIView *iconBadgeContainer;
@property(nonatomic,strong) UIImageView *profileIconView;
@property(nonatomic,strong) UIView *leadingAccentBar;
@property(nonatomic,strong) UIImageView *dragHandleView;
@property(nonatomic,strong) UILabel *profileTitleLabel;
@property(nonatomic,strong) UILabel *profileDetailLabel;
@property(nonatomic,strong) UILabel *protocolBadge;
@property(nonatomic,strong) UILabel *latencyBadge;
@property(nonatomic,strong) UILabel *statusBadge;
@property(nonatomic,strong) UIView *detailDivider;
@property(nonatomic,copy) NSString *profileSource;
@property(nonatomic,copy) void (^onTapLatency)(NSString *source);
@end

@implementation CCTVResourceProfileCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if((self=[super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier])) {
        self.iconBadgeContainer=[UIView new];self.iconBadgeContainer.translatesAutoresizingMaskIntoConstraints=NO;self.iconBadgeContainer.backgroundColor=[HostAccent() colorWithAlphaComponent:0.14];self.iconBadgeContainer.layer.cornerRadius=10;self.iconBadgeContainer.layer.cornerCurve=kCACornerCurveContinuous;self.iconBadgeContainer.layer.borderWidth=0.6;HostSetLayerBorderColor(self.iconBadgeContainer,[HostAccent() colorWithAlphaComponent:0.28]);self.iconBadgeContainer.hidden=YES;self.iconBadgeContainer.alpha=0.0;self.iconBadgeContainer.userInteractionEnabled=NO;
        self.profileIconView=[UIImageView new];self.profileIconView.translatesAutoresizingMaskIntoConstraints=NO;self.profileIconView.contentMode=UIViewContentModeScaleAspectFit;self.profileIconView.hidden=YES;
        [self.iconBadgeContainer addSubview:self.profileIconView];
        self.leadingAccentBar=[UIView new];self.leadingAccentBar.translatesAutoresizingMaskIntoConstraints=NO;self.leadingAccentBar.backgroundColor=HostAccent();self.leadingAccentBar.layer.cornerRadius=1.75;self.leadingAccentBar.layer.cornerCurve=kCACornerCurveContinuous;self.leadingAccentBar.userInteractionEnabled=NO;
        self.dragHandleView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium]]];self.dragHandleView.translatesAutoresizingMaskIntoConstraints=NO;self.dragHandleView.tintColor=HostMutedText();self.dragHandleView.alpha=0.52;self.dragHandleView.contentMode=UIViewContentModeScaleAspectFit;self.dragHandleView.userInteractionEnabled=NO;self.dragHandleView.accessibilityIdentifier=@"resource.drag.handle";
        self.profileTitleLabel=[UILabel new];self.profileTitleLabel.translatesAutoresizingMaskIntoConstraints=NO;self.profileTitleLabel.numberOfLines=2;self.profileTitleLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.profileTitleLabel.adjustsFontForContentSizeCategory=YES;
        self.profileDetailLabel=[UILabel new];self.profileDetailLabel.translatesAutoresizingMaskIntoConstraints=NO;self.profileDetailLabel.numberOfLines=0;self.profileDetailLabel.lineBreakMode=NSLineBreakByCharWrapping;self.profileDetailLabel.adjustsFontForContentSizeCategory=YES;
        self.protocolBadge=[UILabel new];self.protocolBadge.translatesAutoresizingMaskIntoConstraints=NO;self.protocolBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightBold,UIFontTextStyleCaption2);self.protocolBadge.textAlignment=NSTextAlignmentCenter;self.protocolBadge.layer.cornerRadius=6.5;self.protocolBadge.layer.cornerCurve=kCACornerCurveContinuous;self.protocolBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.protocolBadge,[HostAccent() colorWithAlphaComponent:0.32]);self.protocolBadge.clipsToBounds=YES;self.protocolBadge.backgroundColor=HostSelectedSurface();self.protocolBadge.textColor=HostAccent();self.protocolBadge.accessibilityIdentifier=@"resource.protocol.badge";
        self.latencyBadge=[UILabel new];self.latencyBadge.translatesAutoresizingMaskIntoConstraints=NO;self.latencyBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2);self.latencyBadge.textAlignment=NSTextAlignmentCenter;self.latencyBadge.layer.cornerRadius=6.5;self.latencyBadge.layer.cornerCurve=kCACornerCurveContinuous;self.latencyBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.latencyBadge,HostBorder());self.latencyBadge.clipsToBounds=YES;self.latencyBadge.backgroundColor=HostRaisedSurface();self.latencyBadge.textColor=HostSecondaryText();self.latencyBadge.userInteractionEnabled=YES;self.latencyBadge.accessibilityIdentifier=@"resource.latency.badge";
        UITapGestureRecognizer *latencyTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleLatencyBadgeTap)];[self.latencyBadge addGestureRecognizer:latencyTap];
        self.statusBadge=[UILabel new];self.statusBadge.translatesAutoresizingMaskIntoConstraints=NO;self.statusBadge.font=HostMonospacedDigitFont(10.5,UIFontWeightSemibold,UIFontTextStyleCaption2);self.statusBadge.textAlignment=NSTextAlignmentCenter;self.statusBadge.layer.cornerRadius=6.5;self.statusBadge.layer.cornerCurve=kCACornerCurveContinuous;self.statusBadge.layer.borderWidth=0.5;HostSetLayerBorderColor(self.statusBadge,HostBorder());self.statusBadge.clipsToBounds=YES;self.statusBadge.backgroundColor=HostNeutralSurface();self.statusBadge.textColor=HostSecondaryText();self.statusBadge.accessibilityIdentifier=@"resource.status.badge";
        self.detailDivider=[UIView new];self.detailDivider.translatesAutoresizingMaskIntoConstraints=NO;self.detailDivider.backgroundColor=[HostSeparator() colorWithAlphaComponent:0.42];
        [self.contentView addSubview:self.iconBadgeContainer];[self.contentView addSubview:self.leadingAccentBar];[self.contentView addSubview:self.dragHandleView];[self.contentView addSubview:self.profileTitleLabel];[self.contentView addSubview:self.protocolBadge];[self.contentView addSubview:self.latencyBadge];[self.contentView addSubview:self.statusBadge];[self.contentView addSubview:self.detailDivider];[self.contentView addSubview:self.profileDetailLabel];
        [NSLayoutConstraint activateConstraints:@[
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
            [self.latencyBadge.leadingAnchor constraintEqualToAnchor:self.protocolBadge.trailingAnchor constant:6],
            [self.latencyBadge.centerYAnchor constraintEqualToAnchor:self.protocolBadge.centerYAnchor],
            [self.latencyBadge.widthAnchor constraintGreaterThanOrEqualToConstant:44],
            [self.latencyBadge.heightAnchor constraintEqualToConstant:20],
            [self.statusBadge.leadingAnchor constraintEqualToAnchor:self.latencyBadge.trailingAnchor constant:6],
            [self.statusBadge.centerYAnchor constraintEqualToAnchor:self.protocolBadge.centerYAnchor],
            [self.statusBadge.heightAnchor constraintEqualToConstant:20],
            [self.statusBadge.trailingAnchor constraintLessThanOrEqualToAnchor:self.dragHandleView.leadingAnchor constant:-6],
            [self.dragHandleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
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
- (void)handleLatencyBadgeTap {
    if(!self.profileSource.length||!self.onTapLatency)return;
    HostAnimateSelection(self.latencyBadge);
    self.onTapLatency(self.profileSource);
}
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    self.backgroundColor=highlighted?HostHighlightedSurface():HostCard();
    if(UIAccessibilityIsReduceMotionEnabled())return;
    [UIView animateWithDuration:highlighted?0.10:0.24 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform=highlighted?CGAffineTransformMakeScale(0.985,0.985):CGAffineTransformIdentity;
    } completion:nil];
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
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDictionary *> *latencyResults;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *detailSummaryCache;
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
    self.selectedKind=@"all";NSString *savedSort=[NSUserDefaults.standardUserDefaults stringForKey:@"resourceListSortMode"];self.sortMode=(savedSort.length&&[@[@"manual",@"name",@"recent",@"attention"] containsObject:savedSort])?savedSort:@"manual";self.latencyResults=[NSMutableDictionary dictionary];self.detailSummaryCache=[NSMutableDictionary dictionary];
    self.resourceHeader=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(1,self.tableView.bounds.size.width),220)];
    self.resourceHeader.backgroundColor=HostBackground();

    self.topActionsStack=[UIStackView new];self.topActionsStack.translatesAutoresizingMaskIntoConstraints=NO;self.topActionsStack.axis=UILayoutConstraintAxisHorizontal;self.topActionsStack.alignment=UIStackViewAlignmentCenter;self.topActionsStack.distribution=UIStackViewDistributionFillEqually;self.topActionsStack.spacing=0;self.topActionsStack.backgroundColor=HostRaisedSurface();self.topActionsStack.layer.cornerRadius=23;self.topActionsStack.layer.cornerCurve=kCACornerCurveContinuous;self.topActionsStack.layer.borderWidth=.7;HostSetLayerBorderColor(self.topActionsStack,HostBorder());[self.resourceHeader addSubview:self.topActionsStack];
    NSArray *actions=@[@{ @"icon":@"plus", @"label":@"添加资源", @"selector":NSStringFromSelector(@selector(add)) }];
    for(NSDictionary *item in actions){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.translatesAutoresizingMaskIntoConstraints=NO;button.accessibilityLabel=item[@"label"];button.accessibilityIdentifier=[@"resource-action." stringByAppendingString:item[@"label"]];UIButtonConfiguration *config=[UIButtonConfiguration plainButtonConfiguration];config.image=[UIImage systemImageNamed:item[@"icon"]];config.baseForegroundColor=HostText();config.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);button.configuration=config;HostInstallPressFeedback(button);SEL selector=NSSelectorFromString(item[@"selector"]);[button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];[self.topActionsStack addArrangedSubview:button];[button.widthAnchor constraintEqualToConstant:44].active=YES;[button.heightAnchor constraintEqualToConstant:44].active=YES;}
    UIButton *moreButton=[UIButton buttonWithType:UIButtonTypeSystem];moreButton.translatesAutoresizingMaskIntoConstraints=NO;moreButton.accessibilityLabel=@"更多资源操作";moreButton.accessibilityIdentifier=@"resource-action.more";UIButtonConfiguration *moreConfig=[UIButtonConfiguration plainButtonConfiguration];moreConfig.image=[UIImage systemImageNamed:@"ellipsis"];moreConfig.baseForegroundColor=HostText();moreConfig.contentInsets=NSDirectionalEdgeInsetsMake(8,8,8,8);moreButton.configuration=moreConfig;HostInstallPressFeedback(moreButton);[moreButton.widthAnchor constraintEqualToConstant:44].active=YES;[moreButton.heightAnchor constraintEqualToConstant:44].active=YES;__weak typeof(self) weakSelf=self;UIAction *servicesAction=[UIAction actionWithTitle:@"脚本与服务" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *action){[weakSelf openServices];}];UIAction *filterAction=[UIAction actionWithTitle:@"筛选与排序" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] identifier:nil handler:^(UIAction *action){[weakSelf showResourceFilters];}];UIAction *probeAction=[UIAction actionWithTitle:@"检查全部资源连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *action){[weakSelf probeResources];}];UIAction *monitorAction=[UIAction actionWithTitle:@"站点与播放适配监测" image:[UIImage systemImageNamed:@"waveform.path.ecg"] identifier:nil handler:^(UIAction *action){[weakSelf openAdaptationMonitor];}];moreButton.menu=[UIMenu menuWithChildren:@[filterAction,probeAction,monitorAction,servicesAction]];moreButton.showsMenuAsPrimaryAction=YES;[self.topActionsStack addArrangedSubview:moreButton];

    self.resourceTitleLabel=[UILabel new];self.resourceTitleLabel.translatesAutoresizingMaskIntoConstraints=NO;self.resourceTitleLabel.text=@"资源";self.resourceTitleLabel.textColor=HostText();self.resourceTitleLabel.font=HostRoundedFont(34,UIFontWeightBold,UIFontTextStyleLargeTitle);self.resourceTitleLabel.adjustsFontForContentSizeCategory=YES;[self.resourceHeader addSubview:self.resourceTitleLabel];
    self.resourceSearchField=[UITextField new];self.resourceSearchField.translatesAutoresizingMaskIntoConstraints=NO;self.resourceSearchField.accessibilityIdentifier=@"resource-search-field";self.resourceSearchField.accessibilityLabel=@"搜索资源";self.resourceSearchField.placeholder=@"搜索资源";self.resourceSearchField.clearButtonMode=UITextFieldViewModeWhileEditing;self.resourceSearchField.returnKeyType=UIReturnKeySearch;self.resourceSearchField.delegate=self;self.resourceSearchField.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.resourceSearchField.adjustsFontForContentSizeCategory=YES;self.resourceSearchField.textColor=HostText();self.resourceSearchField.tintColor=HostAccent();self.resourceSearchField.backgroundColor=HostRaisedSurface();self.resourceSearchField.layer.cornerRadius=14;self.resourceSearchField.layer.cornerCurve=kCACornerCurveContinuous;self.resourceSearchField.layer.borderWidth=0.65;HostSetLayerBorderColor(self.resourceSearchField,HostBorder());self.resourceSearchField.leftViewMode=UITextFieldViewModeAlways;UIView *searchIconContainer=[[UIView alloc] initWithFrame:CGRectMake(0,0,38,44)];UIImageView *searchIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];searchIcon.tintColor=HostMutedText();searchIcon.frame=CGRectMake(12,13,18,18);searchIconContainer.userInteractionEnabled=NO;[searchIconContainer addSubview:searchIcon];self.resourceSearchField.leftView=searchIconContainer;
    self.sortFilterButton=[UIButton buttonWithType:UIButtonTypeSystem];self.sortFilterButton.accessibilityIdentifier=@"resource-sort-pill";self.sortFilterButton.titleLabel.font=HostMonospacedDigitFont(11.5,UIFontWeightSemibold,UIFontTextStyleCaption1);self.sortFilterButton.backgroundColor=HostNeutralSurface();self.sortFilterButton.tintColor=HostSecondaryText();self.sortFilterButton.layer.cornerRadius=11;self.sortFilterButton.layer.cornerCurve=kCACornerCurveContinuous;self.sortFilterButton.layer.borderWidth=0.55;HostSetLayerBorderColor(self.sortFilterButton,HostBorder());self.sortFilterButton.contentEdgeInsets=UIEdgeInsetsMake(4,9,4,9);self.sortFilterButton.showsMenuAsPrimaryAction=YES;HostInstallPressFeedback(self.sortFilterButton);
    UIView *sortRightContainer=[[UIView alloc] initWithFrame:CGRectMake(0,0,82,32)];self.sortFilterButton.frame=CGRectMake(0,3,74,26);[sortRightContainer addSubview:self.sortFilterButton];self.resourceSearchField.rightView=sortRightContainer;self.resourceSearchField.rightViewMode=UITextFieldViewModeUnlessEditing;
    [self updateSortPillButton];
    [self.resourceSearchField addTarget:self action:@selector(searchTextChanged) forControlEvents:UIControlEventEditingChanged];[self.resourceHeader addSubview:self.resourceSearchField];

    self.kindScroll=[UIScrollView new];self.kindScroll.translatesAutoresizingMaskIntoConstraints=NO;self.kindScroll.showsHorizontalScrollIndicator=NO;self.kindScroll.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.kindStack=[UIStackView new];self.kindStack.translatesAutoresizingMaskIntoConstraints=NO;self.kindStack.axis=UILayoutConstraintAxisHorizontal;self.kindStack.spacing=8;[self.kindScroll addSubview:self.kindStack];[self.resourceHeader addSubview:self.kindScroll];
    self.kindScrollHeightConstraint=[self.kindScroll.heightAnchor constraintEqualToConstant:48];
    self.resourceHeaderTopConstraint=[self.topActionsStack.topAnchor constraintEqualToAnchor:self.resourceHeader.topAnchor constant:4];
    [NSLayoutConstraint activateConstraints:@[self.resourceHeaderTopConstraint,[self.topActionsStack.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-16],[self.topActionsStack.widthAnchor constraintEqualToConstant:88],[self.topActionsStack.heightAnchor constraintEqualToConstant:44],[self.resourceTitleLabel.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.resourceTitleLabel.topAnchor constraintEqualToAnchor:self.topActionsStack.topAnchor],[self.resourceTitleLabel.heightAnchor constraintGreaterThanOrEqualToConstant:42],[self.resourceSearchField.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.resourceSearchField.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-20],[self.resourceSearchField.topAnchor constraintEqualToAnchor:self.resourceTitleLabel.bottomAnchor constant:6],[self.resourceSearchField.heightAnchor constraintGreaterThanOrEqualToConstant:44],[self.kindScroll.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:10],[self.kindScroll.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor],[self.kindScroll.topAnchor constraintEqualToAnchor:self.resourceSearchField.bottomAnchor constant:12],self.kindScrollHeightConstraint,[self.kindStack.leadingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.leadingAnchor],[self.kindStack.trailingAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.trailingAnchor constant:-10],[self.kindStack.topAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.topAnchor],[self.kindStack.bottomAnchor constraintEqualToAnchor:self.kindScroll.contentLayoutGuide.bottomAnchor],[self.kindStack.heightAnchor constraintEqualToAnchor:self.kindScroll.frameLayoutGuide.heightAnchor]]];
    self.importTaskContainer=[UIView new];self.importTaskContainer.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskContainer.backgroundColor=HostRaisedSurface();self.importTaskContainer.layer.cornerRadius=14;self.importTaskContainer.layer.cornerCurve=kCACornerCurveContinuous;self.importTaskContainer.layer.borderWidth=0.65;HostSetLayerBorderColor(self.importTaskContainer,[HostAccent() colorWithAlphaComponent:0.32]);self.importTaskContainer.clipsToBounds=YES;[self.resourceHeader addSubview:self.importTaskContainer];self.importTaskHeight=[self.importTaskContainer.heightAnchor constraintEqualToConstant:0];
    self.importTaskButton=[UIButton buttonWithType:UIButtonTypeSystem];self.importTaskButton.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskButton.titleLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];self.importTaskButton.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;self.importTaskButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;self.importTaskButton.contentEdgeInsets=UIEdgeInsetsMake(0,12,0,8);self.importTaskButton.tintColor=HostAccent();self.importTaskButton.accessibilityIdentifier=@"resource-import-task";[self.importTaskButton addTarget:self action:@selector(add) forControlEvents:UIControlEventTouchUpInside];[self.importTaskContainer addSubview:self.importTaskButton];
    self.importTaskToggleButton=[UIButton buttonWithType:UIButtonTypeSystem];self.importTaskToggleButton.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskToggleButton.accessibilityLabel=@"展开或收起导入任务";[self.importTaskToggleButton setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];self.importTaskToggleButton.tintColor=HostSecondaryText();[self.importTaskToggleButton addTarget:self action:@selector(toggleImportTaskExpanded) forControlEvents:UIControlEventTouchUpInside];[self.importTaskContainer addSubview:self.importTaskToggleButton];
    self.importTaskDetailLabel=[UILabel new];self.importTaskDetailLabel.translatesAutoresizingMaskIntoConstraints=NO;self.importTaskDetailLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];self.importTaskDetailLabel.textColor=HostSecondaryText();self.importTaskDetailLabel.numberOfLines=2;self.importTaskDetailLabel.hidden=YES;[self.importTaskContainer addSubview:self.importTaskDetailLabel];
    self.importTaskButtonHeight=[self.importTaskButton.heightAnchor constraintEqualToConstant:0];self.importTaskToggleHeight=[self.importTaskToggleButton.heightAnchor constraintEqualToConstant:0];
    self.importTaskDetailHeight=[self.importTaskDetailLabel.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[[self.importTaskContainer.leadingAnchor constraintEqualToAnchor:self.resourceHeader.leadingAnchor constant:20],[self.importTaskContainer.trailingAnchor constraintEqualToAnchor:self.resourceHeader.trailingAnchor constant:-20],[self.importTaskContainer.topAnchor constraintEqualToAnchor:self.kindScroll.bottomAnchor constant:4],[self.importTaskContainer.bottomAnchor constraintEqualToAnchor:self.resourceHeader.bottomAnchor constant:-6],self.importTaskHeight,[self.importTaskButton.leadingAnchor constraintEqualToAnchor:self.importTaskContainer.leadingAnchor],[self.importTaskButton.trailingAnchor constraintEqualToAnchor:self.importTaskToggleButton.leadingAnchor],[self.importTaskButton.topAnchor constraintEqualToAnchor:self.importTaskContainer.topAnchor],self.importTaskButtonHeight,[self.importTaskToggleButton.trailingAnchor constraintEqualToAnchor:self.importTaskContainer.trailingAnchor],[self.importTaskToggleButton.topAnchor constraintEqualToAnchor:self.importTaskContainer.topAnchor],[self.importTaskToggleButton.widthAnchor constraintEqualToConstant:44],self.importTaskToggleHeight,[self.importTaskDetailLabel.leadingAnchor constraintEqualToAnchor:self.importTaskContainer.leadingAnchor constant:12],[self.importTaskDetailLabel.trailingAnchor constraintEqualToAnchor:self.importTaskContainer.trailingAnchor constant:-12],[self.importTaskDetailLabel.topAnchor constraintEqualToAnchor:self.importTaskButton.bottomAnchor],self.importTaskDetailHeight]];
    self.tableView.tableHeaderView=self.resourceHeader;
    CGFloat tableBottomInset=MAX(8,self.bottomOverlayInset);self.tableView.contentInset=UIEdgeInsetsMake(0,0,tableBottomInset,0);self.tableView.scrollIndicatorInsets=self.tableView.contentInset;
    self.emptyLabel=[UILabel new];self.emptyLabel.textAlignment=NSTextAlignmentCenter;self.emptyLabel.textColor=HostSecondaryText();self.emptyLabel.numberOfLines=0;self.emptyLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.tableView.backgroundView=self.emptyLabel;
    UIRefreshControl *r = [UIRefreshControl new];
    [r addTarget:self action:@selector(refreshProfiles) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = r;
    self.navigationItem.rightBarButtonItems=nil;self.navigationItem.rightBarButtonItem=nil;
    self.compactHeader=[UIView new];self.compactHeader.backgroundColor=[HostBackground() colorWithAlphaComponent:.94];self.compactHeader.hidden=YES;[self.tableView addSubview:self.compactHeader];
    self.compactBlur=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];self.compactBlur.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.compactBlur.userInteractionEnabled=NO;[self.compactHeader addSubview:self.compactBlur];
    self.compactSeparator=[UIView new];self.compactSeparator.backgroundColor=HostSeparator();self.compactSeparator.userInteractionEnabled=NO;[self.compactHeader addSubview:self.compactSeparator];
    self.compactTitle=[UILabel new];self.compactTitle.text=@"资源";self.compactTitle.font=HostRoundedFont(17,UIFontWeightSemibold,UIFontTextStyleHeadline);self.compactTitle.textColor=HostText();[self.compactHeader addSubview:self.compactTitle];self.compactAdd=[UIButton buttonWithType:UIButtonTypeSystem];[self.compactAdd setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];self.compactAdd.accessibilityLabel=@"添加资源";[self.compactAdd addTarget:self action:@selector(add) forControlEvents:UIControlEventTouchUpInside];self.compactMore=[UIButton buttonWithType:UIButtonTypeSystem];[self.compactMore setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];self.compactMore.menu=moreButton.menu;self.compactMore.showsMenuAsPrimaryAction=YES;self.compactMore.accessibilityLabel=@"更多资源操作";for(UIButton *button in @[self.compactAdd,self.compactMore]){button.tintColor=HostText();button.backgroundColor=HostRaisedSurface();button.layer.cornerRadius=18;button.layer.cornerCurve=kCACornerCurveContinuous;button.layer.borderWidth=0.6;HostSetLayerBorderColor(button,HostBorder());HostInstallPressFeedback(button);[self.compactHeader addSubview:button];}
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
    [self updateSortPillButton];
    [self updateKindFilters];
    [self.tableView reloadData];
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
- (void)runtimeStateDidChange {[self reloadProfiles];}
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
}
- (void)updateSortPillButton {
    if(!self.sortFilterButton)return;
    NSDictionary *shortLabels=@{@"manual":@"⇅ 手动",@"name":@"⇅ A–Z",@"recent":@"⇅ 最近",@"attention":@"⇅ 待处理"};
    NSString *shortTitle=shortLabels[self.sortMode]?:@"⇅ 手动";
    BOOL customSort=![self.sortMode isEqual:@"manual"];
    [self.sortFilterButton setTitle:shortTitle forState:UIControlStateNormal];
    self.sortFilterButton.backgroundColor=customSort?HostSelectedSurface():HostNeutralSurface();
    self.sortFilterButton.tintColor=customSort?HostAccent():HostSecondaryText();
    HostSetLayerBorderColor(self.sortFilterButton,customSort?[HostAccent() colorWithAlphaComponent:0.35]:HostBorder());
    self.sortFilterButton.accessibilityLabel=[NSString stringWithFormat:@"资源排序：%@",shortTitle];
    __weak typeof(self) weakSelf=self;
    NSArray *sortOptions=@[@{@"id":@"manual",@"name":@"手动顺序"},@{@"id":@"name",@"name":@"名称 A–Z"},@{@"id":@"recent",@"name":@"最近更新"},@{@"id":@"attention",@"name":@"待处理优先"}];
    NSMutableArray<UIMenuElement *> *children=[NSMutableArray array];
    for(NSDictionary *option in sortOptions){
        NSString *identifier=option[@"id"],*name=option[@"name"];
        UIAction *action=[UIAction actionWithTitle:name image:[UIImage systemImageNamed:[identifier isEqual:self.sortMode]?@"checkmark":@"arrow.up.arrow.down"] identifier:nil handler:^(__unused UIAction *a){
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            owner.sortMode=identifier;
            [NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"resourceListSortMode"];
            [owner reloadProfiles];
        }];
        if([identifier isEqual:self.sortMode])action.state=UIMenuElementStateOn;
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
    NSString *sortName=@{@"manual":@"手动顺序",@"name":@"名称 A–Z",@"recent":@"最近更新",@"attention":@"待处理优先"}[self.sortMode]?:@"手动顺序";
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"筛选与排序" message:[NSString stringWithFormat:@"来源筛选 · %@\n排序方式 · %@",[self.selectedKind isEqual:@"all"]?@"全部来源":self.selectedKind,sortName] preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *sortOptions=@[@{@"id":@"manual",@"name":@"手动顺序"},@{@"id":@"name",@"name":@"名称 A–Z"},@{@"id":@"recent",@"name":@"最近更新"},@{@"id":@"attention",@"name":@"待处理优先"}];
    for(NSDictionary *option in sortOptions){NSString *identifier=option[@"id"],*name=option[@"name"];NSString *title=[NSString stringWithFormat:@"排序 · %@%@",name,[identifier isEqual:self.sortMode]?@" ✓":@""];[sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.sortMode=identifier;[NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"resourceListSortMode"];[self reloadProfiles];}]];}
    NSMutableArray *options=[NSMutableArray arrayWithArray:@[@{@"id":@"all",@"name":@"全部来源"},@{@"id":@"enabled",@"name":@"仅已启用资源"},@{@"id":@"script",@"name":@"脚本资源"}]];
    NSMutableSet *seen=[NSMutableSet set];for(NSDictionary *profile in self.allProfiles){NSString *domain=[self resourceDomainForProfile:profile];if(!domain.length||[seen containsObject:domain])continue;[seen addObject:domain];[options addObject:@{@"id":[@"domain:" stringByAppendingString:domain],@"name":domain}];}
    for(NSDictionary *option in options){NSString *identifier=option[@"id"],*name=option[@"name"];NSString *title=[NSString stringWithFormat:@"来源 · %@%@",name,[identifier isEqual:self.selectedKind]?@" ✓":@""];[sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){self.selectedKind=identifier;[self reloadProfiles];}]];}
    __weak typeof(self) weakSelf=self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制资源概览摘要" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf copyResourceDiagnosticSummary];}]];
    if(self.latencyResults.count)[sheet addAction:[UIAlertAction actionWithTitle:@"清除连接测速结果" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf.latencyResults removeAllObjects];[weakSelf.tableView reloadData];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.sourceView=self.topActionsStack;sheet.popoverPresentationController.sourceRect=self.topActionsStack.bounds;[self presentViewController:sheet animated:YES completion:nil];
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
    [self updateSortPillButton];
    [self updateKindFilters];
    NSArray *matchedProfiles=[self.allProfiles filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *p,NSDictionary *bindings){
        NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
        if(![self profile:p matchesKind:self.selectedKind?:@"all"])return NO;
        NSString *query=self.searchQuery?:@"";if(query.length&&![self profile:p matchesSearchQuery:query]&&![[p description].lowercaseString containsString:query])return NO;
        return [p[@"type"] isEqual:@"plugin"]||[p[@"type"] isEqual:@"tvbox"]||source.length>0||[p[@"native"] boolValue];
    }]];
    NSArray *profiles=matchedProfiles;
    if([self.sortMode isEqual:@"name"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[self resourceTitleForProfile:a] localizedStandardCompare:[self resourceTitleForProfile:b]];}];}
    else if([self.sortMode isEqual:@"recent"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){NSTimeInterval at=MAX([a[@"updatedAt"] doubleValue],[a[@"playlistUpdatedAt"] doubleValue]),bt=MAX([b[@"updatedAt"] doubleValue],[b[@"playlistUpdatedAt"] doubleValue]);if(at>bt)return NSOrderedAscending;if(at<bt)return NSOrderedDescending;return [[self resourceTitleForProfile:a] localizedStandardCompare:[self resourceTitleForProfile:b]];}];}
    else if([self.sortMode isEqual:@"attention"]){profiles=[matchedProfiles sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){BOOL aa=[self profile:a matchesKind:@"attention"],ba=[self profile:b matchesKind:@"attention"];if(aa!=ba)return aa?NSOrderedAscending:NSOrderedDescending;NSUInteger ai=[matchedProfiles indexOfObjectIdenticalTo:a],bi=[matchedProfiles indexOfObjectIdenticalTo:b];return ai<bi?NSOrderedAscending:(ai>bi?NSOrderedDescending:NSOrderedSame);}];}
    NSString *emptyText=profiles.count?@"":(self.searchQuery.length?@"没有找到匹配的移入资源，请尝试其他搜索词":(![self.selectedKind isEqual:@"all"]?@"当前筛选分类下暂无资源\n可切换顶部筛选胶囊查看全部":@"还没有导入资源\n点顶部“添加”导入影视脚本、直播服务或订阅列表"));
    if([self.profiles isEqualToArray:profiles]){self.emptyLabel.text=emptyText;return;}self.profiles=profiles;self.emptyLabel.text=emptyText;
    [self.tableView reloadData];
}
- (void)kindChanged {[self reloadProfiles];}
- (void)searchTextChanged {self.searchQuery=self.resourceSearchField.text.lowercaseString?:@"";[self reloadProfiles];}
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
        return [lines componentsJoinedByString:@"\n"];
    }
    if(tvbox){
        BOOL macCMS=[profile[@"catalogKind"] isEqual:@"maccms"];NSString *catalogTitle=macCMS?@"MacCMS 影视接口":@"资源合集";
        NSTimeInterval updated=[profile[@"updatedAt"] doubleValue];NSDateFormatter *savedFormatter=CCTVResourceListDateFormatter();NSString *saved=updated>0?[NSString stringWithFormat:@"最近保存 %@",[savedFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:updated]]]:@"尚无保存时间";
        return macCMS?[NSString stringWithFormat:@"%@%@ · 选中后浏览 · 仅请求当前接口\n%@",current,catalogTitle,saved]:[NSString stringWithFormat:@"%@%@ · %lu 个站点 · %lu 个已识别 · %lu 个直播列表\n%@",current,catalogTitle,(unsigned long)[profile[@"siteCount"] unsignedIntegerValue],(unsigned long)[profile[@"supportedCount"] unsignedIntegerValue],(unsigned long)[profile[@"liveCount"] unsignedIntegerValue],saved];
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
    NSDictionary *targetProfile=nil;
    for(NSDictionary *p in self.allProfiles)if([p[@"source"] isEqual:source]){targetProfile=p;break;}
    if(!targetProfile)return;
    NSURL *url=[self probeURLForProfile:targetProfile];
    if(!url){self.latencyResults[source]=@{@"notProbeable":@YES};[self.tableView reloadData];return;}
    self.latencyResults[source]=@{@"probing":@YES};
    [self.tableView reloadData];
    __weak typeof(self) weakSelf=self;
    NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];configuration.timeoutIntervalForRequest=4;configuration.timeoutIntervalForResource=5;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];request.HTTPMethod=@"HEAD";
    NSDate *start=[NSDate date];
    NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *rawResponse,NSError *error){
        double elapsed=[[NSDate date] timeIntervalSinceDate:start]*1000.0;
        NSHTTPURLResponse *response=[rawResponse isKindOfClass:NSHTTPURLResponse.class]?(id)rawResponse:nil;
        NSInteger status=response.statusCode;BOOL ok=!error&&status>=200&&status<300;
        NSDictionary *result=@{@"ok":@(ok),@"milliseconds":@(MAX(0,elapsed)),@"status":@(status)};
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(),^{
            ConfigCenterViewController *owner=weakSelf;if(!owner)return;
            owner.latencyResults[source]=result;
            [owner.tableView reloadData];
        });
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
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=8;queue.qualityOfService=NSQualityOfServiceUtility;
    NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];configuration.timeoutIntervalForRequest=4;configuration.timeoutIntervalForResource=5;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];__weak typeof(self) weakSelf=self;
    NSMutableArray<NSDictionary *> *targets=[NSMutableArray array];
    for(NSDictionary *profile in profiles){
        NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";NSURL *url=[self probeURLForProfile:profile];
        if(!url){if(source.length)self.latencyResults[source]=@{@"notProbeable":@YES};continue;}
        if(source.length)self.latencyResults[source]=@{@"probing":@YES};
        [targets addObject:@{@"source":source,@"url":url}];
    }
    [self.tableView reloadData];
    for(NSDictionary *target in targets){
        dispatch_group_enter(group);
        [queue addOperationWithBlock:^{
            NSURL *url=target[@"url"];NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:4];request.HTTPMethod=@"HEAD";
            NSDate *start=[NSDate date];__block NSHTTPURLResponse *response=nil;__block NSError *probeError=nil;dispatch_semaphore_t semaphore=dispatch_semaphore_create(0);
            NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *rawResponse,NSError *error){response=[rawResponse isKindOfClass:NSHTTPURLResponse.class]?(id)rawResponse:nil;probeError=error;dispatch_semaphore_signal(semaphore);}];[task resume];
            long waited=dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));if(waited!=0){[task cancel];probeError=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];}
            double elapsed=[[NSDate date] timeIntervalSinceDate:start]*1000.0;NSInteger status=response.statusCode;BOOL ok=!probeError&&status>=200&&status<300;
            NSDictionary *result=@{@"ok":@(ok),@"milliseconds":@(MAX(0,elapsed)),@"status":@(status)};NSString *source=target[@"source"];
            dispatch_async(dispatch_get_main_queue(),^{
                ConfigCenterViewController *owner=weakSelf;if(!owner||!source.length)return;owner.latencyResults[source]=result;
                NSUInteger row=[owner.profiles indexOfObjectPassingTest:^BOOL(NSDictionary *profile,NSUInteger index,BOOL *stop){return [profile[@"source"] isEqual:source];}];
                if(row!=NSNotFound){NSIndexPath *path=[NSIndexPath indexPathForRow:(NSInteger)row inSection:0];if([owner.tableView.indexPathsForVisibleRows containsObject:path])[owner.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];}
            });
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group,dispatch_get_main_queue(),^{
        NSOperationQueue *finishedQueue=queue;ConfigCenterViewController *owner=weakSelf;if(!owner)return;(void)finishedQueue;[session finishTasksAndInvalidate];owner.probingResources=NO;
        [UIView transitionWithView:owner.tableView duration:.18 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{[owner.tableView reloadData];} completion:nil];
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
    NSDictionary *profile=self.profiles[indexPath.row];BOOL plugin=[profile[@"type"] isEqual:@"plugin"],tvbox=[profile[@"type"] isEqual:@"tvbox"],hasExportMenu=plugin||[profile[@"source"] length]||[profile[@"native"] boolValue];
    CGFloat accessoryWidth=plugin?104:(tvbox?44:(hasExportMenu?104:56)),cardWidth=MAX(1,tableView.bounds.size.width-40);
    // Match the actual Auto Layout width of profileTitleLabel and profileDetailLabel.
    CGFloat textWidth=MAX(44,cardWidth-22-12-accessoryWidth);
    UIFont *titleFont=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline],*detailFont=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    CGRect titleBounds=[[self resourceTitleForProfile:profile] boundingRectWithSize:CGSizeMake(textWidth,ceil(titleFont.lineHeight*2)) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:titleFont} context:nil];
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByCharWrapping;paragraph.lineSpacing=3.2;paragraph.paragraphSpacing=2.0;
    CGRect detailBounds=[[self resourceDetailForProfile:profile] boundingRectWithSize:CGSizeMake(textWidth,CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:detailFont,NSParagraphStyleAttributeName:paragraph} context:nil];
    CGFloat titleHeight=MIN(ceil(titleFont.lineHeight*2),MAX(ceil(titleFont.lineHeight),ceil(titleBounds.size.height)));
    CGFloat detailHeight=MAX(ceil(detailFont.lineHeight),ceil(detailBounds.size.height))+26;
    // Keep extra room beyond the measured text. UIKit can make the cell's
    // content view slightly narrower for grouped insets/accessories than the
    // table width used above, which otherwise clips the final detail line.
    return MAX(112,ceil(14+titleHeight+6+detailHeight+14+14));
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
        if(c.detailTextLabel.text.length){NSMutableParagraphStyle *detailPara=[NSMutableParagraphStyle new];detailPara.lineBreakMode=NSLineBreakByCharWrapping;detailPara.lineSpacing=3.2;detailPara.paragraphSpacing=2.0;NSMutableAttributedString *attrDetail=[[NSMutableAttributedString alloc] initWithString:c.detailTextLabel.text attributes:@{NSFontAttributeName:c.detailTextLabel.font,NSForegroundColorAttributeName:HostSecondaryText(),NSParagraphStyleAttributeName:detailPara}];NSRange firstNewline=[c.detailTextLabel.text rangeOfString:@"\n"];NSRange firstLineRange=firstNewline.location!=NSNotFound?NSMakeRange(0,firstNewline.location):NSMakeRange(0,c.detailTextLabel.text.length);[attrDetail addAttribute:NSForegroundColorAttributeName value:[HostText() colorWithAlphaComponent:0.88] range:firstLineRange];c.detailTextLabel.attributedText=attrDetail;}
        c.detailDivider.backgroundColor=[HostSeparator() colorWithAlphaComponent:0.42];
        c.iconBadgeContainer.backgroundColor=[HostAccent() colorWithAlphaComponent:0.14];
        HostSetLayerBorderColor(c.iconBadgeContainer,[HostAccent() colorWithAlphaComponent:0.28]);
        UIColor *latencyColor=nil;NSString *rawLatency=[self latencyTextForProfile:p color:&latencyColor];
        if([p[@"native"] boolValue]&&[rawLatency isEqualToString:@"未检测"])rawLatency=@"官方源";
        c.latencyBadge.text=[NSString stringWithFormat:@"  %@  ",rawLatency];c.latencyBadge.textColor=latencyColor?:HostSecondaryText();c.latencyBadge.backgroundColor=HostRaisedSurface();HostSetLayerBorderColor(c.latencyBadge,HostBorder());c.latencyBadge.accessibilityLabel=[NSString stringWithFormat:@"资源测速：%@",rawLatency?:@"未测速"];
        NSString *rowSource=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";
        c.profileSource=rowSource;
        __weak typeof(self) weakLatencySelf=self;
        c.onTapLatency=^(NSString *tappedSource){[weakLatencySelf probeSingleProfile:tappedSource];};
        UIColor *statusTextColor=nil,*statusBgColor=nil,*statusBorderColor=nil;
        NSString *statusText=[self statusBadgeTextForProfile:p textColor:&statusTextColor backgroundColor:&statusBgColor borderColor:&statusBorderColor];
        c.statusBadge.text=statusText;c.statusBadge.textColor=statusTextColor?:HostSecondaryText();c.statusBadge.backgroundColor=statusBgColor?:HostNeutralSurface();HostSetLayerBorderColor(c.statusBadge,statusBorderColor?:HostBorder());
        BOOL isCurrent=[p[@"current"] boolValue];
        c.leadingAccentBar.backgroundColor=isCurrent?HostAccent():([p[@"enabled"] boolValue]?[HostAccent() colorWithAlphaComponent:0.75]:[HostMutedText() colorWithAlphaComponent:0.38]);
        if(isCurrent){c.layer.borderWidth=1.15;HostSetLayerBorderColor(c,HostAccent());c.iconBadgeContainer.backgroundColor=[HostAccent() colorWithAlphaComponent:0.22];}
        c.protocolBadge.backgroundColor=HostSelectedSurface();c.protocolBadge.textColor=HostAccent();HostSetLayerBorderColor(c.protocolBadge,[HostAccent() colorWithAlphaComponent:0.32]);
        NSString *protoTag=plugin?(p[@"runtime"]?:@"插件"):(tvbox?([p[@"catalogKind"] isEqual:@"maccms"]?@"MacCMS":@"合集"):@"M3U");c.protocolBadge.text=[NSString stringWithFormat:@"  %@  ",protoTag];
        if(!plugin&&!tvbox){
            UISwitch *s=[self compactSwitchForRow:ip.row enabled:[p[@"enabled"] boolValue] label:[NSString stringWithFormat:@"加入频道 %@",p[@"name"]?:@"订阅"] source:p[@"source"]];c.accessoryView=[self switchAccessoryForSwitch:s width:56];
        }
        if(plugin||tvbox||[p[@"source"] length]||[p[@"native"] boolValue]){
            __weak typeof(self) weakSelf=self;NSString *source=[p[@"source"] isKindOfClass:NSString.class]?p[@"source"]:@"";BOOL macCMS=[p[@"catalogKind"] isEqual:@"maccms"];
            UIAction *manage=[UIAction actionWithTitle:tvbox?(macCMS?@"打开影视接口":@"打开资源合集"): @"资源能力与设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(tvbox){if([source hasPrefix:@"tvbox:"]&&weakSelf.onOpenTVBoxCatalog)weakSelf.onOpenTVBoxCatalog([source substringFromIndex:6]);}else if(weakSelf.onOpenResource)weakSelf.onOpenResource(source);}];
            NSMutableArray<UIAction *> *menuActions=[NSMutableArray array];
            if(plugin||tvbox)[menuActions addObject:manage];
            else if([p[@"native"] boolValue]||source.length){
                [menuActions addObject:[UIAction actionWithTitle:@"资源详情与台标设置" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *a){if(weakSelf.onOpenSubscription)weakSelf.onOpenSubscription(source);}]];
            }
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
                [menuActions addObject:toggleListLogo];
                [menuActions addObject:toggleCornerLogo];
                [menuActions addObject:togglePreview];
                [menuActions addObject:toggleTelemetry];
                if(!tvbox&&weakSelf.onMatchStationLogos){
                    [menuActions addObject:[UIAction actionWithTitle:@"智能匹配官方台标与节目单" image:[UIImage systemImageNamed:@"sparkles.tv"] identifier:nil handler:^(UIAction *a){if(weakSelf.onMatchStationLogos)weakSelf.onMatchStationLogos(source);}]];
                }
            }
            if(tvbox){
                [menuActions addObject:[UIAction actionWithTitle:@"导出完整 JSON" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(UIAction *a){if(weakSelf.onExportResource)weakSelf.onExportResource(source,@"catalog-json");}]];
                [menuActions addObject:[UIAction actionWithTitle:@"导出资源 ZIP（含可获取的 PY / JS）" image:[UIImage systemImageNamed:@"archivebox"] identifier:nil handler:^(UIAction *a){if(weakSelf.onExportResource)weakSelf.onExportResource(source,@"catalog-zip");}]];
            }else{
                [menuActions addObject:[UIAction actionWithTitle:@"导出单项资源文件" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a){if(weakSelf.onExportResource)weakSelf.onExportResource(source,@"single");}]];
            }
            if(plugin&&self.onUseResource){NSString *resourceKind=p[@"resourceKind"];if([resourceKind isEqual:@"live"]||[resourceKind isEqual:@"both"])[menuActions addObject:[UIAction actionWithTitle:@"添加直播频道" image:[UIImage systemImageNamed:@"dot.radiowaves.left.and.right"] identifier:nil handler:^(UIAction *a){if(weakSelf.onUseResource)weakSelf.onUseResource(source,@"live");}]];if([resourceKind isEqual:@"vod"]||[resourceKind isEqual:@"both"])[menuActions addObject:[UIAction actionWithTitle:@"进入影视" image:[UIImage systemImageNamed:@"film"] identifier:nil handler:^(UIAction *a){if(weakSelf.onUseResource)weakSelf.onUseResource(source,@"vod");}]];}
            if(plugin){
                // 单条目刷新：只刷新这一行对应的订阅清单 / 健康 / EPG / 服务，
                // 不走整页刷新。无订阅清单的纯影视插件不显示清单与 EPG 项。
                NSString *subscriptionURL=[p[@"subscriptionURL"] isKindOfClass:NSString.class]?p[@"subscriptionURL"]:@"";
                if(subscriptionURL.length&&weakSelf.onRefreshProfile)[menuActions addObject:[UIAction actionWithTitle:@"刷新订阅清单" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRefreshProfile)weakSelf.onRefreshProfile(source);}]];
                if(weakSelf.onRecheckProfile)[menuActions addObject:[UIAction actionWithTitle:@"重新检测健康" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRecheckProfile)weakSelf.onRecheckProfile(source);}]];
                if(subscriptionURL.length&&weakSelf.onRematchEPGProfile)[menuActions addObject:[UIAction actionWithTitle:@"重新匹配节目单（EPG）" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRematchEPGProfile)weakSelf.onRematchEPGProfile(source);}]];
                if(weakSelf.onRestartProfile)[menuActions addObject:[UIAction actionWithTitle:@"重启服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRestartProfile)weakSelf.onRestartProfile(source);}]];
            }
            if(tvbox&&!macCMS&&weakSelf.onRefreshCatalogProfile){
                // MacCMS 行的 url 是接口地址而非可下载的 JSON 配置，不提供刷新。
                NSString *catalogURL=[p[@"url"] isKindOfClass:NSString.class]?p[@"url"]:@"";
                NSURL *catalogURLObject=[NSURL URLWithString:catalogURL];
                if(catalogURLObject&&[@[@"http",@"https"] containsObject:catalogURLObject.scheme.lowercaseString])[menuActions addObject:[UIAction actionWithTitle:@"刷新合集" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(weakSelf.onRefreshCatalogProfile)weakSelf.onRefreshCatalogProfile(source);}]];
            }
            if([self probeURLForProfile:p]){
                [menuActions addObject:[UIAction actionWithTitle:@"单条测速连接" image:[UIImage systemImageNamed:@"network"] identifier:nil handler:^(UIAction *a){[weakSelf probeSingleProfile:source];}]];
            }
            NSString *copyableURL=[p[@"url"] isKindOfClass:NSString.class]&&[p[@"url"] length]?p[@"url"]:([ProfileStore isHTTP:source]?source:@"");
            if(copyableURL.length){
                [menuActions addObject:[UIAction actionWithTitle:@"复制资源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:copyableURL];}]];
            }
            NSInteger rowIndex=ip.row;
            if(rowIndex>0){
                [menuActions addObject:[UIAction actionWithTitle:@"上移一行" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[weakSelf moveProfileFromIndexPath:[NSIndexPath indexPathForRow:rowIndex inSection:0] toIndexPath:[NSIndexPath indexPathForRow:rowIndex-1 inSection:0] updateTableView:NO];}]];
            }
            if(rowIndex+1<(NSInteger)self.profiles.count){
                [menuActions addObject:[UIAction actionWithTitle:@"下移一行" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[weakSelf moveProfileFromIndexPath:[NSIndexPath indexPathForRow:rowIndex inSection:0] toIndexPath:[NSIndexPath indexPathForRow:rowIndex+1 inSection:0] updateTableView:NO];}]];
            }
            if(source.length){
                UIAction *remove=[UIAction actionWithTitle:tvbox?(macCMS?@"移除影视接口":@"移除资源合集"): @"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[weakSelf confirmRemoveProfile:source];}];[menuActions addObject:remove];
            }
            UIButton *more=[UIButton buttonWithType:UIButtonTypeSystem];more.frame=CGRectMake(0,0,44,44);[more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];more.menu=[UIMenu menuWithChildren:menuActions];more.showsMenuAsPrimaryAction=YES;more.accessibilityLabel=@"更多资源操作";more.accessibilityIdentifier=[NSString stringWithFormat:@"resource-more-%ld",(long)ip.row];more.tintColor=HostSecondaryText();more.backgroundColor=HostNeutralSurface();more.layer.cornerRadius=12;more.layer.cornerCurve=kCACornerCurveContinuous;more.layer.borderWidth=.6;HostSetLayerBorderColor(more,HostBorder());HostInstallPressFeedback(more);
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
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if(ip.row<0||ip.row>=self.profiles.count)return;
    NSDictionary *profile=self.profiles[ip.row];if(![profile isKindOfClass:NSDictionary.class])return;
    NSString *source=[profile[@"source"] isKindOfClass:NSString.class]?profile[@"source"]:@"";
    if([profile[@"type"] isEqual:@"plugin"]){if(self.onOpenResource)self.onOpenResource(source);}
    else if([profile[@"type"] isEqual:@"tvbox"]){if([source hasPrefix:@"tvbox:"]&&self.onOpenTVBoxCatalog)self.onOpenTVBoxCatalog([source substringFromIndex:6]);}
    else {
        if(self.onOpenSubscription){self.onOpenSubscription(source);return;}
        UIAlertController *actions=[UIAlertController alertControllerWithTitle:profile[@"name"]?:@"订阅" message:source.length?source:nil preferredStyle:UIAlertControllerStyleActionSheet];
        if(self.onSelectProfile)[actions addAction:[UIAlertAction actionWithTitle:@"打开频道" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onSelectProfile(source);}]];
        if(source.length&&self.onEditProfile)[actions addAction:[UIAlertAction actionWithTitle:@"编辑订阅与节目单" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onEditProfile(source);}]];
        if(source.length&&self.onRefreshProfile)[actions addAction:[UIAlertAction actionWithTitle:@"刷新此订阅" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onRefreshProfile(source);}]];
        if(source.length&&self.onRecheckProfile)[actions addAction:[UIAlertAction actionWithTitle:@"重新检测健康" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onRecheckProfile(source);}]];
        if(source.length&&self.onRematchEPGProfile)[actions addAction:[UIAlertAction actionWithTitle:@"重新匹配节目单（EPG）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){self.onRematchEPGProfile(source);}]];
        [actions addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UITableViewCell *cell=[tableView cellForRowAtIndexPath:ip];actions.popoverPresentationController.sourceView=cell?:self.view;actions.popoverPresentationController.sourceRect=cell?cell.bounds:CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);[self presentViewController:actions animated:YES completion:nil];
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
            if(copyableURL.length)[actions addObject:[UIAction actionWithTitle:@"复制资源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:copyableURL];}]];
            [actions addObject:[UIAction actionWithTitle:@"复制资源名称" image:[UIImage systemImageNamed:@"textformat"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=profileName;}]];
            if(currentRow>0)[actions addObject:[UIAction actionWithTitle:@"上移" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow-1 inSection:0] updateTableView:NO];}]];
            if(currentRow+1<(NSInteger)w.profiles.count)[actions addObject:[UIAction actionWithTitle:@"下移" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow+1 inSection:0] updateTableView:NO];}]];
            [actions addObject:[UIAction actionWithTitle:macCMS?@"移除影视接口":@"移除资源合集" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];
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
        if(copyableURL.length)[actions addObject:[UIAction actionWithTitle:@"复制资源地址" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=[HostLogRedactor redactText:copyableURL];}]];
        [actions addObject:[UIAction actionWithTitle:@"复制资源名称" image:[UIImage systemImageNamed:@"textformat"] identifier:nil handler:^(UIAction *a){UIPasteboard.generalPasteboard.string=profileName;}]];
        if(!source.length)return [UIMenu menuWithTitle:@"资源操作" children:actions];
        if([source hasPrefix:@"plugin:"]){
            if(subscriptionURL.length)[actions addObject:[UIAction actionWithTitle:@"刷新订阅清单" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshProfile)w.onRefreshProfile(source);}]];
            [actions addObject:[UIAction actionWithTitle:@"重新检测健康" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction *a){if(w.onRecheckProfile)w.onRecheckProfile(source);}]];
            if(subscriptionURL.length)[actions addObject:[UIAction actionWithTitle:@"重新匹配节目单（EPG）" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a){if(w.onRematchEPGProfile)w.onRematchEPGProfile(source);}]];
            [actions addObject:[UIAction actionWithTitle:@"重启服务" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *a){if(w.onRestartProfile)w.onRestartProfile(source);}]];
            if(currentRow>0)[actions addObject:[UIAction actionWithTitle:@"上移" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow-1 inSection:0] updateTableView:NO];}]];
            if(currentRow+1<(NSInteger)w.profiles.count)[actions addObject:[UIAction actionWithTitle:@"下移" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *a){[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow+1 inSection:0] updateTableView:NO];}]];
            [actions addObject:[UIAction actionWithTitle:@"移除资源" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];
            return [UIMenu menuWithTitle:@"资源操作" children:actions];
        }
        [actions addObject:[UIAction actionWithTitle:@"刷新此订阅" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a){if(w.onRefreshProfile)w.onRefreshProfile(source);}]];
        [actions addObject:[UIAction actionWithTitle:@"重新检测健康" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(UIAction *a){if(w.onRecheckProfile)w.onRecheckProfile(source);}]];
        [actions addObject:[UIAction actionWithTitle:@"重新匹配节目单（EPG）" image:[UIImage systemImageNamed:@"list.bullet.rectangle"] identifier:nil handler:^(UIAction *a){if(w.onRematchEPGProfile)w.onRematchEPGProfile(source);}]];
        for(NSNumber *offset in @[@(-1),@1]){[actions addObject:[UIAction actionWithTitle:offset.integerValue<0?@"上移":@"下移" image:[UIImage systemImageNamed:offset.integerValue<0?@"arrow.up":@"arrow.down"] identifier:nil handler:^(UIAction *a){NSArray *sources=[w.allProfiles valueForKey:@"source"];sources=[sources filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id s,NSDictionary *b){return [s isKindOfClass:NSString.class]&&[(NSString *)s length]>0;}]];[ProfileStore move:source offset:offset.integerValue sources:sources];if(currentRow+offset.integerValue>=0&&currentRow+offset.integerValue<(NSInteger)w.profiles.count)[w moveProfileFromIndexPath:[NSIndexPath indexPathForRow:currentRow inSection:0] toIndexPath:[NSIndexPath indexPathForRow:currentRow+offset.integerValue inSection:0] updateTableView:NO];else[w reloadProfiles];}]];}
        [actions addObject:[UIAction actionWithTitle:@"移除订阅" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a){[w confirmRemoveProfile:source];}]];
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
    [alert addAction:[UIAlertAction actionWithTitle:tvbox?(macCMS?@"移除接口":@"移除合集"):(plugin?@"移除资源":@"移除订阅") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){if(self.onDeleteProfile)self.onDeleteProfile(source);[self reloadProfiles];}]];
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
