#import "HostGlassActionSheetViewController.h"
#import "HostTheme.h"

@implementation HostGlassSheetAction
+ (instancetype)actionWithTitle:(NSString *)title
                       subtitle:(NSString *)subtitle
                          value:(NSString *)value
                           icon:(NSString *)iconName
                           tint:(UIColor *)tintColor
                    destructive:(BOOL)destructive
                       selected:(BOOL)selected
                        handler:(dispatch_block_t)handler {
    HostGlassSheetAction *a = [HostGlassSheetAction new];
    a.title = title ?: @"";
    a.subtitle = subtitle;
    a.value = value;
    a.iconName = iconName;
    a.tintColor = tintColor;
    a.destructive = destructive;
    a.selected = selected;
    a.handler = handler;
    return a;
}
@end

@implementation HostGlassSheetSection
+ (instancetype)sectionWithTitle:(NSString *)title actions:(NSArray<HostGlassSheetAction *> *)actions {
    HostGlassSheetSection *s = [HostGlassSheetSection new];
    s.title = title;
    s.actions = actions ?: @[];
    s.horizontalChips = NO;
    return s;
}
+ (instancetype)chipSectionWithTitle:(NSString *)title actions:(NSArray<HostGlassSheetAction *> *)actions {
    HostGlassSheetSection *s = [HostGlassSheetSection new];
    s.title = title;
    s.actions = actions ?: @[];
    s.horizontalChips = YES;
    return s;
}
@end

@interface HostGlassActionSheetViewController ()
@property(nonatomic, strong) UIVisualEffectView *blurBackdrop;
@property(nonatomic, strong) UIView *tintOverlay;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *actionHandlers;
/// U02：动作已分发守卫——快速双击/重复点按只执行一次 handler。
@property(nonatomic, assign) BOOL actionDispatched;
- (void)dismissSheet;
- (void)runActionControl:(UIControl *)sender;
- (UILabel *)makeSectionHeaderLabel:(NSString *)title;
- (UIView *)makeChipRowCard:(NSArray<HostGlassSheetAction *> *)actions;
- (UIView *)makeGroupedRowsCard:(NSArray<HostGlassSheetAction *> *)actions;
- (UIView *)makeRowViewForAction:(HostGlassSheetAction *)action;
@end

@implementation HostGlassActionSheetViewController

