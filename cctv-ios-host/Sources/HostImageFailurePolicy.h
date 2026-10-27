#ifndef HOST_IMAGE_FAILURE_POLICY_H
#define HOST_IMAGE_FAILURE_POLICY_H
static inline double HostImageFailureBackoff(long status) {
    return status==404?120.0:((status==429||status==492)?60.0:30.0);
}
#endif
