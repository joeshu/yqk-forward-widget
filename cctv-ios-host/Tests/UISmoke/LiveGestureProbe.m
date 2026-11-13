#import <math.h>
#import <UIKit/UIKit.h>
#import "RootViewController.h"
@interface RootViewController (GestureProbe)
- (void)onPan:(UIPanGestureRecognizer *)gesture;
- (UISlider *)systemVolumeSlider;
@end
@interface FixturePan : UIPanGestureRecognizer
@property(nonatomic) CGPoint displacement;
@end
@implementation FixturePan
- (UIGestureRecognizerState)state {return UIGestureRecognizerStateChanged;}
- (CGPoint)locationInView:(UIView *)view {return CGPointMake(100,0);}
- (CGPoint)velocityInView:(UIView *)view {return CGPointZero;}
- (CGPoint)translationInView:(UIView *)view {return self.displacement;}
- (void)setTranslation:(CGPoint)translation inView:(UIView *)view {self.displacement=translation;}
@end
@interface GestureRoot : RootViewController
@property(nonatomic,strong) UISlider *fixtureSlider;
@end
@implementation GestureRoot
- (UISlider *)systemVolumeSlider {return self.fixtureSlider;}
@end
BOOL PlaybackGestureRunSmokeChecks(void) {
    GestureRoot *root=[GestureRoot new];root.fixtureSlider=[UISlider new];FixturePan *gesture=[FixturePan new];CGFloat values[2];
    for(NSUInteger pass=0;pass<2;pass++){NSUInteger events=pass?60:10;root.fixtureSlider.value=.5;
        for(NSUInteger i=0;i<events;i++){gesture.displacement=CGPointMake(0,-100.0/events);[root onPan:gesture];}
        values[pass]=root.fixtureSlider.value;
    }
    return fabs(values[0]-values[1])<.00001&&fabs(values[0]-(.5+100.0/220*.35))<.00001;
}
