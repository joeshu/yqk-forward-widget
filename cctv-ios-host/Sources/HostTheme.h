#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "HostGlassBackdropView.h"
#import "HostThemePalette.h"

static NSString * const HostDarkThemePreferenceKey = @"hostDarkTheme";
static NSString * const HostThemeModePreferenceKey = @"hostThemeMode";
extern char HostLayerBorderColorAssociationKey;
extern char HostAppearanceRefreshAssociationKey;
extern char HostGlassEffectAssociationKey;
extern char HostPressFeedbackAssociationKey;
extern char HostSpecularRimAssociationKey;

static inline NSString *HostThemeMode(void) {
    NSString *mode=[NSUserDefaults.standardUserDefaults stringForKey:HostThemeModePreferenceKey];
    if([@[@"system",@"light",@"dark"] containsObject:mode?:@""])return mode;
    if([NSUserDefaults.standardUserDefaults objectForKey:HostDarkThemePreferenceKey])
        return [NSUserDefaults.standardUserDefaults boolForKey:HostDarkThemePreferenceKey]?@"dark":@"light";
    return @"dark"; // Preserve the app's established first-launch appearance.
}

static inline UIUserInterfaceStyle HostSystemInterfaceStyle(void) {
    UIApplication *application=UIApplication.sharedApplication;
    for(UIScene *scene in application.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class])continue;
        UIWindowScene *windowScene=(UIWindowScene *)scene;
        if(windowScene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *window in windowScene.windows)if(window.isKeyWindow)return window.traitCollection.userInterfaceStyle;
        if(windowScene.windows.firstObject)return windowScene.windows.firstObject.traitCollection.userInterfaceStyle;
    }
    return UITraitCollection.currentTraitCollection.userInterfaceStyle;
}

static inline BOOL HostIsDarkThemeSelected(void) {
    NSString *mode=HostThemeMode();
    if([mode isEqual:@"system"])return HostSystemInterfaceStyle()==UIUserInterfaceStyleDark;
    return [mode isEqual:@"dark"];
}

static inline UIUserInterfaceStyle HostSelectedInterfaceStyle(void) {
    NSString *mode=HostThemeMode();
    if([mode isEqual:@"system"])return UIUserInterfaceStyleUnspecified;
    return [mode isEqual:@"dark"] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
}

static inline UIColor *HostBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].background;}];
}
static inline UIColor *HostCard(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].card;}];
}
static inline UIColor *HostRaisedSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].raisedSurface;}];
}
static inline UIColor *HostText(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].text;}];
}
static inline UIColor *HostSecondaryText(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].secondaryText;}];
}
static inline UIColor *HostAccent(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].accent;}];
}
static inline UIColor *HostOnAccent(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].onAccent;}];
}
static inline UIColor *HostMutedText(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].mutedText;}];
}
static inline UIColor *HostGlassTint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].glassTint;}];
}
static inline UIColor *HostBorder(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].border;}];
}
static inline UIColor *HostSeparator(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].separator;}];
}
static inline UIColor *HostNeutralSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].neutralSurface;}];
}
static inline UIColor *HostSelectedSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].selectedSurface;}];
}
static inline UIColor *HostHighlightedSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].highlightedSurface;}];
}
static inline UIColor *HostSuccessSurface(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].successSurface;}];
}
static inline UIBlurEffect *HostGlassBlur(void) { return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]; }
static inline void HostSetLayerBorderColor(UIView *view, UIColor *color);