+ (void)presentOn:(UIViewController *)presenter
            title:(NSString *)title
         subtitle:(NSString *)subtitle
        badgeText:(NSString *)badgeText
       badgeColor:(UIColor *)badgeColor
         sections:(NSArray<HostGlassSheetSection *> *)sections
       sourceView:(UIView *)sourceView {
    if (!presenter) return;
    HostGlassActionSheetViewController *sheet = [HostGlassActionSheetViewController new];
    sheet.sheetTitle = title ?: @"操作";
    sheet.sheetSubtitle = subtitle;
    sheet.badgeText = badgeText;
    sheet.badgeColor = badgeColor;
    sheet.sections = sections ?: @[];
    BOOL usePopover = (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && sourceView != nil);
    sheet.modalPresentationStyle = usePopover ? UIModalPresentationPopover : UIModalPresentationPageSheet;
    if (!usePopover) {
        if (@available(iOS 16.0, *)) {
            UISheetPresentationController *sp = sheet.sheetPresentationController;
            if (sp) {
                __weak typeof(sheet) weakSheet = sheet;
                UISheetPresentationControllerDetent *fitDetent = [UISheetPresentationControllerDetent customDetentWithIdentifier:@"host.sheet.fit" resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                    HostGlassActionSheetViewController *owner = weakSheet;
                    CGFloat maxH = context.maximumDetentValue;
                    if (!owner || !owner.isViewLoaded) return MIN(maxH, 360.0);
                    [owner.view layoutIfNeeded];
                    CGFloat contentH = owner.scrollView.contentSize.height + 116.0;
                    if (contentH <= 140.0) contentH = 320.0;
                    return MIN(maxH, MAX(220.0, contentH));
                }];
                sp.detents = @[fitDetent, UISheetPresentationControllerDetent.largeDetent];
                sp.prefersGrabberVisible = YES;
                sp.preferredCornerRadius = 28.0;
                sp.prefersScrollingExpandsWhenScrolledToEdge = YES;
            }
        } else if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sp = sheet.sheetPresentationController;
            if (sp) {
                sp.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
                sp.prefersGrabberVisible = YES;
                sp.preferredCornerRadius = 28.0;
                sp.prefersScrollingExpandsWhenScrolledToEdge = YES;
            }
        }
    }
    if (sheet.popoverPresentationController) {
        UIView *anchor = sourceView ?: presenter.view;
        sheet.popoverPresentationController.sourceView = anchor;
        sheet.popoverPresentationController.sourceRect = anchor.bounds;
        sheet.preferredContentSize = CGSizeMake(380.0, 440.0);
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.view.backgroundColor = UIColor.clearColor;
    self.view.accessibilityIdentifier = @"host.glass.action-sheet";
    self.actionHandlers = [NSMutableArray array];

    self.blurBackdrop = [[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];
    self.blurBackdrop.translatesAutoresizingMaskIntoConstraints = NO;
    HostRegisterGlassEffectView(self.blurBackdrop);
    [self.view addSubview:self.blurBackdrop];

    self.tintOverlay = [UIView new];
    self.tintOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    self.tintOverlay.backgroundColor = [HostBackground() colorWithAlphaComponent:0.84];
    self.tintOverlay.userInteractionEnabled = NO;
    [self.view addSubview:self.tintOverlay];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];
    self.scrollView = scroll;

    UIStackView *rootStack = [UIStackView new];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.axis = UILayoutConstraintAxisVertical;
    rootStack.alignment = UIStackViewAlignmentFill;
    rootStack.spacing = 11;
    [scroll addSubview:rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.blurBackdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.blurBackdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.blurBackdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.blurBackdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.tintOverlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tintOverlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tintOverlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tintOverlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [rootStack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [rootStack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:16],
        [rootStack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-16],
        [rootStack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28]
    ]];

    // Header
    UIView *headerRow = [UIView new];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.sheetTitle.length ? self.sheetTitle : @"操作";
    titleLabel.font = HostRoundedFont(18.0, UIFontWeightBold, UIFontTextStyleTitle3);
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.textColor = HostText();
    titleLabel.numberOfLines = 2;
    [headerRow addSubview:titleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *closeCfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:closeCfg] forState:UIControlStateNormal];
    closeBtn.tintColor = HostSecondaryText();
    closeBtn.backgroundColor = HostRaisedSurface();
    closeBtn.layer.cornerRadius = 15;
    closeBtn.layer.borderWidth = 0.55;
    HostSetLayerBorderColor(closeBtn, HostBorder());
    closeBtn.accessibilityLabel = @"关闭";
    closeBtn.isAccessibilityElement = NO; // 容器承载无障碍标签，避免重复朗读。
    closeBtn.userInteractionEnabled = NO; // 命中由外层 44×44 容器承接，视觉仍是 30pt 圆。
    HostInstallPressFeedback(closeBtn);
    // U02：关闭按钮视觉 30pt、有效命中 44×44——44pt 透明容器承接点按，
    // 圆钮在容器内居中，标题行的 trailing 锚点改到容器。
    UIControl *closeHit = [UIControl new];
    closeHit.translatesAutoresizingMaskIntoConstraints = NO;
    closeHit.accessibilityLabel = @"关闭";
    [closeHit addTarget:self action:@selector(dismissSheet) forControlEvents:UIControlEventTouchUpInside];
    [closeHit addSubview:closeBtn];
    [headerRow addSubview:closeHit];
    [NSLayoutConstraint activateConstraints:@[
        [closeBtn.centerXAnchor constraintEqualToAnchor:closeHit.centerXAnchor],
        [closeBtn.centerYAnchor constraintEqualToAnchor:closeHit.centerYAnchor],
        [closeBtn.widthAnchor constraintEqualToConstant:30],
        [closeBtn.heightAnchor constraintEqualToConstant:30]
    ]];

    UIStackView *metaStack = [UIStackView new];
    metaStack.translatesAutoresizingMaskIntoConstraints = NO;
    metaStack.axis = UILayoutConstraintAxisVertical;
    metaStack.alignment = UIStackViewAlignmentLeading;
    metaStack.spacing = 6;
    [headerRow addSubview:metaStack];

    if (self.badgeText.length) {
        UIColor *bc = self.badgeColor ?: HostAccent();
        UIView *pill = [UIView new];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.backgroundColor = [bc colorWithAlphaComponent:0.15];
        pill.layer.cornerRadius = 9;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.borderWidth = 0.55;
        HostSetLayerBorderColor(pill, [bc colorWithAlphaComponent:0.35]);
        UILabel *bl = [UILabel new];
        bl.translatesAutoresizingMaskIntoConstraints = NO;
        bl.text = self.badgeText;
        bl.font = HostMonospacedDigitFont(11.5, UIFontWeightSemibold, UIFontTextStyleCaption2);
        bl.adjustsFontForContentSizeCategory = YES;
        bl.textColor = bc;
        [pill addSubview:bl];
        [NSLayoutConstraint activateConstraints:@[
            [bl.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8],
            [bl.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-8],
            [bl.topAnchor constraintEqualToAnchor:pill.topAnchor constant:3.5],
            [bl.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-3.5]
        ]];
        [metaStack addArrangedSubview:pill];
    }

    if (self.sheetSubtitle.length) {
        UILabel *subLabel = [UILabel new];
        subLabel.text = self.sheetSubtitle;
        subLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        subLabel.adjustsFontForContentSizeCategory = YES;
        subLabel.textColor = HostSecondaryText();
        subLabel.numberOfLines = 0;
        [metaStack addArrangedSubview:subLabel];
    }

    [NSLayoutConstraint activateConstraints:@[
        [closeHit.topAnchor constraintEqualToAnchor:headerRow.topAnchor constant:2],
        [closeHit.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [closeHit.widthAnchor constraintEqualToConstant:44],
        [closeHit.heightAnchor constraintEqualToConstant:44],
        [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:closeHit.leadingAnchor constant:-10],
        [metaStack.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:(metaStack.arrangedSubviews.count ? 6 : 0)],
        [metaStack.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [metaStack.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [metaStack.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor]
    ]];
    [rootStack addArrangedSubview:headerRow];

    for (HostGlassSheetSection *section in self.sections) {
        if (!section.actions.count) continue;
        if (section.title.length) {
            [rootStack addArrangedSubview:[self makeSectionHeaderLabel:section.title]];
        }
        if (section.horizontalChips) {
            [rootStack addArrangedSubview:[self makeChipRowCard:section.actions]];
        } else {
            [rootStack addArrangedSubview:[self makeGroupedRowsCard:section.actions]];
        }
    }
}

- (void)reloadThemeAppearance {
    if (!self.isViewLoaded) return;
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    HostRefreshAppearanceLayers(self.view);
    self.tintOverlay.backgroundColor = [HostBackground() colorWithAlphaComponent:0.84];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection && [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self reloadThemeAppearance];
    }
}

- (void)dismissSheet {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)runActionControl:(UIControl *)sender {
    // U02：只触发一次——dismiss 动画期间控件仍在屏上，快速双击不得重复执行 handler。
    if (self.actionDispatched) return;
    self.actionDispatched = YES;
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= self.actionHandlers.count) return;
    dispatch_block_t block = self.actionHandlers[(NSUInteger)idx];
    [self dismissViewControllerAnimated:YES completion:^{
        if (block) block();
    }];
}

