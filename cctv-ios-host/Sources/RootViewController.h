#import <UIKit/UIKit.h>

@interface RootViewController : UIViewController

// Native playback session ID, bumped at every native play start and on every
// stopPlayback. CNPlayerSessionDelegate captures the ID at creation and only
// forwards SDK callbacks while it still matches. Readonly here; Root owns it.
@property (nonatomic, readonly) NSUInteger nativeSessionID;

// CNPlayer SDK callbacks. The SDK calls them on CNPlayerSessionDelegate, which
// forwards them here after its session check. These stay public so the session
// delegate can call them with compiler checking. Each handler still applies
// its own current-player and generation checks as a second layer.
- (void)player:(id)player loadStateDidChanged:(NSUInteger)state;
- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state;
- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value;
- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state;
- (void)player:(id)player playbackFailed:(NSError *)error;
- (void)player:(id)player vdnRequestFailed:(NSError *)error;
- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate;
- (void)player:(id)player publicRequestFailed:(NSError *)error;
- (void)authFailed:(NSError *)error;

@end
