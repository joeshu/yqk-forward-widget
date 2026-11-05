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
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].background;}];});return color;
}
static inline UIColor *HostCard(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].card;}];});return color;
}
static inline UIColor *HostRaisedSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].raisedSurface;}];});return color;
}
static inline UIColor *HostText(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].text;}];});return color;
}
static inline UIColor *HostSecondaryText(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].secondaryText;}];});return color;
}
static inline UIColor *HostAccent(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].accent;}];});return color;
}
static inline UIColor *HostOnAccent(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].onAccent;}];});return color;
}
static inline UIColor *HostMutedText(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].mutedText;}];});return color;
}
static inline UIColor *HostGlassTint(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].glassTint;}];});return color;
}
static inline UIColor *HostBorder(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].border;}];});return color;
}
static inline UIColor *HostSeparator(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].separator;}];});return color;
}
static inline UIColor *HostNeutralSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].neutralSurface;}];});return color;
}
static inline UIColor *HostSelectedSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].selectedSurface;}];});return color;
}
static inline UIColor *HostHighlightedSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].highlightedSurface;}];});return color;
}
static inline UIColor *HostSuccessSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return [HostThemePalette effectivePaletteForDark:traits.userInterfaceStyle==UIUserInterfaceStyleDark].successSurface;}];});return color;
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
    glass.layer.cornerRadius=radius;
    view.backgroundColor=UIColor.clearColor;
    view.layer.cornerRadius=radius;
    view.layer.cornerCurve=kCACornerCurveContinuous;
    view.layer.borderWidth=.7;
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
    UIColor *border=objc_getAssociatedObject(view,&HostLayerBorderColorAssociationKey);
    if(border)view.layer.borderColor=[[border resolvedColorWithTraitCollection:view.traitCollection] CGColor];
    for(UIView *child in view.subviews)HostRefreshAppearanceLayers(child);
}

static inline void HostStylePillButton(UIButton *button, BOOL primary) {
    HostInstallPressFeedback(button);
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 16, 10, 16);
    button.layer.cornerRadius = 15;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = primary ? 0 : 0.7;
    HostSetLayerBorderColor(button,HostBorder());
    button.backgroundColor = primary ? HostAccent() : HostNeutralSurface();
    [button setTitleColor:primary?HostOnAccent():HostText() forState:UIControlStateNormal];
    [button setTitleColor:HostSecondaryText() forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.accessibilityTraits |= UIAccessibilityTraitButton;
}
static inline void HostStyleNavigation(UINavigationController *nav) {
    if (!nav) return;
    UINavigationBarAppearance *a = [UINavigationBarAppearance new];
    [a configureWithDefaultBackground];
    a.backgroundEffect = HostGlassBlur();
    a.backgroundColor = HostGlassTint();
    a.titleTextAttributes = @{NSForegroundColorAttributeName : HostText(),
                              NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    a.largeTitleTextAttributes = @{NSForegroundColorAttributeName : HostText(),
                                   NSFontAttributeName : [UIFont systemFontOfSize:32 weight:UIFontWeightBold]};
    a.shadowColor = UIColor.clearColor;
    UINavigationBarAppearance *edge = [UINavigationBarAppearance new];
    [edge configureWithTransparentBackground];
    edge.backgroundColor = [HostBackground() colorWithAlphaComponent:0.16];
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
    if(!window)return;
    UIUserInterfaceStyle target=HostSelectedInterfaceStyle();
    if(window.overrideUserInterfaceStyle==target&&target!=UIUserInterfaceStyleUnspecified){
        [CATransaction begin];[CATransaction setDisableActions:YES];
        window.overrideUserInterfaceStyle=(target==UIUserInterfaceStyleDark)?UIUserInterfaceStyleLight:UIUserInterfaceStyleDark;
        [window layoutIfNeeded];
        window.overrideUserInterfaceStyle=target;
        [CATransaction commit];
    }else{
        window.overrideUserInterfaceStyle=target;
    }
    [window layoutIfNeeded];
}
