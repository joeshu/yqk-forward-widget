#import "HostTabBarController.h"
#import "HostTheme.h"
@implementation HostTabBarController
- (void)loadView {
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisHorizontal;stack.distribution=UIStackViewDistributionFillEqually;stack.spacing=3;stack.backgroundColor=UIColor.clearColor;stack.layer.cornerRadius=27;stack.layer.cornerCurve=kCACornerCurveContinuous;stack.clipsToBounds=YES;self.view=stack;
}
- (UIStackView *)stackView {return (UIStackView *)self.view;}
- (void)addTabButton:(UIButton *)button {[button addTarget:self action:@selector(selectTab:) forControlEvents:UIControlEventTouchUpInside];[self.stackView addArrangedSubview:button];}
- (void)selectTab:(UIButton *)button {if(self.onSelect)self.onSelect(button);}
- (void)reloadThemeAppearance {self.overrideUserInterfaceStyle=HostSelectedInterfaceStyle();self.view.tintColor=HostAccent();}
@end
