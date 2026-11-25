#import "HostEmptyStateView.h"

// 布局常量：图标与文字间距、整体 周边的内边距。值与既有空态 的视觉密度一致，
// 大字号下因文字使用 adaptive font 仍会自然撑高，不需手动放大。
static const CGFloat kHostEmptySymbolPointSize = 30.0;
static const CGFloat kHostEmptyStackSpacing = 10.0;
static const CGFloat kHostEmptyHorizontalInset = 32.0;
static const CGFloat kHostEmptySymbolTopInset = 6.0;

@interface HostEmptyStateView ()
- (void)_buildInterface;
- (void)_updateAccessibility;
- (void)_actionTapped;
@end

@implementation HostEmptyStateView {
    UIStackView *_stack;
    UIImageView *_symbolView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIButton *_actionButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self _buildInterface];
    }
    return self;
}

- (void)_buildInterface {
    // 背景 透明：本视图作为 `tableView.backgroundView` 时，表 表背景由 表 backgroundView
    // 之下的 controller 背景提供；保留透明避免遮挡主题背景。
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = YES;

    _symbolView = [UIImageView new];
    _symbolView.contentMode = UIViewContentModeCenter;
    _symbolView.tintColor = HostSecondaryText();
    _symbolView.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:kHostEmptySymbolPointSize weight:UIImageSymbolWeightRegular];
    _symbolView.translatesAutoresizingMaskIntoConstraints = NO;
    _symbolView.isHidden = YES;

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.textColor = HostText();
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 0;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.isHidden = YES;

    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _subtitleLabel.adjustsFontForContentSizeCategory = YES;
    _subtitleLabel.textColor = HostSecondaryText();
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.numberOfLines = 0;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.isHidden = YES;

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _actionButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    _actionButton.hidden = YES;
    _actionButton.contentEdgeInsets = UIEdgeInsetsMake(10, 18, 10, 18);
    _actionButton.layer.cornerRadius = 14;
    _actionButton.layer.cornerCurve = kCACornerCurveContinuous;
    _actionButton.layer.borderWidth = 0.6;
    HostSetLayerBorderColor(_actionButton, HostBorder());
    _actionButton.backgroundColor = HostRaisedSurface();
    [_actionButton addTarget:self action:@selector(_actionTapped) forControlEvents:UIControlEventTouchUpInside];

    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.alignment = UIStackViewAlignmentCenter;
    _stack.distribution = UIStackViewDistributionFill;
    _stack.spacing = kHostEmptyStackSpacing;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stack];
    [_stack addArrangedSubview:_symbolView];
    [_stack addArrangedSubview:_titleLabel];
    [_stack addArrangedSubview:_subtitleLabel];
    [_stack addArrangedSubview:_actionButton];

    // 居中并保留水平内边距；底部 多留一点 让大字号下不至于贴边。
    [NSLayoutConstraint activateConstraints:@[
        [_stack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                                         constant:kHostEmptyHorizontalInset],
        [_stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                        constant:-kHostEmptyHorizontalInset],
        [_symbolView.topAnchor constraintGreaterThanOrEqualToAnchor:_stack.topAnchor
                                                          constant:kHostEmptySymbolTopInset],
        // 顶部略下移，避免 大字号下居中时图标贴 顶部安全区。
        [_stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.layoutMarginsGuide.topAnchor],
    ]];
}

#pragma mark - Public setters

- (void)setTitle:(NSString *)title {
    _titleLabel.text = title;
    _titleLabel.hidden = !title.length;
    [self _updateAccessibility];
}

- (NSString *)title {
    return _titleLabel.text;
}

- (void)setSubtitle:(NSString *)subtitle {
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = !subtitle.length;
    [self _updateAccessibility];
}

- (NSString *)subtitle {
    return _subtitleLabel.text;
}

- (void)setSymbolName:(NSString *)symbolName {
    if (symbolName.length) {
        UIImage *image = [UIImage systemImageNamed:symbolName
                                     withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:kHostEmptySymbolPointSize
                                                                                                        weight:UIImageSymbolWeightRegular]];
        _symbolView.image = image;
        _symbolView.accessibilityLabel = symbolName; // 不朗读符号名，由容器合并朗读 title/subtitle。
        _symbolView.isHidden = NO;
    } else {
        _symbolView.image = nil;
        _symbolView.hidden = YES;
    }
}

