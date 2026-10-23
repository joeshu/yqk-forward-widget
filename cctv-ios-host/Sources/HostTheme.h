#import <UIKit/UIKit.h>
static inline UIColor *HostAccent(void) { return [UIColor colorWithRed:1 green:0.16 blue:0.43 alpha:1]; }
static inline UIColor *HostCard(void) { return [UIColor colorWithWhite:0.115 alpha:1]; }
static inline UIColor *HostGlassTint(void) { return [UIColor colorWithWhite:0.12 alpha:0.38]; }
static inline UIColor *HostMutedText(void) { return [UIColor colorWithWhite:1 alpha:0.68]; }
static inline UIBlurEffect *HostGlassBlur(void) { return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]; }
static inline void HostStylePillButton(UIButton *button, BOOL primary) {
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 16, 10, 16);
    button.layer.cornerRadius = 18;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = primary ? 0 : 0.7;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    button.backgroundColor = primary ? HostAccent() : [UIColor colorWithWhite:1 alpha:0.09];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1 alpha:0.65] forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.accessibilityTraits |= UIAccessibilityTraitButton;
}
static inline void HostStyleNavigation(UINavigationController *nav) {
    if (!nav) return;
    UINavigationBarAppearance *a = [UINavigationBarAppearance new];
    [a configureWithDefaultBackground];
    a.backgroundEffect = HostGlassBlur();
    a.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.72];
    a.titleTextAttributes = @{NSForegroundColorAttributeName : UIColor.whiteColor,
                              NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
    a.largeTitleTextAttributes = @{NSForegroundColorAttributeName : UIColor.whiteColor,
                                   NSFontAttributeName : [UIFont systemFontOfSize:32 weight:UIFontWeightBold]};
    a.shadowColor = UIColor.clearColor;
    nav.navigationBar.standardAppearance = a;
    nav.navigationBar.scrollEdgeAppearance = a;
    nav.navigationBar.compactAppearance = a;
    nav.navigationBar.isTranslucent = YES;
    nav.navigationBar.prefersLargeTitles = YES;
    nav.navigationBar.tintColor = HostAccent();
}
