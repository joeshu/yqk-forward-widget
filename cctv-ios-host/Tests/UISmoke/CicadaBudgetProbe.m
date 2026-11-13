#import <UIKit/UIKit.h>
#import "MediaPlaybackCicadaAdapter.h"
static void advanceBudgetRunLoop(NSTimeInterval seconds) {[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];}
BOOL CicadaBudgetRunSmokeChecks(void) {
    MediaPlaybackCicadaAdapter *adapter=[[MediaPlaybackCicadaAdapter alloc] initWithURL:[NSURL URLWithString:@"https://fixture.invalid/live.flv"] headers:@{} networkTimeout:5];
    [adapter prepare];[adapter setValue:@1.0 forKey:@"firstFrameRemaining"];[adapter start];[adapter pause];
    double remaining=[[adapter valueForKey:@"firstFrameRemaining"] doubleValue];
    BOOL valid=remaining>0&&remaining<=1.0&&[adapter valueForKey:@"firstFrameWatchdog"]==nil;
    advanceBudgetRunLoop(.02);valid=valid&&adapter.state==MediaPlaybackCicadaAdapterStatePaused;
    [adapter setValue:@.01 forKey:@"firstFrameRemaining"];[adapter start];advanceBudgetRunLoop(.05);valid=valid&&adapter.state==MediaPlaybackCicadaAdapterStateFailed;
    [adapter destroy];return valid;
}
