// HostPlaybackSession.m
#import "HostPlaybackSession.h"
#include <math.h>

@implementation HostPlaybackSession

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentRoute = MediaPlaybackDecodeRouteNone;
        _attemptedRoutes = 0;
        _retryCount = 0;
        _resumePosition = 0;
    }
    return self;
}

+ (NSUInteger)attemptedMaskForRoute:(MediaPlaybackDecodeRoute)route {
    switch (route) {
        case MediaPlaybackDecodeRouteAVPlayer: return MediaPlaybackDecodeRouteAttemptedAVPlayer;
        case MediaPlaybackDecodeRouteCicadaPlayer: return MediaPlaybackDecodeRouteAttemptedCicadaPlayer;
        case MediaPlaybackDecodeRouteWebView: return MediaPlaybackDecodeRouteAttemptedWebView;
        case MediaPlaybackDecodeRouteMPV: return MediaPlaybackDecodeRouteAttemptedMPV;
        case MediaPlaybackDecodeRouteNone: return 0;
    }
    return 0;
}

- (void)setResumePosition:(NSTimeInterval)resumePosition {
    _resumePosition = (isfinite(resumePosition) && resumePosition > 0) ? resumePosition : 0;
}

- (MediaPlaybackDecodeRoute)peekNextRouteForResult:(NSDictionary *)result {
    return MediaPlaybackDecodeRouteNextForResult(result, self.attemptedRoutes);
}

- (MediaPlaybackDecodeRoute)nextRouteForResult:(NSDictionary *)result {
    return [self nextRouteForResult:result markAttempted:NO];
}

- (MediaPlaybackDecodeRoute)nextRouteForResult:(NSDictionary *)result markAttempted:(BOOL)markAttempted {
    MediaPlaybackDecodeRoute route = MediaPlaybackDecodeRouteNextForResult(result, self.attemptedRoutes);
    self.currentRoute = route;
    if (markAttempted) [self markRouteAttempted:route];
    return route;
}

- (void)markRouteAttempted:(MediaPlaybackDecodeRoute)route {
    self.attemptedRoutes |= [HostPlaybackSession attemptedMaskForRoute:route];
}

- (BOOL)hasAttemptedRoute:(MediaPlaybackDecodeRoute)route {
    NSUInteger mask = [HostPlaybackSession attemptedMaskForRoute:route];
    return mask != 0 && (self.attemptedRoutes & mask) == mask;
}

- (void)resetRoutes {
    self.attemptedRoutes = 0;
    self.currentRoute = MediaPlaybackDecodeRouteNone;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p route=%@ attempted=0x%lx retries=%ld resume=%.1f>",
            NSStringFromClass(self.class), (void *)self, MediaPlaybackDecodeRouteName(self.currentRoute),
            (unsigned long)self.attemptedRoutes, (long)self.retryCount, self.resumePosition];
}

@end
