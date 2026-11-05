#import "CNPlayerSessionDelegate.h"
#import "RootViewController.h"
#import <objc/runtime.h>

@implementation CNPlayerSessionDelegate {
    __weak RootViewController *_owner;
    NSUInteger _sessionID;
}

- (instancetype)initWithOwner:(RootViewController *)owner sessionID:(NSUInteger)sessionID {
    if (self = [super init]) {
        _owner = owner;
        _sessionID = sessionID;
        // Mirror NativeChannelPreloader: the SDK protocol only exists at
        // runtime, so adopt it dynamically when it is available.
        Protocol *protocol = NSProtocolFromString(@"CNPlayerCallbackProtocol");
        if (protocol) class_addProtocol(self.class, protocol);
    }
    return self;
}

- (NSUInteger)sessionID {
    return _sessionID;
}

- (BOOL)isCurrentSession {
    RootViewController *owner = _owner;
    if (!owner) return NO;
    return _sessionID == owner.nativeSessionID;
}

- (void)player:(id)player loadStateDidChanged:(NSUInteger)state {
    if (![self isCurrentSession]) return;
    [_owner player:player loadStateDidChanged:state];
}

- (void)player:(id)player vdnRequestStateDidChanged:(NSUInteger)state {
    if (![self isCurrentSession]) return;
    [_owner player:player vdnRequestStateDidChanged:state];
}

- (void)player:(id)player statEvent:(NSUInteger)event value:(id)value {
    if (![self isCurrentSession]) return;
    [_owner player:player statEvent:event value:value];
}

- (void)player:(id)player playBackStateDidChanged:(NSUInteger)state {
    if (![self isCurrentSession]) return;
    [_owner player:player playBackStateDidChanged:state];
}

- (void)player:(id)player playbackFailed:(NSError *)error {
    if (![self isCurrentSession]) return;
    [_owner player:player playbackFailed:error];
}

- (void)player:(id)player vdnRequestFailed:(NSError *)error {
    if (![self isCurrentSession]) return;
    [_owner player:player vdnRequestFailed:error];
}

- (void)player:(id)player parameterError:(NSError *)error rate:(id)rate {
    if (![self isCurrentSession]) return;
    [_owner player:player parameterError:error rate:rate];
}

- (void)player:(id)player publicRequestFailed:(NSError *)error {
    if (![self isCurrentSession]) return;
    [_owner player:player publicRequestFailed:error];
}

- (void)authFailed:(NSError *)error {
    if (![self isCurrentSession]) return;
    [_owner authFailed:error];
}

@end
