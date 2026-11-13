#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *MediaPlaybackHeadersFromResult(NSDictionary * _Nullable result);
/// Returns only safe request-header metadata; never includes header values.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *MediaPlaybackDiagnosticHeaderFields(NSDictionary * _Nullable headers);
FOUNDATION_EXPORT BOOL MediaPlaybackResultIsDirectMedia(NSDictionary * _Nullable result);
FOUNDATION_EXPORT BOOL MediaPlaybackResultSupportsAVPlayer(NSDictionary * _Nullable result);
FOUNDATION_EXPORT BOOL MediaPlaybackResultSupportsCicada(NSDictionary * _Nullable result);
FOUNDATION_EXPORT BOOL MediaPlaybackResultSupportsNativePlayback(NSDictionary * _Nullable result);

/// Retains credentials only for the same origin or a standard-port HTTP→HTTPS upgrade.
FOUNDATION_EXPORT NSDictionary<NSString *,NSString *> *MediaPlaybackHeadersScopedToURL(NSDictionary *headers,NSURL *originURL,NSURL *targetURL);
