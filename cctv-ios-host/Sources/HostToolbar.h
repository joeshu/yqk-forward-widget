#import <UIKit/UIKit.h>
#import "HostTheme.h"
// A single compact toolbar shared by catalog, configuration and service pages.
static inline UIBarButtonItem *HostToolbar(NSArray<NSDictionary *> *actions) {
    if (!actions.count) return nil;
    CGFloat width = actions.count * 48 + 8;
    UIView *container=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,48)];
    container.backgroundColor=UIColor.clearColor;container.layer.cornerRadius=24;container.layer.cornerCurve=kCACornerCurveContinuous;container.clipsToBounds=YES;
    UIVisualEffectView *glass=[[UIVisualEffectView alloc] initWithEffect:HostGlassBlur()];glass.frame=container.bounds;glass.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    UIView *tint=[[UIView alloc] initWithFrame:glass.contentView.bounds];tint.backgroundColor=HostGlassTint();tint.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[glass.contentView addSubview:tint];
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisHorizontal;stack.distribution=UIStackViewDistributionFillEqually;stack.spacing=4;stack.frame=CGRectMake(4,2,width-8,44);stack.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [glass.contentView addSubview:stack];[container addSubview:glass];
    for(NSDictionary *a in actions){UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setImage:[UIImage systemImageNamed:a[@"icon"]] forState:UIControlStateNormal];b.tintColor=UIColor.whiteColor;b.accessibilityLabel=a[@"title"];b.accessibilityIdentifier=a[@"identifier"]?:a[@"title"];b.frame=CGRectMake(0,0,44,44);b.layer.cornerRadius=16;b.layer.cornerCurve=kCACornerCurveContinuous;b.imageView.contentMode=UIViewContentModeScaleAspectFit;
        if(a[@"menu"]){b.menu=a[@"menu"];b.showsMenuAsPrimaryAction=YES;}else if(a[@"action"])[b addAction:a[@"action"] forControlEvents:UIControlEventTouchUpInside];
        [b.widthAnchor constraintEqualToConstant:44].active=YES;[b.heightAnchor constraintEqualToConstant:44].active=YES;[stack addArrangedSubview:b];}
    container.layer.borderWidth=0.7;container.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.10].CGColor;
    return [[UIBarButtonItem alloc] initWithCustomView:container];
}
