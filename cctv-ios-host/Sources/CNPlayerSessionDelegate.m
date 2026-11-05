#import "CNPlayerSessionDelegate.h"
#import "RootViewController.h"
#import <objc/runtime.h>

// 时移 / 回看新增转发（手册 §4.7 版权变动、§4.9 每秒周期事件）。
// 宿主侧的方法由集成补丁在 RootViewController 补齐；此处先判
// respondsToSelector，补丁未合入前不崩溃，也不影响其它回调的转发。
// 注意：分类声明必须放在 @implementation 之前，不能写在实现块里。
@interface RootViewController (CCTVTimeshiftCallbacks)
- (void)player:(id)player programPubicChanged:(BOOL)isPublic;
- (void)player:(id)player programPubicChanged:(BOOL)isPublic type:(NSUInteger)sourceType error:(NSError *)error;
- (void)playerPeriodicTimeEvent:(id)player;
@end

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

- (void)player:(id)player programPubicChanged:(BOOL)isPublic {
    if (![self isCurrentSession]) return;
    if ([_owner respondsToSelector:@selector(player:programPubicChanged:)]) [_owner player:player programPubicChanged:isPublic];
}

- (void)player:(id)player programPubicChanged:(BOOL)isPublic type:(NSUInteger)sourceType error:(NSError *)error {
    if (![self isCurrentSession]) return;
    if ([_owner respondsToSelector:@selector(player:programPubicChanged:type:error:)]) [_owner player:player programPubicChanged:isPublic type:sourceType error:error];
}

- (void)playerPeriodicTimeEvent:(id)player {
    if (![self isCurrentSession]) return;
    if ([_owner respondsToSelector:@selector(playerPeriodicTimeEvent:)]) [_owner playerPeriodicTimeEvent:player];
}

@end
