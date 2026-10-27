#ifndef HOST_PLAYBACK_PROGRESS_H
#define HOST_PLAYBACK_PROGRESS_H
#include <math.h>
typedef struct { double wall,position,observed; unsigned samples; int initialized; } HostPlaybackProgress;
// Only count short, forward samples consistent with the current rate. Seeking,
// pauses and suspension gaps cannot manufacture a successful playback duration.
static inline void HostPlaybackProgressSample(HostPlaybackProgress *p,double wall,double position,double rate,int active) {
    if(!isfinite(wall)||!isfinite(position)||position<0){p->initialized=0;return;}
    if(p->initialized&&active&&isfinite(rate)&&rate>0){
        double dt=wall-p->wall,advance=position-p->position;
        if(dt>0&&dt<=2.5&&advance>0&&fabs(advance-dt*rate)<=fmax(.5,dt*rate*.5)){
            p->observed+=dt;p->samples++;
        }
    }
    p->wall=wall;p->position=position;p->initialized=1;
}
#endif
