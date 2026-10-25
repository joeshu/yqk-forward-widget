#import "HostGlassBackdropView.h"
#import "HostTheme.h"

@interface HostGlassBackdropView ()
@property(nonatomic,strong) CAGradientLayer *baseGradient;
@property(nonatomic,strong) CAGradientLayer *roseGradient;
@property(nonatomic,strong) CAGradientLayer *blueGradient;
@end

@implementation HostGlassBackdropView

- (instancetype)initWithFrame:(CGRect)frame {
    self=[super initWithFrame:frame];
    if(self){
        self.userInteractionEnabled=NO;
        self.opaque=NO;
        self.baseGradient=[CAGradientLayer layer];
        self.baseGradient.startPoint=CGPointMake(0,0);
        self.baseGradient.endPoint=CGPointMake(1,1);
        [self.layer addSublayer:self.baseGradient];
        self.roseGradient=[CAGradientLayer layer];
        self.roseGradient.type=kCAGradientLayerRadial;
        self.roseGradient.startPoint=CGPointMake(.88,.08);
        self.roseGradient.endPoint=CGPointMake(.48,.48);
        self.roseGradient.locations=@[@0,@1];
        [self.layer addSublayer:self.roseGradient];
        self.blueGradient=[CAGradientLayer layer];
        self.blueGradient.type=kCAGradientLayerRadial;
        self.blueGradient.startPoint=CGPointMake(.08,.78);
        self.blueGradient.endPoint=CGPointMake(.58,.38);
        self.blueGradient.locations=@[@0,@1];
        [self.layer addSublayer:self.blueGradient];
        [self refreshAppearance];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds=self.bounds;
    self.baseGradient.frame=bounds;
    self.roseGradient.frame=bounds;
    self.blueGradient.frame=bounds;
}

- (void)refreshAppearance {
    UITraitCollection *traits=self.traitCollection;
    UIColor *(^resolved)(UIColor *)=^UIColor *(UIColor *value){return [value resolvedColorWithTraitCollection:traits];};
    self.baseGradient.colors=@[(id)resolved(HostBackground()).CGColor,(id)resolved(HostRaisedSurface()).CGColor];
    UIColor *roseTint=traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:1 green:.16 blue:.43 alpha:.13]:[UIColor colorWithRed:.93 green:.24 blue:.48 alpha:.16];
    UIColor *blueTint=traits.userInterfaceStyle==UIUserInterfaceStyleDark?[UIColor colorWithRed:.20 green:.43 blue:.92 alpha:.10]:[UIColor colorWithRed:.20 green:.50 blue:.96 alpha:.13];
    self.roseGradient.colors=@[(id)resolved(roseTint).CGColor,(id)UIColor.clearColor.CGColor];
    self.blueGradient.colors=@[(id)resolved(blueTint).CGColor,(id)UIColor.clearColor.CGColor];
    [self setNeedsLayout];
}

@end
