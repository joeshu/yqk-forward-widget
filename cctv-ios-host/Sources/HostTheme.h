#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "HostGlassBackdropView.h"

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
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:0.018 green:0.021 blue:0.032 alpha:0.90]:[UIColor colorWithRed:0.925 green:0.938 blue:0.965 alpha:0.87];}];});return color;
}
static inline UIColor *HostCard(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:0.105 alpha:0.88]:[UIColor colorWithWhite:1 alpha:0.78];}];});return color;
}
static inline UIColor *HostRaisedSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:0.18 alpha:0.91]:[UIColor colorWithWhite:0.985 alpha:0.88];}];});return color;
}
static inline UIColor *HostText(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?UIColor.whiteColor:[UIColor colorWithWhite:0.075 alpha:1];}];});return color;
}
static inline UIColor *HostSecondaryText(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.68]:[UIColor colorWithWhite:0.27 alpha:1];}];});return color;
}
static inline UIColor *HostAccent(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:1 green:0.16 blue:0.43 alpha:1]:[UIColor colorWithRed:0.78 green:0.04 blue:0.25 alpha:1];}];});return color;
}
static inline UIColor *HostOnAccent(void) { return UIColor.whiteColor; }
static inline UIColor *HostMutedText(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.68]:[UIColor colorWithWhite:0.28 alpha:0.82];}];});return color;
}
static inline UIColor *HostGlassTint(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:0.10 alpha:0.46]:[UIColor colorWithWhite:1 alpha:0.68];}];});return color;
}
static inline UIColor *HostBorder(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.11]:[UIColor colorWithWhite:0 alpha:0.09];}];});return color;
}
static inline UIColor *HostSeparator(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.11]:[UIColor colorWithWhite:0 alpha:0.10];}];});return color;
}
static inline UIColor *HostNeutralSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.09]:[UIColor colorWithWhite:0 alpha:0.055];}];});return color;
}
static inline UIColor *HostSelectedSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.16]:[UIColor colorWithWhite:0 alpha:0.07];}];});return color;
}
static inline UIColor *HostHighlightedSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithWhite:1 alpha:0.2]:[UIColor colorWithWhite:0 alpha:0.06];}];});return color;
}
static inline UIColor *HostSuccessSurface(void) {
    static UIColor *color;static dispatch_once_t once;
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:0.07 green:0.18 blue:0.13 alpha:1]:[UIColor colorWithRed:0.88 green:0.96 blue:0.91 alpha:1];}];});return color;
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
    button.layer.cornerRadius = 18;
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
    nav.navigationBar.standardAppearance = a;
    nav.navigationBar.scrollEdgeAppearance = a;
    nav.navigationBar.compactAppearance = a;
    nav.navigationBar.translucent = YES;
    nav.navigationBar.prefersLargeTitles = YES;
    nav.navigationBar.tintColor = HostAccent();
}