- (NSString *)symbolName {
    return _symbolView.accessibilityLabel;
}

- (void)setActionTitle:(NSString *)actionTitle {
    [_actionButton setTitle:actionTitle forState:UIControlStateNormal];
    _actionButton.hidden = !actionTitle.length;
    [self _updateAccessibility];
}

- (NSString *)actionTitle {
    return [_actionButton titleForState:UIControlStateNormal];
}

- (void)setOnAction:(void (^)(void))onAction {
    _onAction = [onAction copy];
}

- (void)setAccessibilityIdentifier:(NSString *)accessibilityIdentifier {
    [super setAccessibilityIdentifier:accessibilityIdentifier];
    // 同步给子元素，便于 UI 自动化定位单个可操作按钮。
    _actionButton.accessibilityIdentifier = accessibilityIdentifier.length ? [accessibilityIdentifier stringByAppendingString:@".action"] : nil;
}

#pragma mark - Factories

+ (instancetype)emptyStateViewWithTitle:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol {
    return [self emptyStateViewWithTitle:title subtitle:subtitle symbol:symbol actionTitle:nil];
}

+ (instancetype)emptyStateViewWithTitle:(NSString *)title
                                 subtitle:(NSString *)subtitle
                                   symbol:(NSString *)symbol
                               actionTitle:(NSString *)actionTitle {
    HostEmptyStateView *view = [self new];
    view.title = title;
    view.subtitle = subtitle;
    view.symbolName = symbol;
    view.actionTitle = actionTitle;
    return view;
}

+ (UILabel *)placeholderLabelWithText:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text ?: @"";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = HostSecondaryText();
    // 作为 表 backgroundView 时，整张标签是 VoiceOver 唯一可 朗读元素：
    // 合并 文案 为 label，静态文本 traits，避免读出 “按钮”/“图像” 噪音。
    label.isAccessibilityElement = YES;
    label.accessibilityLabel = text ?: @"";
    label.accessibilityTraits = UIAccessibilityTraitStaticText;
    return label;
}

#pragma mark - Actions / theme

- (void)_actionTapped {
    if (self.onAction) self.onAction();
}

- (void)reloadThemeAppearance {
    self.overrideUserInterfaceStyle = HostSelectedInterfaceStyle();
    _symbolView.tintColor = HostSecondaryText();
    _titleLabel.textColor = HostText();
    _subtitleLabel.textColor = HostSecondaryText();
    _actionButton.backgroundColor = HostRaisedSurface();
    HostSetLayerBorderColor(_actionButton, HostBorder());
    [_actionButton setTitleColor:HostText() forState:UIControlStateNormal];
    [_actionButton setTitleColor:HostSecondaryText() forState:UIControlStateHighlighted];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self reloadThemeAppearance];
    }
    // 动态字体档位变化：adaptive font 会自动重排；这里 仍触发一次 layout
    // 以保证 约束在 大字号 下的垂直间距 正确更新。
    if (previousTraitCollection && ![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self setNeedsLayout];
    }
}

#pragma mark - Accessibility consolidation

- (void)_updateAccessibility {
    // 合并 朗读：title 与 subtitle 用逗 号连接；仅有 subtitle 时单独朗读。
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (_titleLabel.text.length) [parts addObject:_titleLabel.text];
    if (_subtitleLabel.text.length) [parts addObject:_subtitleLabel.text];
    NSString *combined = [parts componentsJoinedByString:@"，"];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = combined.length ? combined : @"空状态";
    self.accessibilityTraits = _actionButton.hidden ? UIAccessibilityTraitStaticText : UIAccessibilityTraitButton;
    self.accessibilityHint = _actionButton.hidden ? nil : (_actionButton.currentTitle ?: @"执行操作");
    // 图标与文字 不再单独 朗读：容器合并后隐藏子元素的 a11y。
    _symbolView.isAccessibilityElement = NO;
    _titleLabel.isAccessibilityElement = NO;
    _subtitleLabel.isAccessibilityElement = NO;
    _actionButton.isAccessibilityElement = NO; // 容器作为按钮整体响应。
}

@end
