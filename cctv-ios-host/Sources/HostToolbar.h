#import <UIKit/UIKit.h>
// A single compact toolbar shared by catalog, configuration and service pages.
static inline UIBarButtonItem *HostToolbar(NSArray<NSDictionary *> *actions) {
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisHorizontal;stack.distribution=UIStackViewDistributionFillEqually;
    stack.backgroundColor=[UIColor colorWithWhite:0.13 alpha:0.96];stack.layer.cornerRadius=22;stack.clipsToBounds=YES;
    for(NSDictionary *a in actions){UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setImage:[UIImage systemImageNamed:a[@"icon"]] forState:UIControlStateNormal];b.tintColor=UIColor.whiteColor;b.accessibilityLabel=a[@"title"];b.accessibilityIdentifier=a[@"identifier"]?:a[@"title"];b.frame=CGRectMake(0,0,44,44);
        if(a[@"menu"]){b.menu=a[@"menu"];b.showsMenuAsPrimaryAction=YES;}else if(a[@"action"])[b addAction:a[@"action"] forControlEvents:UIControlEventTouchUpInside];
        [b.widthAnchor constraintEqualToConstant:44].active=YES;[b.heightAnchor constraintEqualToConstant:44].active=YES;[stack addArrangedSubview:b];}
    stack.frame=CGRectMake(0,0,44*actions.count,44);return [[UIBarButtonItem alloc] initWithCustomView:stack];
}
