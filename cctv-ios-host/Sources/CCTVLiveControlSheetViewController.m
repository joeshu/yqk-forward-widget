#import "CCTVLiveControlSheetViewController.h"
#import "HostTheme.h"

@interface CCTVLiveControlSheetViewController ()
@property(nonatomic, strong) UIVisualEffectView *blurBackdrop;
@property(nonatomic, strong) UIView *tintOverlay;
@property(nonatomic, strong) UILabel *sleepStatusLabel;
@property(nonatomic, strong) NSArray<UIButton *> *sleepButtons;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *rowHandlers;
- (void)dismissSheet;
- (void)runRowAction:(UIControl *)sender;
- (void)sleepChipTapped:(UIButton *)sender;
- (void)updateSleepChipSelection;
- (UIView *)makeStatusPill:(NSString *)text textColor:(UIColor *)textColor bgColor:(UIColor *)bgColor borderColor:(UIColor *)borderColor;
- (UILabel *)makeSectionLabel:(NSString *)title;
- (UIButton *)makeBannerButtonWithTitle:(NSString *)title icon:(NSString *)iconName tint:(UIColor *)tint handler:(nullable dispatch_block_t)handler;
- (UIControl *)makeQuickTileWithTitle:(NSString *)title icon:(NSString *)iconName tint:(UIColor *)tint handler:(nullable dispatch_block_t)handler;
- (UIView *)makeGroupedCardWithRows:(NSArray<UIView *> *)rows;
- (UIView *)makeActionRowWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle value:(nullable NSString *)value icon:(NSString *)iconName tint:(UIColor *)tint handler:(nullable dispatch_block_t)handler;
- (UIView *)makeInlineSleepTimerRow;
@end

