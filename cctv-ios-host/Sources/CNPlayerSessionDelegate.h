#import <Foundation/Foundation.h>

@class RootViewController;

// Per-playback-session delegate for CNPlayerSDK.
//
// The SDK does not tag its callbacks with a request or session identifier, so
// a callback carries no proof of which playback it belongs to. Root used to be
// the delegate directly, which left two holes: callbacks delivered on the main
// thread were never checked against the playback generation, and callbacks
// received after a channel switch could pass the receipt-time generation check
// while still belonging to the old stream (notably when the legacy path reuses
// the same CNPlayer instance for the next channel).
//
// Each native playback session gets its own session delegate holding the
// session ID captured at play start. The session delegate forwards a callback
// to its owner only while its session is still current. A stale session
// delegate therefore drops in-flight callbacks from the old stream, on any
// thread. The owner invalidates the session in stopPlayback (which also bumps
// the session ID, so a delegate retained by the SDK can never forward again)
// and creates a fresh session delegate at every native play start.
//
// Residual limit: if the SDK itself delivers a leftover event from the old
// stream to the currently installed delegate object, no host-side check can
// tell it apart. Only an SDK-provided request identifier would close that.
@interface CNPlayerSessionDelegate : NSObject

- (instancetype)initWithOwner:(RootViewController *)owner sessionID:(NSUInteger)sessionID NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSUInteger sessionID;

// YES when this delegate still belongs to the owner's current native session.
- (BOOL)isCurrentSession;

@end
