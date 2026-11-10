#import <Foundation/Foundation.h>
#import <math.h>

// Media seconds: faster playback consumes the same network buffer sooner.
static inline NSTimeInterval MediaPlaybackForwardBuffer(BOOL firstFrame, BOOL fastStartup, double rate, NSUInteger stalls, BOOL constrained) {
    rate=isfinite(rate)?MIN(3.0,MAX(0.5,rate)):1.0;
    double seconds=firstFrame?(constrained?6.0:12.0):(fastStartup?1.5:3.0);
    if(firstFrame)seconds+=MIN(stalls,(NSUInteger)3)*4.0;
    return MIN(constrained?12.0:30.0,seconds*MAX(1.0,rate));
}
static inline BOOL MediaPlaybackShouldPrefetch(double position,double duration,double bufferedAhead,BOOL waiting,BOOL constrained) {
    if(waiting||constrained||!isfinite(position)||!isfinite(duration)||!isfinite(bufferedAhead)||position<2||duration<=0||position>=duration||bufferedAhead<2)return NO;
    return duration-position<=MIN(90.0,duration*0.25);
}
