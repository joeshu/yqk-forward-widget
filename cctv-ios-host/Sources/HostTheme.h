#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const HostDarkThemePreferenceKey = @"hostDarkTheme";
static NSString * const HostThemeModePreferenceKey = @"hostThemeMode";
static char HostLayerBorderColorAssociationKey;
static char HostAppearanceRefreshAssociationKey;

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
    dispatch_once(&once,^{color=[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits){return traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:0.018 green:0.021 blue:0.032 alpha:0.94]:[UIColor colorWithRed:0.925 green:0.938 blue:0.965 alpha:0.92];}];});return color;
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

static inline void HostPinGradientLayer(CAGradientLayer *layer) {
    NSArray<CAConstraint *> *constraints=@[
        [CAConstraint constraintWithAttribute:kCAConstraintMinX relativeTo:@"superlayer" attribute:kCAConstraintMinX offset:0],
        [CAConstraint constraintWithAttribute:kCAConstraintMaxX relativeTo:@"superlayer" attribute:kCAConstraintMaxX offset:0],
        [CAConstraint constraintWithAttribute:kCAConstraintMinY relativeTo:@"superlayer" attribute:kCAConstraintMinY offset:0],
        [CAConstraint constraintWithAttribute:kCAConstraintMaxY relativeTo:@"superlayer" attribute:kCAConstraintMaxY offset:0]
    ];
    [layer setConstraints:constraints];
}

static inline void HostInstallGlassBackdrop(UIView *target) {
    if(!target||objc_getAssociatedObject(target,&HostAppearanceRefreshAssociationKey))return;
    UIView *backdrop=[UIView new];
    backdrop.frame=target.bounds;
    backdrop.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    backdrop.userInteractionEnabled=NO;
    backdrop.backgroundColor=HostBackground();
    backdrop.layer.layoutManager=[CAConstraintLayoutManager layoutManager];
    CAGradientLayer *base=[CAGradientLayer layer];
    base.frame=backdrop.bounds;
    base.startPoint=CGPointMake(0,0);base.endPoint=CGPointMake(1,1);
    HostPinGradientLayer(base);
    [backdrop.layer addSublayer:base];
    CAGradientLayer *rose=[CAGradientLayer layer];
    rose.type=kCAGradientLayerRadial;rose.frame=backdrop.bounds;
    rose.startPoint=CGPointMake(.88,.08);rose.endPoint=CGPointMake(.48,.48);
    rose.locations=@[@0,@1];HostPinGradientLayer(rose);[backdrop.layer addSublayer:rose];
    CAGradientLayer *blue=[CAGradientLayer layer];
    blue.type=kCAGradientLayerRadial;blue.frame=backdrop.bounds;
    blue.startPoint=CGPointMake(.08,.78);blue.endPoint=CGPointMake(.58,.38);
    blue.locations=@[@0,@1];HostPinGradientLayer(blue);[backdrop.layer addSublayer:blue];
    if([target isKindOfClass:UITableView.class])((UITableView *)target).backgroundView=backdrop;
    else [target insertSubview:backdrop atIndex:0];
    __weak UIView *weakBackdrop=backdrop;
    __weak CAGradientLayer *weakBase=base,*weakRose=rose,*weakBlue=blue;
    void(^refresh)(void)=^{
        UIView *view=weakBackdrop;if(!view)return;UITraitCollection *traits=view.traitCollection;
        UIColor *(^resolved)(UIColor *)=^UIColor *(UIColor *value){return [value resolvedColorWithTraitCollection:traits];};
        weakBase.colors=@[(id)resolved(HostBackground()).CGColor,(id)resolved(HostRaisedSurface()).CGColor];
        UIColor *roseTint=traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:1 green:.16 blue:.43 alpha:.13]:[UIColor colorWithRed:.93 green:.24 blue:.48 alpha:.16];
        UIColor *blueTint=traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:.20 green:.43 blue:.92 alpha:.10]:[UIColor colorWithRed:.20 green:.50 blue:.96 alpha:.13];
        weakRose.colors=@[(id)resolved(roseTint).CGColor,(id)UIColor.clearColor.CGColor];
        weakBlue.colors=@[(id)resolved(blueTint).CGColor,(id)UIColor.clearColor.CGColor];
    };
    objc_setAssociatedObject(target,&HostAppearanceRefreshAssociationKey,[refresh copy],OBJC_ASSOCIATION_COPY_NONATOMIC);
    refresh();
}

static inline void HostStyleGlassCard(UIView *view, CGFloat radius) {
    if(!view)return;
    view.backgroundColor=HostCard();
    view.layer.cornerRadius=radius;
    view.layer.cornerCurve=kCACornerCurveContinuous;
    view.layer.borderWidth=.7;
    HostSetLayerBorderColor(view,HostBorder());
    view.clipsToBounds=YES;
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
    void(^refresh)(void)=objc_getAssociatedObject(view,&HostAppearanceRefreshAssociationKey);if(refresh)refresh();
    UIColor *border=objc_getAssociatedObject(view,&HostLayerBorderColorAssociationKey);
    if(border)view.layer.borderColor=[[border resolvedColorWithTraitCollection:view.traitCollection] CGColor];
    for(UIView *child in view.subviews)HostRefreshAppearanceLayers(child);
}

static inline void HostStylePillButton(UIButton *button, BOOL primary) {
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
