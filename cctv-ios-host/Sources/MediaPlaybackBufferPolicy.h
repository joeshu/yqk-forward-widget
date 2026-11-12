#import <Foundation/Foundation.h>
#import <math.h>

// Media seconds: faster playback consumes the same network buffer sooner.
static inline NSTimeInterval MediaPlaybackForwardBuffer(BOOL firstFrame, BOOL fastStartup, double rate, NSUInteger stalls, BOOL constrained) {
    rate=isfinite(rate)?MIN(3.0,MAX(0.5,rate)):1.0;
    double seconds=firstFrame?(constrained?6.0:12.0):(fastStartup?1.5:3.0);
    if(firstFrame)seconds+=MIN(stalls,(NSUInteger)3)*4.0;
    return MIN(constrained?12.0:30.0,seconds*MAX(1.0,rate));
}
// Four-stage smooth buffer ramp after first frame (1.5s -> 4.0s -> 8.0s -> 12.0s)
// to prevent post-startup buffer starvation re-stalls.
static inline NSTimeInterval MediaPlaybackSmoothForwardBuffer(BOOL firstFrame, BOOL fastStartup, double observed, double rate, NSUInteger stalls, BOOL constrained) {
    if(!firstFrame)return MediaPlaybackForwardBuffer(NO,fastStartup,rate,stalls,constrained);
    if(!isfinite(observed)||observed>=15.0)return MediaPlaybackForwardBuffer(YES,fastStartup,rate,stalls,constrained);
    rate=isfinite(rate)?MIN(3.0,MAX(0.5,rate)):1.0;
    double base=3.5;
    if(observed>=6.0)base=constrained?5.0:8.0;
    else if(observed>=2.0)base=4.0;
    base+=MIN(stalls,(NSUInteger)3)*3.5;
    return MIN(constrained?12.0:30.0,base*MAX(1.0,rate));
}
// A displayed poster/first frame does not prove continuous playback. Increasing
// the target while data is still scarce can create another startup wait.
static inline BOOL MediaPlaybackCanGrowForwardBuffer(double observed, double ahead, double target, BOOL playing) {
    return playing&&isfinite(observed)&&observed>=5.0&&isfinite(ahead)&&isfinite(target)&&target>0&&ahead>=target;
}
static inline BOOL MediaPlaybackShouldPrefetch(double position,double duration,double bufferedAhead,BOOL waiting,BOOL constrained) {
    if(waiting||constrained||!isfinite(position)||!isfinite(duration)||!isfinite(bufferedAhead)||position<2||duration<=0||position>=duration||bufferedAhead<2)return NO;
    return duration-position<=MIN(90.0,duration*0.25);
}
