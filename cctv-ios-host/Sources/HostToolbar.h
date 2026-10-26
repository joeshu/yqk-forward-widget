#import <UIKit/UIKit.h>
#import "HostTheme.h"
// A single compact toolbar shared by catalog, configuration and service pages.
static inline UIBarButtonItem *HostToolbar(NSArray<NSDictionary *> *actions) {
    if (!actions.count) return nil;
    CGFloat stackWidth = actions.count * 44 + MAX(0, (actions.count - 1) * 4);
    CGFloat width = stackWidth + 8;
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisHorizontal;stack.distribution=UIStackViewDistributionFillEqually;stack.spacing=4;stack.layoutMarginsRelativeArrangement=YES;stack.layoutMargins=UIEdgeInsetsMake(2,4,2,4);stack.frame=CGRectMake(0,0,width,48);stack.backgroundColor=UIColor.clearColor;stack.layer.cornerRadius=24;stack.layer.cornerCurve=kCACornerCurveContinuous;stack.clipsToBounds=YES;
    UIVisualEffectView *glass=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];glass.frame=stack.bounds;glass.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    UIView *tint=[[UIView alloc] initWithFrame:glass.contentView.bounds];tint.backgroundColor=HostGlassTint();tint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[glass.contentView addSubview:tint];
    [stack insertSubview:glass atIndex:0];
    for(NSDictionary *a in actions){
        UIView *custom=a[@"customView"];
        if([custom isKindOfClass:UIView.class]){
            custom.translatesAutoresizingMaskIntoConstraints=NO;
            custom.accessibilityLabel=a[@"title"];
            custom.accessibilityIdentifier=a[@"identifier"]?:a[@"title"];
            [custom.widthAnchor constraintEqualToConstant:44].active=YES;
            [custom.heightAnchor constraintEqualToConstant:44].active=YES;
            [stack addArrangedSubview:custom];
            continue;
        }
        UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];HostInstallPressFeedback(b);[b setImage:[UIImage systemImageNamed:a[@"icon"]] forState:UIControlStateNormal];b.tintColor=HostText();b.accessibilityLabel=a[@"title"];b.accessibilityIdentifier=a[@"identifier"]?:a[@"title"];b.frame=CGRectMake(0,0,44,44);b.layer.cornerRadius=16;b.layer.cornerCurve=kCACornerCurveContinuous;b.imageView.contentMode=UIViewContentModeScaleAspectFit;
        if(a[@"menu"]){b.menu=a[@"menu"];b.showsMenuAsPrimaryAction=YES;}else if(a[@"action"])[b addAction:a[@"action"] forControlEvents:UIControlEventTouchUpInside];
        [b.widthAnchor constraintEqualToConstant:44].active=YES;[b.heightAnchor constraintEqualToConstant:44].active=YES;[stack addArrangedSubview:b];
    }
    stack.layer.borderWidth=0.7;HostSetLayerBorderColor(stack,HostBorder());
    [stack sendSubviewToBack:glass];
    return [[UIBarButtonItem alloc] initWithCustomView:stack];
}
