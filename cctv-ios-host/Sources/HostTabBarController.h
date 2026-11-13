#import <UIKit/UIKit.h>
@interface HostTabBarController : UIViewController
@property(nonatomic,strong,readonly) UIStackView *stackView;
@property(nonatomic,copy) void (^onSelect)(UIButton *button);
- (void)addTabButton:(UIButton *)button;
- (void)reloadThemeAppearance;
@end
