#import "MediaPlaybackMPVAdapter.h"
#import "HostMPVLifecycle.h"
#import <objc/runtime.h>
#import <math.h>

// Exercise adapter request ordering without loading a device-only libmpv.
// No libmpv handle exists, so queued commands safely fail after this check.
BOOL MPVSeekRunSmokeChecks(void) {
    MediaPlaybackMPVAdapter *adapter = [[MediaPlaybackMPVAdapter alloc]
        initWithURL:[NSURL URLWithString:@"https://fixture.test/video.mp4"]
        headers:@{} networkTimeout:1];
    Ivar lifecycleIvar = class_getInstanceVariable(MediaPlaybackMPVAdapter.class, "_lifecycle");
    if (!lifecycleIvar) return NO;
    char *objectBytes = (__bridge void *)adapter;
    host_mpv_lifecycle_t *lifecycle = *(host_mpv_lifecycle_t **)(objectBytes + ivar_getOffset(lifecycleIvar));
    if (!host_mpv_lifecycle_begin_prepare(lifecycle)) return NO;

    __block NSUInteger invalidCallbacks = 0;
    [adapter seekToTime:NAN completion:^(BOOL finished) { if (!finished) invalidCallbacks++; }];
    [adapter seekToTime:INFINITY completion:^(BOOL finished) { if (!finished) invalidCallbacks++; }];
    [adapter seekToTime:-INFINITY completion:^(BOOL finished) { if (!finished) invalidCallbacks++; }];
    BOOL invalidRejected = invalidCallbacks == 3 && [[adapter valueForKey:@"pendingSeekID"] unsignedIntegerValue] == 0;

    __block NSUInteger cancelledOld = 0, cancelledOuter = 0, cancelledNewest = 0;
    [adapter seekToTime:5 completion:^(BOOL finished) {
        if (!finished) cancelledOld++;
        [adapter seekToTime:20 completion:^(BOOL newestFinished) {
            if (!newestFinished) cancelledNewest++;
        }];
    }];
    [adapter seekToTime:10 completion:^(BOOL finished) { if (!finished) cancelledOuter++; }];
    BOOL latestPreserved = cancelledOld == 1 && cancelledOuter == 1 && cancelledNewest == 0 &&
        [[adapter valueForKey:@"pendingSeekID"] unsignedIntegerValue] == 3 &&
        [[adapter valueForKey:@"pendingSeekTarget"] doubleValue] == 20;
    [adapter destroy];
    return invalidRejected && latestPreserved && cancelledNewest == 1;
}