- (UILabel *)makeSectionHeaderLabel:(NSString *)title {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = HostRoundedFont(12.5, UIFontWeightSemibold, UIFontTextStyleCaption1);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = HostSecondaryText();
    return label;
}

- (UIView *)makeChipRowCard:(NSArray<HostGlassSheetAction *> *)actions {
    // U02：每行最多 4 个 chip（320pt 下单行 5 个也会被均分到 ~51pt，大字号下
    // 仍挤；超 4 个自动换行），保证 44×44pt 有效命中；选中不再只靠颜色，
    // 而是 selected trait + value/hint（与行式操作同款语义）。
    UIStackView *column = [UIStackView new];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 8;
    NSUInteger chunk = 4;
    for (NSUInteger start = 0; start < actions.count; start += chunk) {
        NSUInteger end = MIN(actions.count, start + chunk);
        UIStackView *row = [UIStackView new];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.axis = UILayoutConstraintAxisHorizontal;
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 8;
        for (NSUInteger i = start; i < end; i++) {
            HostGlassSheetAction *action = actions[i];
            UIColor *tint = action.destructive ? UIColor.systemRedColor : (action.tintColor ?: HostAccent());
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
            [btn setTitle:action.title forState:UIControlStateNormal];
            btn.titleLabel.font = HostMonospacedDigitFont(12.5, UIFontWeightSemibold, UIFontTextStyleCaption1);
            btn.titleLabel.adjustsFontForContentSizeCategory = YES;
            btn.titleLabel.adjustsFontSizeToFitWidth = YES;
            btn.titleLabel.minimumScaleFactor = 0.8;
            btn.backgroundColor = action.selected ? tint : HostCard();
            [btn setTitleColor:(action.selected ? HostOnAccent() : (action.destructive ? UIColor.systemRedColor : HostText())) forState:UIControlStateNormal];
            btn.layer.cornerRadius = 12;
            btn.layer.cornerCurve = kCACornerCurveContinuous;
            btn.layer.borderWidth = 0.65;
            HostSetLayerBorderColor(btn, action.selected ? tint : HostBorder());
            [btn.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
            btn.accessibilityTraits = UIAccessibilityTraitButton | (action.selected ? UIAccessibilityTraitSelected : 0);
            btn.accessibilityValue = action.value;
            btn.accessibilityHint = action.subtitle;
            btn.tag = (NSInteger)self.actionHandlers.count;
            [self.actionHandlers addObject:action.handler ? [action.handler copy] : (id)^{}];
            HostInstallPressFeedback(btn);
            [btn addTarget:self action:@selector(runActionControl:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:btn];
        }
        [column addArrangedSubview:row];
    }
    return column;
}

- (UIView *)makeGroupedRowsCard:(NSArray<HostGlassSheetAction *> *)actions {
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = HostCard();
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.6;
    card.clipsToBounds = YES;
    HostSetLayerBorderColor(card, HostBorder());

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 0;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor]
    ]];

    for (NSUInteger i = 0; i < actions.count; i++) {
        [stack addArrangedSubview:[self makeRowViewForAction:actions[i]]];
        if (i + 1 < actions.count) {
            UIView *sepWrap = [UIView new];
            sepWrap.translatesAutoresizingMaskIntoConstraints = NO;
            UIView *sep = [UIView new];
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            sep.backgroundColor = HostSeparator();
            [sepWrap addSubview:sep];
            [NSLayoutConstraint activateConstraints:@[
                [sepWrap.heightAnchor constraintEqualToConstant:0.5],
                [sep.topAnchor constraintEqualToAnchor:sepWrap.topAnchor],
                [sep.bottomAnchor constraintEqualToAnchor:sepWrap.bottomAnchor],
                [sep.leadingAnchor constraintEqualToAnchor:sepWrap.leadingAnchor constant:54],
                [sep.trailingAnchor constraintEqualToAnchor:sepWrap.trailingAnchor]
            ]];
            [stack addArrangedSubview:sepWrap];
        }
    }
    return card;
}

