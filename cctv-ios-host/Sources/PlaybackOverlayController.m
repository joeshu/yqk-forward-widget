#import "PlaybackOverlayController.h"
@interface PlaybackOverlayController ()
@property(nonatomic,readwrite) BOOL visible;
@property(nonatomic,strong) NSTimer *timer;
@end
@implementation PlaybackOverlayController
- (BOOL)isVoiceOverRunning {return self.voiceOverRunningProvider?self.voiceOverRunningProvider():UIAccessibilityIsVoiceOverRunning();}
- (instancetype)init {
    if((self=[super init]))[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(voiceOverStatusChanged:) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
    return self;
}
- (void)show {
    [self.timer invalidate];self.timer=nil;self.visible=YES;if(self.onVisibilityChanged)self.onVisibilityChanged(YES);
    [self scheduleAutoHideAfter:[self isVoiceOverRunning]?0.0:3.0];
}
- (void)rearmAutoHide {if(!self.visible)return;[self.timer invalidate];self.timer=nil;[self scheduleAutoHideAfter:[self isVoiceOverRunning]?0.0:3.0];}
- (void)scheduleAutoHideAfter:(NSTimeInterval)interval {
    [self.timer invalidate];self.timer=nil;
    if(!self.visible||[self isVoiceOverRunning])return;
    __weak typeof(self) weakSelf=self;
    self.timer=[NSTimer timerWithTimeInterval:interval repeats:NO block:^(NSTimer *timer){PlaybackOverlayController *owner=weakSelf;if(!owner)return;owner.timer=nil;if([owner isVoiceOverRunning])return;if(!owner.canAutoHide||owner.canAutoHide())[owner hide];else[owner scheduleAutoHideAfter:0.5];}];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)voiceOverStatusChanged:(NSNotification *)notification {
    if([self isVoiceOverRunning]){[self.timer invalidate];self.timer=nil;if(!self.visible)[self show];return;}
    if(self.visible)[self scheduleAutoHideAfter:3.0];
}
- (void)hide {[self.timer invalidate];self.timer=nil;self.visible=NO;if(self.onVisibilityChanged)self.onVisibilityChanged(NO);}
- (void)toggle {if([self isVoiceOverRunning]){if(!self.visible)[self show];return;}if(self.visible)[self hide];else[self show];}
- (void)invalidate {[self.timer invalidate];self.timer=nil;}
- (void)dealloc {[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
