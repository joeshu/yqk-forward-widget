#ifndef HOST_IMAGE_FAILURE_POLICY_H
#define HOST_IMAGE_FAILURE_POLICY_H
static inline double HostImageFailureBackoff(long status) {
    return status==404?120.0:((status==429||status==492)?60.0:30.0);
}
typedef struct {unsigned timeouts; double until; int probe;} HostImageDomainState;
static inline int HostImageDomainAllows(HostImageDomainState *s,double now) {
    if(s->timeouts<3)return 1;
    if(now<s->until||s->probe)return 0;
    s->probe=1;return 1;
}
static inline void HostImageDomainFinish(HostImageDomainState *s,double now,int timeout,int cancelled) {
    s->probe=0;
    if(cancelled)return;
    if(!timeout){s->timeouts=0;s->until=0;return;}
    if(s->timeouts<3)s->timeouts++;
    if(s->timeouts>=3)s->until=now+60;
}
#endif