- (UIView *)makeRowViewForAction:(HostGlassSheetAction *)action {
    UIControl *row = [UIControl new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.isAccessibilityElement=YES;
    row.accessibilityLabel = action.title;
    row.accessibilityTraits = UIAccessibilityTraitButton|(action.selected?UIAccessibilityTraitSelected:0);
    row.accessibilityValue=action.value;
    row.accessibilityHint=action.subtitle;
    if (action.selected) {
        row.backgroundColor = HostSelectedSurface();
    }

    UIColor *tint = action.destructive ? UIColor.systemRedColor : (action.tintColor ?: HostAccent());
    UIView *badge = [UIView new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.userInteractionEnabled = NO;
    badge.backgroundColor = [tint colorWithAlphaComponent:0.15];
    badge.layer.cornerRadius = 8.5;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    [row addSubview:badge];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13.5 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(action.iconName.length ? action.iconName : @"circle.grid.2x2") withConfiguration:cfg]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = tint;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [badge addSubview:iv];

    UIStackView *textStack = [UIStackView new];
    textStack.translatesAutoresizingMaskIntoConstraints = NO;
    textStack.userInteractionEnabled = NO;
    textStack.axis = UILayoutConstraintAxisVertical;
    textStack.spacing = 2;
    [row addSubview:textStack];

    UILabel *titleLabel = [UILabel new];
    titleLabel.text = action.title;
    titleLabel.font = HostRoundedFont(14.5, UIFontWeightSemibold, UIFontTextStyleSubheadline);
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.textColor = action.destructive ? UIColor.systemRedColor : (action.selected ? HostAccent() : HostText());
    titleLabel.numberOfLines = 2;
    [textStack addArrangedSubview:titleLabel];

    if (action.subtitle.length) {
        UILabel *subLabel = [UILabel new];
        subLabel.text = action.subtitle;
        subLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        subLabel.adjustsFontForContentSizeCategory = YES;
        subLabel.textColor = HostSecondaryText();
        subLabel.numberOfLines = 2;
        [textStack addArrangedSubview:subLabel];
    }

    UIImageSymbolConfiguration *trailCfg = [UIImageSymbolConfiguration configurationWithPointSize:action.selected ? 16 : 12 weight:UIImageSymbolWeightSemibold];
    UIImageView *trailingIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(action.selected ? @"checkmark.circle.fill" : @"chevron.right") withConfiguration:trailCfg]];
    trailingIcon.translatesAutoresizingMaskIntoConstraints = NO;
    trailingIcon.tintColor = action.selected ? HostAccent() : HostMutedText();
    trailingIcon.userInteractionEnabled = NO;
    trailingIcon.hidden = action.destructive && !action.selected;
    [trailingIcon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:trailingIcon];
    HostInstallPressFeedback(row);

    NSLayoutXAxisAnchor *trailingAnchor = trailingIcon.leadingAnchor;
    if (action.value.length) {
        UILabel *valLabel = [UILabel new];
        valLabel.translatesAutoresizingMaskIntoConstraints = NO;
        valLabel.userInteractionEnabled = NO;
        valLabel.text = action.value;
        valLabel.font = HostMonospacedDigitFont(12.5, UIFontWeightMedium, UIFontTextStyleCaption1);
        valLabel.adjustsFontForContentSizeCategory = YES;
        valLabel.textColor = HostSecondaryText();
        [valLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [valLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [row addSubview:valLabel];
        [NSLayoutConstraint activateConstraints:@[
            [valLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [valLabel.trailingAnchor constraintEqualToAnchor:trailingIcon.leadingAnchor constant:-6]
        ]];
        trailingAnchor = valLabel.leadingAnchor;
    }

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:48],
        [badge.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [badge.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant:28],
        [badge.heightAnchor constraintEqualToConstant:28],
        [iv.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [trailingIcon.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [trailingIcon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:trailingAnchor constant:-8],
        [textStack.topAnchor constraintEqualToAnchor:row.topAnchor constant:9],
        [textStack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-9]
    ]];

    row.tag = (NSInteger)self.actionHandlers.count;
    [self.actionHandlers addObject:action.handler ? [action.handler copy] : (id)^{}];
    HostInstallPressFeedback(row);
    [row addTarget:self action:@selector(runActionControl:) forControlEvents:UIControlEventTouchUpInside];
    return row;
}

@end
