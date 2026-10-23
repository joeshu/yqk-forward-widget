#import <UIKit/UIKit.h>
static inline UIColor *HostAccent(void) { return [UIColor colorWithRed:1 green:0.16 blue:0.43 alpha:1]; }
static inline UIColor *HostCard(void) { return [UIColor colorWithWhite:0.115 alpha:1]; }
static inline void HostStyleNavigation(UINavigationController *nav) {
    UINavigationBarAppearance *a = [UINavigationBarAppearance new];
    [a configureWithOpaqueBackground];
    a.backgroundColor = UIColor.blackColor;
    a.titleTextAttributes = @{NSForegroundColorAttributeName : UIColor.whiteColor};
    a.largeTitleTextAttributes = @{NSForegroundColorAttributeName : UIColor.whiteColor};
    a.shadowColor = UIColor.clearColor;
    nav.navigationBar.standardAppearance = a;
    nav.navigationBar.scrollEdgeAppearance = a;
    nav.navigationBar.compactAppearance = a;
    nav.navigationBar.prefersLargeTitles = YES;
    nav.navigationBar.tintColor = UIColor.whiteColor;
}
