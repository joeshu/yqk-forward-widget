#import "PlaybackOverlayController.h"
@interface PlaybackOverlayController ()
@property(nonatomic,readwrite) BOOL visible;
@property(nonatomic,strong) NSTimer *timer;
@end
@implementation PlaybackOverlayController
- (void)show {
    [self.timer invalidate];self.timer=nil;self.visible=YES;if(self.onVisibilityChanged)self.onVisibilityChanged(YES);
    if(UIAccessibilityIsVoiceOverRunning()||(self.canAutoHide&&!self.canAutoHide()))return;
    __weak typeof(self) weakSelf=self;
    self.timer=[NSTimer timerWithTimeInterval:3 repeats:NO block:^(NSTimer *timer){PlaybackOverlayController *owner=weakSelf;if(!owner)return;owner.timer=nil;if(!UIAccessibilityIsVoiceOverRunning()&&(!owner.canAutoHide||owner.canAutoHide()))[owner hide];}];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)hide {[self.timer invalidate];self.timer=nil;self.visible=NO;if(self.onVisibilityChanged)self.onVisibilityChanged(NO);}
- (void)toggle {if(self.visible)[self hide];else[self show];}
- (void)invalidate {[self.timer invalidate];self.timer=nil;}
- (void)dealloc {[self.timer invalidate];}
@end