static inline void HostInstallGlassBackdrop(UIView *target) {
    if(!target||objc_getAssociatedObject(target,&HostAppearanceRefreshAssociationKey))return;
    HostGlassBackdropView *backdrop=[HostGlassBackdropView new];
    backdrop.frame=target.bounds;
    backdrop.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    backdrop.userInteractionEnabled=NO;
    backdrop.backgroundColor=HostBackground();
    if([target isKindOfClass:UITableView.class])((UITableView *)target).backgroundView=backdrop;
    else [target insertSubview:backdrop atIndex:0];
    [backdrop refreshAppearance];
    objc_setAssociatedObject(target,&HostAppearanceRefreshAssociationKey,backdrop,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static inline void HostStyleGlassCard(UIView *view, CGFloat radius) {
    if(!view)return;
    UIVisualEffectView *glass=objc_getAssociatedObject(view,&HostGlassEffectAssociationKey);
    if(!glass){
        glass=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];
        glass.frame=view.bounds;
        glass.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled=NO;
        glass.clipsToBounds=YES;
        UIView *tint=[[UIView alloc] initWithFrame:glass.contentView.bounds];
        tint.backgroundColor=HostGlassTint();
        tint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        tint.userInteractionEnabled=NO;
        [glass.contentView addSubview:tint];
        [view insertSubview:glass atIndex:0];
        objc_setAssociatedObject(view,&HostGlassEffectAssociationKey,glass,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [view sendSubviewToBack:glass];
    if([view isKindOfClass:UIButton.class]){
        UIButton *btn=(UIButton *)view;
        if(btn.imageView)[btn bringSubviewToFront:btn.imageView];
        if(btn.titleLabel)[btn bringSubviewToFront:btn.titleLabel];
    }
    glass.layer.cornerRadius=radius;
    glass.layer.cornerCurve=kCACornerCurveContinuous;
    CAGradientLayer *specularRim=objc_getAssociatedObject(view,&HostSpecularRimAssociationKey);
    if(!specularRim){
        specularRim=[CAGradientLayer layer];
        specularRim.startPoint=CGPointMake(0,0);
        specularRim.endPoint=CGPointMake(1,1);
        specularRim.colors=@[(id)[UIColor colorWithWhite:1 alpha:0.22].CGColor,(id)[UIColor colorWithWhite:1 alpha:0.05].CGColor,(id)[UIColor colorWithWhite:1 alpha:0.12].CGColor];
        specularRim.locations=@[@0.0,@0.52,@1.0];
        [glass.contentView.layer addSublayer:specularRim];
        objc_setAssociatedObject(view,&HostSpecularRimAssociationKey,specularRim,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    specularRim.frame=CGRectMake(0,0,CGRectGetWidth(view.bounds),MIN(1.2,CGRectGetHeight(view.bounds)));
    view.backgroundColor=UIColor.clearColor;
    view.layer.cornerRadius=radius;
    view.layer.cornerCurve=kCACornerCurveContinuous;
    view.layer.borderWidth=.85;
    HostSetLayerBorderColor(view,HostBorder());
    view.clipsToBounds=YES;
}

static inline void HostStyleSurfaceCard(UIView *view, CGFloat radius) {
    if(!view)return;
    view.backgroundColor=HostCard();
    view.layer.cornerRadius=radius;
    view.layer.cornerCurve=kCACornerCurveContinuous;
    view.layer.borderWidth=.75;
    HostSetLayerBorderColor(view,HostBorder());
    view.clipsToBounds=YES;
}

static inline void HostInstallPressFeedback(UIButton *button) {
    if(!button||objc_getAssociatedObject(button,&HostPressFeedbackAssociationKey))return;
    __weak UIButton *weakButton=button;
    UIAction *press=[UIAction actionWithHandler:^(UIAction *action){
        UIButton *target=weakButton;
        if(!target||UIAccessibilityIsReduceMotionEnabled())return;
        [UIView animateWithDuration:.10 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{target.transform=CGAffineTransformMakeScale(.97,.97);} completion:nil];
    }];
    UIAction *releaseAction=[UIAction actionWithHandler:^(UIAction *action){
        UIButton *target=weakButton;
        if(!target||UIAccessibilityIsReduceMotionEnabled())return;
        [UIView animateWithDuration:.22 delay:0 usingSpringWithDamping:.78 initialSpringVelocity:.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{target.transform=CGAffineTransformIdentity;} completion:nil];
    }];
    [button addAction:press forControlEvents:UIControlEventTouchDown|UIControlEventTouchDragEnter];
    [button addAction:releaseAction forControlEvents:UIControlEventTouchDragExit|UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    objc_setAssociatedObject(button,&HostPressFeedbackAssociationKey,@[press,releaseAction],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static inline void HostAnimateSelection(UIView *view) {
    if(!view||UIAccessibilityIsReduceMotionEnabled())return;
    view.transform=CGAffineTransformMakeScale(.96,.96);
    [UIView animateWithDuration:.34 delay:0 usingSpringWithDamping:.58 initialSpringVelocity:.25 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{view.transform=CGAffineTransformIdentity;} completion:nil];
}

static inline void HostSetLayerBorderColor(UIView *view, UIColor *color) {
    if(!view||!color)return;
    objc_setAssociatedObject(view,&HostLayerBorderColorAssociationKey,color,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.layer.borderColor=[[color resolvedColorWithTraitCollection:view.traitCollection] CGColor];
}
static inline void HostRefreshAppearanceLayers(UIView *view) {
    if(!view)return;
    HostGlassBackdropView *backdrop=objc_getAssociatedObject(view,&HostAppearanceRefreshAssociationKey);if(backdrop)[backdrop refreshAppearance];
    CAGradientLayer *specularRim=objc_getAssociatedObject(view,&HostSpecularRimAssociationKey);
    if(specularRim)specularRim.frame=CGRectMake(0,0,CGRectGetWidth(view.bounds),MIN(1.2,CGRectGetHeight(view.bounds)));
    UIColor *border=objc_getAssociatedObject(view,&HostLayerBorderColorAssociationKey);
    if(border)view.layer.borderColor=[[HostBorder() resolvedColorWithTraitCollection:view.traitCollection] CGColor];
    for(UIView *child in view.subviews)HostRefreshAppearanceLayers(child);
}

static inline UIFont *HostRoundedFont(CGFloat size, UIFontWeight weight, UIFontTextStyle textStyle) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *roundedDesc = [base.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    UIFont *rounded = roundedDesc ? [UIFont fontWithDescriptor:roundedDesc size:size] : base;
    return textStyle ? [[UIFontMetrics metricsForTextStyle:textStyle] scaledFontForFont:rounded] : rounded;
}

static inline UIFont *HostMonospacedDigitFont(CGFloat size, UIFontWeight weight, UIFontTextStyle textStyle) {
    UIFont *mono = [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
    return textStyle ? [[UIFontMetrics metricsForTextStyle:textStyle] scaledFontForFont:mono] : mono;
}

static inline void HostStyleSectionHeaderView(UIView *view) {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = HostRoundedFont(13.0, UIFontWeightSemibold, UIFontTextStyleSubheadline);
    header.textLabel.textColor = HostSecondaryText();
    header.textLabel.adjustsFontForContentSizeCategory = YES;
}

static inline void HostStyleSectionFooterView(UIView *view) {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
    footer.textLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledFontForFont:[UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular]];
    footer.textLabel.textColor = HostMutedText();
    footer.textLabel.adjustsFontForContentSizeCategory = YES;
}

static inline void HostStylePillButton(UIButton *button, BOOL primary) {
    HostInstallPressFeedback(button);
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 16, 10, 16);
    button.layer.cornerRadius = 15;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = primary ? 0.5 : 0.75;
    HostSetLayerBorderColor(button,primary?[HostOnAccent() colorWithAlphaComponent:0.24]:HostBorder());
    button.backgroundColor = primary ? HostAccent() : HostNeutralSurface();
    [button setTitleColor:primary?HostOnAccent():HostText() forState:UIControlStateNormal];
    [button setTitleColor:HostSecondaryText() forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.titleLabel.layer.shadowColor = primary ? [UIColor colorWithWhite:0 alpha:0.35].CGColor : UIColor.clearColor.CGColor;
    button.titleLabel.layer.shadowOffset = CGSizeMake(0, 0.5);
    button.titleLabel.layer.shadowRadius = primary ? 1.5 : 0;
    button.titleLabel.layer.shadowOpacity = primary ? 1.0 : 0;
    button.accessibilityTraits |= UIAccessibilityTraitButton;
}
static inline void HostStyleNavigation(UINavigationController *nav) {
    if (!nav) return;
    UINavigationBarAppearance *a = [UINavigationBarAppearance new];
    [a configureWithDefaultBackground];
    a.backgroundEffect = HostGlassBlur();
    a.backgroundColor = HostGlassTint();
    a.titleTextAttributes = @{NSForegroundColorAttributeName : HostText(),
                              NSFontAttributeName : HostRoundedFont(17, UIFontWeightSemibold, nil),
                              NSKernAttributeName : @(-0.15)};
    a.largeTitleTextAttributes = @{NSForegroundColorAttributeName : HostText(),
                                   NSFontAttributeName : HostRoundedFont(32, UIFontWeightBold, nil),
                                   NSKernAttributeName : @(-0.35)};
    a.shadowColor = UIColor.clearColor;
    UINavigationBarAppearance *edge = [UINavigationBarAppearance new];
    [edge configureWithTransparentBackground];
    edge.backgroundColor = UIColor.clearColor;
    edge.titleTextAttributes = a.titleTextAttributes;
    edge.largeTitleTextAttributes = a.largeTitleTextAttributes;
    edge.shadowColor = UIColor.clearColor;
    nav.navigationBar.standardAppearance = a;
    nav.navigationBar.scrollEdgeAppearance = edge;
    nav.navigationBar.compactAppearance = a;
    if (@available(iOS 15.0, *)) nav.navigationBar.compactScrollEdgeAppearance = edge;
    nav.navigationBar.translucent = YES;
    nav.navigationBar.prefersLargeTitles = YES;
    nav.navigationBar.tintColor = HostAccent();
}

// 把当前主题与模式应用到窗口。按 HostSelectedInterfaceStyle() 设定
// overrideUserInterfaceStyle；同深浅换主题时（深色→深色），动态颜色本身不会
// 重新解析，因此先把 override 切到相反深浅并用 layoutIfNeeded 冲掉中间态，
// 再切回目标深浅——两次切换在同一 runloop 内完成，不产生可见闪烁。
// 调用方随后仍需重刷导航栏与图层边框（HostStyleNavigation /
// HostRefreshAppearanceLayers），并重载可见的列表（cellForRow 会重新取色）。
static inline void HostApplyThemeToWindow(UIWindow *window) {
    UIUserInterfaceStyle target=HostSelectedInterfaceStyle();
    NSMutableArray<UIWindow *> *windows=[NSMutableArray array];
    if(window)[windows addObject:window];
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if([scene isKindOfClass:UIWindowScene.class]){
            for(UIWindow *w in ((UIWindowScene *)scene).windows){
                if(![windows containsObject:w])[windows addObject:w];
            }
        }
    }
    for(UIWindow *w in windows){
        UIUserInterfaceStyle opposite=(target==UIUserInterfaceStyleDark)?UIUserInterfaceStyleLight:UIUserInterfaceStyleDark;
        [CATransaction begin];[CATransaction setDisableActions:YES];
        w.overrideUserInterfaceStyle=opposite;
        [w layoutIfNeeded];
        w.overrideUserInterfaceStyle=target;
        [CATransaction commit];
        [w layoutIfNeeded];
        HostRefreshAppearanceLayers(w);
    }
}

// 锁定物理状态栏/灵动岛顶部安全区高度（恒定值），避免在 push/pop 二级页面切换
// UINavigationBar 显隐时因 view.safeAreaInsets.top 叠加 44pt/96pt 引发顶栏跳动。
static inline CGFloat HostStatusBarSafeTop(UIView *view, CGFloat fallbackSafeTop) {
    CGFloat safeTop = isfinite(fallbackSafeTop) ? MAX(0.0, fallbackSafeTop) : 0.0;
    UIWindow *window = view ? view.window : nil;
    if (window) {
        CGFloat winTop = window.safeAreaInsets.top;
        if (isfinite(winTop) && winTop > 0.0) return winTop;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && w.safeAreaInsets.top > 0.0) return w.safeAreaInsets.top;
        }
        for (UIWindow *w in ws.windows) {
            if (w.safeAreaInsets.top > 0.0) return w.safeAreaInsets.top;
        }
        if (ws.statusBarManager.statusBarFrame.size.height > 0.0) {
            return ws.statusBarManager.statusBarFrame.size.height;
        }
    }
    return safeTop;
}

// 2026 Spatial Glass 统一顶部渐进式沉浸遮罩：五个一级导航页与影视详情页共用，
// 保证顶部状态栏与悬浮胶囊在海报/列表滚动时始终清晰可读且无生硬分割线。
static inline void HostUpdateImmersiveTopScrim(UIView *scrimView, CAGradientLayer *gradientLayer, CGRect frame, CGFloat scrollProgress, BOOL hasHeroBackdrop) {
    if (!scrimView || !gradientLayer) return;
    scrimView.frame = frame;
    gradientLayer.frame = scrimView.bounds;
    CGFloat clamped = MIN(1.0, MAX(0.0, scrollProgress));
    CGFloat topAlpha = hasHeroBackdrop ? (clamped * 0.52) : (clamped * 0.76);
    CGFloat midAlpha = topAlpha * 0.65;
    UIColor *base = [HostBackground() resolvedColorWithTraitCollection:scrimView.traitCollection];
    gradientLayer.locations = @[@0.0, @0.68, @1.0];
    gradientLayer.colors = @[
        (id)[base colorWithAlphaComponent:topAlpha].CGColor,
        (id)[base colorWithAlphaComponent:midAlpha].CGColor,
        (id)[base colorWithAlphaComponent:0.0].CGColor
    ];
}
