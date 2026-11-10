#import <Foundation/Foundation.h>
#import "MediaPlaybackBufferPolicy.h"
#define Check(value) do { if(!(value)){NSLog(@"failed: %s",#value);return 1;} } while(0)
int main(void){@autoreleasepool {
    Check(MediaPlaybackForwardBuffer(NO,YES,1,0,NO)<MediaPlaybackForwardBuffer(NO,NO,1,0,NO));
    double steady=MediaPlaybackForwardBuffer(YES,YES,1,0,NO),stalled=MediaPlaybackForwardBuffer(YES,YES,1,2,NO);
    Check(steady>=10&&stalled>steady);
    Check(MediaPlaybackForwardBuffer(YES,YES,3,100,NO)<=30);
    Check(MediaPlaybackForwardBuffer(YES,YES,NAN,0,NO)==steady);
    Check(MediaPlaybackForwardBuffer(YES,YES,2,3,YES)<=12);
    Check(!MediaPlaybackCanGrowForwardBuffer(0,12,12,YES));
    Check(!MediaPlaybackCanGrowForwardBuffer(5,3,12,YES));
    Check(!MediaPlaybackCanGrowForwardBuffer(5,12,12,NO));
    Check(!MediaPlaybackCanGrowForwardBuffer(5,NAN,12,YES));
    Check(MediaPlaybackCanGrowForwardBuffer(5,12,12,YES));
    Check(!MediaPlaybackShouldPrefetch(10,1800,10,NO,NO));
    Check(MediaPlaybackShouldPrefetch(1750,1800,10,NO,NO));
    Check(!MediaPlaybackShouldPrefetch(1750,1800,0.5,NO,NO));
    Check(!MediaPlaybackShouldPrefetch(1750,1800,10,YES,NO));
    Check(!MediaPlaybackShouldPrefetch(1750,1800,10,NO,YES));
    Check(!MediaPlaybackShouldPrefetch(10,INFINITY,10,NO,NO));
    NSLog(@"Playback buffer policy tests passed");return 0;
}}