@implementation CCTVLiveControlSheetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.view.backgroundColor = UIColor.clearColor;
    self.view.accessibilityIdentifier = @"cctv.live.control-sheet";
    self.rowHandlers = [NSMutableArray array];

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

    UIStackView *rootStack = [UIStackView new];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.axis = UILayoutConstraintAxisVertical;
    rootStack.alignment = UIStackViewAlignmentFill;
    rootStack.spacing = 12;
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

    // 1. Header with channel title, status pills & close button
    UIView *headerRow = [UIView new];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = self.channelTitle.length ? self.channelTitle : @"播放控制";
    titleLabel.font = HostRoundedFont(18.5, UIFontWeightBold, UIFontTextStyleTitle3);
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.textColor = HostText();
    titleLabel.numberOfLines = 1;
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
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
    closeBtn.accessibilityLabel = @"关闭播放控制";
    HostInstallPressFeedback(closeBtn);
    [closeBtn addTarget:self action:@selector(dismissSheet) forControlEvents:UIControlEventTouchUpInside];
    [headerRow addSubview:closeBtn];

    UIStackView *pillRow = [UIStackView new];
    pillRow.translatesAutoresizingMaskIntoConstraints = NO;
    pillRow.axis = UILayoutConstraintAxisHorizontal;
    pillRow.alignment = UIStackViewAlignmentCenter;
    pillRow.spacing = 6;
    [headerRow addSubview:pillRow];

    UIColor *modeColor = self.catchupActive ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
    NSString *statusText = self.catchupActive ? [NSString stringWithFormat:@"↺ %@", self.modeLabel ?: @"回看中"] : @"● 实时直播";
    [pillRow addArrangedSubview:[self makeStatusPill:statusText textColor:modeColor bgColor:[modeColor colorWithAlphaComponent:0.15] borderColor:[modeColor colorWithAlphaComponent:0.35]]];
    [pillRow addArrangedSubview:[self makeStatusPill:[NSString stringWithFormat:@"线路 · %@", self.routeLabel.length ? self.routeLabel : @"自动"] textColor:HostSecondaryText() bgColor:HostRaisedSurface() borderColor:HostBorder()]];
    UIView *pillSpacer = [UIView new];
    [pillSpacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [pillRow addArrangedSubview:pillSpacer];

    [NSLayoutConstraint activateConstraints:@[
        [closeBtn.topAnchor constraintEqualToAnchor:headerRow.topAnchor constant:2],
        [closeBtn.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [closeBtn.widthAnchor constraintEqualToConstant:30],
        [closeBtn.heightAnchor constraintEqualToConstant:30],
        [titleLabel.topAnchor constraintEqualToAnchor:headerRow.topAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:closeBtn.leadingAnchor constant:-10],
        [pillRow.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:7],
        [pillRow.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor],
        [pillRow.trailingAnchor constraintEqualToAnchor:headerRow.trailingAnchor],
        [pillRow.bottomAnchor constraintEqualToAnchor:headerRow.bottomAnchor]
    ]];
    [rootStack addArrangedSubview:headerRow];

    // 2. Conditional failure recovery banner
    if (self.playbackFailed && self.onRetryAlternate) {
        [rootStack addArrangedSubview:[self makeBannerButtonWithTitle:@"换线路 / 换源重试" icon:@"arrow.triangle.2.circlepath" tint:HostAccent() handler:self.onRetryAlternate]];
    }

    // 3. 4-column tactile Control Center quick grid
    UIStackView *quickGrid = [UIStackView new];
    quickGrid.axis = UILayoutConstraintAxisHorizontal;
    quickGrid.distribution = UIStackViewDistributionFillEqually;
    quickGrid.spacing = 9;
    [quickGrid addArrangedSubview:[self makeQuickTileWithTitle:(self.fullscreenActive ? @"退出全屏" : @"全屏") icon:(self.fullscreenActive ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right") tint:HostAccent() handler:self.onToggleFullscreen]];
    [quickGrid addArrangedSubview:[self makeQuickTileWithTitle:@"投屏" icon:@"airplayvideo" tint:UIColor.systemBlueColor handler:self.onCast]];
    [quickGrid addArrangedSubview:[self makeQuickTileWithTitle:@"上一频道" icon:@"backward.end.fill" tint:HostText() handler:self.onPrevChannel]];
    [quickGrid addArrangedSubview:[self makeQuickTileWithTitle:@"下一频道" icon:@"forward.end.fill" tint:HostText() handler:self.onNextChannel]];
    [rootStack addArrangedSubview:quickGrid];

    if (self.catchupActive && self.onReturnLive) {
        [rootStack addArrangedSubview:[self makeBannerButtonWithTitle:@"返回实时直播" icon:@"dot.radiowaves.left.and.right" tint:UIColor.systemGreenColor handler:self.onReturnLive]];
    }

    // 4. Primary playback & channel section
    [rootStack addArrangedSubview:[self makeSectionLabel:@"播放与频道"]];
    NSMutableArray<UIView *> *playbackRows = [NSMutableArray array];
    [playbackRows addObject:[self makeActionRowWithTitle:@"切换线路" subtitle:@"选择更流畅的直播信号源" value:(self.routeLabel.length ? self.routeLabel : @"自动") icon:@"antenna.radiowaves.left.and.right" tint:HostAccent() handler:self.onRoutes]];
    [playbackRows addObject:[self makeActionRowWithTitle:@"节目单" subtitle:@"查看频道预告与 7 天回看" value:nil icon:@"calendar.badge.clock" tint:UIColor.systemBlueColor handler:self.onEPG]];
    if (self.canTimeshiftOrCatchup) {
        [playbackRows addObject:[self makeActionRowWithTitle:@"时移 / 回看" subtitle:@"拖动进度回看或跳转指定时间" value:(self.catchupActive ? @"回看中" : @"可用") icon:@"clock.arrow.circlepath" tint:UIColor.systemOrangeColor handler:self.onTimeshift]];
    }
    if (self.pipSupported && self.onPiP) {
        [playbackRows addObject:[self makeActionRowWithTitle:@"画中画" subtitle:@"切至悬浮小窗继续观看" value:nil icon:@"pip.enter" tint:UIColor.systemTealColor handler:self.onPiP]];
    }
    [rootStack addArrangedSubview:[self makeGroupedCardWithRows:playbackRows]];

    // 5. Tools & diagnostics section (with inline sleep timer chips)
    [rootStack addArrangedSubview:[self makeSectionLabel:@"定时与诊断"]];
    NSMutableArray<UIView *> *toolRows = [NSMutableArray array];
    [toolRows addObject:[self makeInlineSleepTimerRow]];
    [toolRows addObject:[self makeActionRowWithTitle:@"播放信息" subtitle:@"码率 · 编解码 · 缓冲遥测" value:nil icon:@"gauge.with.dots.needle.bottom.50percent" tint:UIColor.systemTealColor handler:self.onPlaybackInfo]];
    [toolRows addObject:[self makeActionRowWithTitle:@"诊断日志" subtitle:@"查看连接与播放事件记录" value:nil icon:@"doc.text.magnifyingglass" tint:HostSecondaryText() handler:self.onDiagnosticLog]];
    [rootStack addArrangedSubview:[self makeGroupedCardWithRows:toolRows]];
}

- (void)reloadThemeAppearance {
    if (!self.isViewLoaded) return;
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    self.view.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    HostRefreshAppearanceLayers(self.view);
    self.tintOverlay.backgroundColor = [HostBackground() colorWithAlphaComponent:0.84];
    [self updateSleepChipSelection];
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

- (void)runRowAction:(UIControl *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (NSUInteger)idx >= self.rowHandlers.count) return;
    dispatch_block_t block = self.rowHandlers[(NSUInteger)idx];
    [self dismissViewControllerAnimated:YES completion:^{
        if (block) block();
    }];
}

- (UIView *)makeStatusPill:(NSString *)text textColor:(UIColor *)textColor bgColor:(UIColor *)bgColor borderColor:(UIColor *)borderColor {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = HostMonospacedDigitFont(11.5, UIFontWeightSemibold, UIFontTextStyleCaption2);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = textColor;
    UIView *pill = [UIView new];
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    pill.backgroundColor = bgColor;
    pill.layer.cornerRadius = 9;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.layer.borderWidth = 0.55;
    HostSetLayerBorderColor(pill, borderColor);
    [pill addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-8],
        [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:3.5],
        [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-3.5]
    ]];
    return pill;
}

- (UILabel *)makeSectionLabel:(NSString *)title {
    UILabel *label = [UILabel new];
    label.text = title;
    label.font = HostRoundedFont(12.5, UIFontWeightSemibold, UIFontTextStyleCaption1);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = HostSecondaryText();
    return label;
}

- (UIButton *)makeBannerButtonWithTitle:(NSString *)title icon:(NSString *)iconName tint:(UIColor *)tint handler:(dispatch_block_t)handler {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.backgroundColor = [tint colorWithAlphaComponent:0.14];
    btn.tintColor = tint;
    btn.layer.cornerRadius = 14;
    btn.layer.cornerCurve = kCACornerCurveContinuous;
    btn.layer.borderWidth = 0.85;
    HostSetLayerBorderColor(btn, [tint colorWithAlphaComponent:0.42]);
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    [btn setImage:[UIImage systemImageNamed:iconName withConfiguration:cfg] forState:UIControlStateNormal];
    [btn setTitle:[NSString stringWithFormat:@"  %@", title] forState:UIControlStateNormal];
    btn.titleLabel.font = HostRoundedFont(14.5, UIFontWeightSemibold, UIFontTextStyleSubheadline);
    btn.titleLabel.adjustsFontForContentSizeCategory = YES;
    [btn.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    btn.tag = (NSInteger)self.rowHandlers.count;
    [self.rowHandlers addObject:handler ? [handler copy] : (id)^{}];
    HostInstallPressFeedback(btn);
    [btn addTarget:self action:@selector(runRowAction:) forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIControl *)makeQuickTileWithTitle:(NSString *)title icon:(NSString *)iconName tint:(UIColor *)tint handler:(dispatch_block_t)handler {
    UIControl *tile = [UIControl new];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = HostCard();
    tile.layer.cornerRadius = 16;
    tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(tile, HostBorder());
    tile.accessibilityLabel = title;
    tile.accessibilityTraits = UIAccessibilityTraitButton;

    UIView *iconWrap = [UIView new];
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;
    iconWrap.userInteractionEnabled = NO;
    iconWrap.backgroundColor = [tint colorWithAlphaComponent:0.14];
    iconWrap.layer.cornerRadius = 11;
    iconWrap.layer.cornerCurve = kCACornerCurveContinuous;
    [tile addSubview:iconWrap];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName withConfiguration:cfg]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = tint;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    [iconWrap addSubview:iv];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.userInteractionEnabled = NO;
    label.text = title;
    label.font = HostRoundedFont(11.5, UIFontWeightSemibold, UIFontTextStyleCaption2);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = HostText();
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [tile addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [tile.heightAnchor constraintGreaterThanOrEqualToConstant:74],
        [iconWrap.topAnchor constraintEqualToAnchor:tile.topAnchor constant:11],
        [iconWrap.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        [iconWrap.widthAnchor constraintEqualToConstant:34],
        [iconWrap.heightAnchor constraintEqualToConstant:34],
        [iv.centerXAnchor constraintEqualToAnchor:iconWrap.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:iconWrap.centerYAnchor],
        [label.topAnchor constraintEqualToAnchor:iconWrap.bottomAnchor constant:6],
        [label.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:4],
        [label.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-4],
        [label.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-9]
    ]];

    tile.tag = (NSInteger)self.rowHandlers.count;
    [self.rowHandlers addObject:handler ? [handler copy] : (id)^{}];
    HostInstallPressFeedback(tile);
    [tile addTarget:self action:@selector(runRowAction:) forControlEvents:UIControlEventTouchUpInside];
    return tile;
}

- (UIView *)makeGroupedCardWithRows:(NSArray<UIView *> *)rows {
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

    for (NSUInteger i = 0; i < rows.count; i++) {
        [stack addArrangedSubview:rows[i]];
        if (i + 1 < rows.count) {
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
                [sep.leadingAnchor constraintEqualToAnchor:sepWrap.leadingAnchor constant:56],
                [sep.trailingAnchor constraintEqualToAnchor:sepWrap.trailingAnchor]
            ]];
            [stack addArrangedSubview:sepWrap];
        }
    }
    return card;
}

- (UIView *)makeActionRowWithTitle:(NSString *)title subtitle:(NSString *)subtitle value:(NSString *)value icon:(NSString *)iconName tint:(UIColor *)tint handler:(dispatch_block_t)handler {
    UIControl *row = [UIControl new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.accessibilityLabel = title;
    row.accessibilityTraits = UIAccessibilityTraitButton;

    UIView *badge = [UIView new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.userInteractionEnabled = NO;
    badge.backgroundColor = [tint colorWithAlphaComponent:0.15];
    badge.layer.cornerRadius = 9;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    [row addSubview:badge];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName withConfiguration:cfg]];
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
    titleLabel.text = title;
    titleLabel.font = HostRoundedFont(15, UIFontWeightSemibold, UIFontTextStyleSubheadline);
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.textColor = HostText();
    [textStack addArrangedSubview:titleLabel];

    if (subtitle.length) {
        UILabel *subLabel = [UILabel new];
        subLabel.text = subtitle;
        subLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        subLabel.adjustsFontForContentSizeCategory = YES;
        subLabel.textColor = HostSecondaryText();
        subLabel.numberOfLines = 1;
        subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [textStack addArrangedSubview:subLabel];
    }

    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg]];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.tintColor = HostMutedText();
    chevron.userInteractionEnabled = NO;
    [chevron setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addSubview:chevron];

    NSLayoutXAxisAnchor *trailingAnchor = chevron.leadingAnchor;
    if (value.length) {
        UILabel *valLabel = [UILabel new];
        valLabel.translatesAutoresizingMaskIntoConstraints = NO;
        valLabel.userInteractionEnabled = NO;
        valLabel.text = value;
        valLabel.font = HostMonospacedDigitFont(12.5, UIFontWeightMedium, UIFontTextStyleCaption1);
        valLabel.adjustsFontForContentSizeCategory = YES;
        valLabel.textColor = HostSecondaryText();
        [valLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [valLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [row addSubview:valLabel];
        [NSLayoutConstraint activateConstraints:@[
            [valLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [valLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-6]
        ]];
        trailingAnchor = valLabel.leadingAnchor;
    }

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:54],
        [badge.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [badge.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant:30],
        [badge.heightAnchor constraintEqualToConstant:30],
        [iv.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [chevron.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [textStack.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12],
        [textStack.trailingAnchor constraintLessThanOrEqualToAnchor:trailingAnchor constant:-8],
        [textStack.topAnchor constraintEqualToAnchor:row.topAnchor constant:10],
        [textStack.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-10]
    ]];

    row.tag = (NSInteger)self.rowHandlers.count;
    [self.rowHandlers addObject:handler ? [handler copy] : (id)^{}];
    HostInstallPressFeedback(row);
    [row addTarget:self action:@selector(runRowAction:) forControlEvents:UIControlEventTouchUpInside];
    return row;
}

- (UIView *)makeInlineSleepTimerRow {
    UIView *container = [UIView new];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *badge = [UIView new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [UIColor.systemIndigoColor colorWithAlphaComponent:0.16];
    badge.layer.cornerRadius = 9;
    badge.layer.cornerCurve = kCACornerCurveContinuous;
    [container addSubview:badge];

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"moon.zzz.fill" withConfiguration:cfg]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.tintColor = UIColor.systemIndigoColor;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [badge addSubview:iv];

    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"睡眠定时关闭";
    titleLabel.font = HostRoundedFont(15, UIFontWeightSemibold, UIFontTextStyleSubheadline);
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.textColor = HostText();
    [container addSubview:titleLabel];

    self.sleepStatusLabel = [UILabel new];
    self.sleepStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sleepStatusLabel.font = HostMonospacedDigitFont(12, UIFontWeightMedium, UIFontTextStyleCaption1);
    self.sleepStatusLabel.adjustsFontForContentSizeCategory = YES;
    self.sleepStatusLabel.textColor = HostSecondaryText();
    [container addSubview:self.sleepStatusLabel];

    UIStackView *chips = [UIStackView new];
    chips.translatesAutoresizingMaskIntoConstraints = NO;
    chips.axis = UILayoutConstraintAxisHorizontal;
    chips.distribution = UIStackViewDistributionFillEqually;
    chips.spacing = 8;
    [container addSubview:chips];

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSNumber *mins in @[@0, @15, @30, @60]) {
        NSInteger m = mins.integerValue;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = m;
        [b setTitle:(m == 0 ? @"关闭" : [NSString stringWithFormat:@"%ld 分钟", (long)m]) forState:UIControlStateNormal];
        b.titleLabel.font = HostMonospacedDigitFont(12, UIFontWeightSemibold, UIFontTextStyleCaption1);
        b.titleLabel.adjustsFontForContentSizeCategory = YES;
        b.layer.cornerRadius = 10;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.layer.borderWidth = 0.6;
        [b.heightAnchor constraintGreaterThanOrEqualToConstant:32].active = YES;
        HostInstallPressFeedback(b);
        [b addTarget:self action:@selector(sleepChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [chips addArrangedSubview:b];
        [buttons addObject:b];
    }
    self.sleepButtons = buttons;
    [self updateSleepChipSelection];

    [NSLayoutConstraint activateConstraints:@[
        [badge.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:14],
        [badge.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [badge.widthAnchor constraintEqualToConstant:30],
        [badge.heightAnchor constraintEqualToConstant:30],
        [iv.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [iv.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [titleLabel.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12],
        [titleLabel.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [self.sleepStatusLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-14],
        [self.sleepStatusLabel.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [self.sleepStatusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.trailingAnchor constant:8],
        [chips.topAnchor constraintEqualToAnchor:badge.bottomAnchor constant:10],
        [chips.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:14],
        [chips.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-14],
        [chips.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12]
    ]];
    return container;
}

- (void)sleepChipTapped:(UIButton *)sender {
    self.sleepMinutes = sender.tag;
    [self updateSleepChipSelection];
    if (self.onSelectSleepMinutes) self.onSelectSleepMinutes(sender.tag);
}

- (void)updateSleepChipSelection {
    self.sleepStatusLabel.text = self.sleepMinutes > 0 ? [NSString stringWithFormat:@"%ld 分钟后暂停", (long)self.sleepMinutes] : @"已关闭";
    self.sleepStatusLabel.textColor = self.sleepMinutes > 0 ? HostAccent() : HostSecondaryText();
    for (UIButton *b in self.sleepButtons) {
        BOOL active = (b.tag == self.sleepMinutes);
        b.backgroundColor = active ? HostAccent() : HostRaisedSurface();
        [b setTitleColor:(active ? HostOnAccent() : HostText()) forState:UIControlStateNormal];
        HostSetLayerBorderColor(b, active ? HostAccent() : HostBorder());
    }
}

@end
