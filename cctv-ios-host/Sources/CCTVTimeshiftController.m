#import "CCTVTimeshiftController.h"
#import "NativeTimeshiftSession.h"
#import <math.h>
#import <string.h>

// 防抖窗口：0.3 秒内多次 seek 请求只执行最后一次。
static const NSTimeInterval CCTVTimeshiftDebounceInterval = 0.3;
// 版权预检缓存：同一频道同一节目 60 秒内不重复校验。
static const NSTimeInterval CCTVTimeshiftCopyrightCacheTTL = 60.0;
// 版权预检超时：5 秒无回调则放行 seek（SDK seek 本身会再校验版权）。
static const NSTimeInterval CCTVTimeshiftCopyrightCheckTimeout = 5.0;
static NSString *const CCTVTimeshiftErrorDomain = @"CCTVHostTimeshift";

// 运行时协议：CNPlayerSDK.h 存根未声明 checkPublicPlaytime，
// 与 NativeTimeshiftSession 的 CCTVNativeTimeshift 协议做法一致，
// 先校验方法签名再直接调用，避免 unrecognized selector。
@protocol CCTVPublicCheckPlayer <NSObject>
- (void)checkPublicPlaytime:(NSTimeInterval)playTime completionBlock:(void (^)(BOOL isPublic, id programChecked, NSError *error))completionBlock;
@end

@interface CCTVTimeshiftController ()
@property(nonatomic, weak) id player;
@property(nonatomic, strong) NativeTimeshiftSession *session;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) CCTVTimeshiftState state;
@property(nonatomic) NSTimeInterval seekStart;
@property(nonatomic) NSTimeInterval seekEnd;
@property(nonatomic) NSTimeInterval seekLatency;
@property(nonatomic) NSTimeInterval seekFirstFrameLatency;
@property(nonatomic) NSTimeInterval behindLiveSeconds;
@property(nonatomic) NSUInteger stallCount;
@property(nonatomic) BOOL stalled;
@property(nonatomic) BOOL cancelledByUs;
// 待执行的防抖 seek。
@property(nonatomic) NSTimeInterval pendingStart;
@property(nonatomic) NSTimeInterval pendingEnd;
@property(nonatomic, copy) NSString *pendingChannelID;
@property(nonatomic, copy) void (^pendingCompletion)(BOOL ok, NSError *error);
@property(nonatomic) BOOL pendingSeekScheduled;
// 本次 seek 的上下文。
@property(nonatomic) NSTimeInterval seekIssuedAt;
@property(nonatomic) NSTimeInterval seekCheckAt;
@property(nonatomic) BOOL seekFirstFrameRecorded;
@property(nonatomic) NSUInteger seekAttempts;
@property(nonatomic) BOOL seekPreCheckPassed;   // 预检通过（或跳过预检时为 YES）
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *copyrightCache;
@end

@implementation CCTVTimeshiftController

- (instancetype)initWithPlayer:(id)player {
    if (self = [super init]) {
        _copyrightCache = [NSMutableDictionary dictionary];
        [self resetWithPlayer:player];
    }
    return self;
}

- (void)resetWithPlayer:(id)player {
    [self cancel];
    _player = player;
    _session = player ? [[NativeTimeshiftSession alloc] initWithPlayer:player] : nil;
    _state = CCTVTimeshiftStateIdle;
    _seekStart = 0; _seekEnd = 0; _seekLatency = 0; _seekFirstFrameLatency = 0;
    _behindLiveSeconds = 0; _stallCount = 0; _stalled = NO;
}

#pragma mark - 状态

- (void)setState:(CCTVTimeshiftState)state {
    if (_state == state) return;
    _state = state;
    if (self.onStateChanged) self.onStateChanged(state);
}

- (NSError *)errorWithCode:(CCTVTimeshiftError)code message:(NSString *)message {
    return [NSError errorWithDomain:CCTVTimeshiftErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @""}];
}

- (void)failWithError:(NSError *)error completion:(void (^)(BOOL, NSError *))completion {
    [self setState:CCTVTimeshiftStateFailed];
    if (completion) completion(NO, error);
    if (self.onFailure) self.onFailure(error);
}

#pragma mark - Seek（防抖 + 版权预检 + 一次重试）

- (void)requestSeekToStart:(NSTimeInterval)start end:(NSTimeInterval)end channelID:(NSString *)channelID completion:(void (^)(BOOL, NSError *))completion {
    // 范围校验与 NativeTimeshiftSession 一致，失败立即返回（不等防抖）。
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!isfinite(start) || !isfinite(end) || !isfinite(now) || start <= 0 || start >= now || end < 0 || (end != 0 && (end <= start || end > now))) {
        NSError *error = [self errorWithCode:CCTVTimeshiftErrorInvalidRange message:@"回看时间范围无效：开始时间须大于 0 且早于当前时间，结束时间须晚于开始时间且不晚于当前时间"];
        dispatch_async(dispatch_get_main_queue(), ^{ [self failWithError:error completion:completion]; });
        return;
    }
    if (!self.player || !self.session) {
        NSError *error = [self errorWithCode:CCTVTimeshiftErrorUnsupportedPlayer message:@"当前播放器不支持时移定位接口"];
        dispatch_async(dispatch_get_main_queue(), ^{ [self failWithError:error completion:completion]; });
        return;
    }
    // 新请求取消进行中的 seek（会话代际守卫会丢弃旧回调），并合并防抖：
    // 每次请求都重新计时，只执行最后一次；旧的防抖块因代际不符直接丢弃。
    self.cancelledByUs = YES;
    [self.session cancel];
    self.pendingStart = start; self.pendingEnd = end;
    self.pendingChannelID = channelID ?: @"";
    self.pendingCompletion = completion;
    NSUInteger generation = ++self.generation;
    self.pendingSeekScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CCTVTimeshiftDebounceInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CCTVTimeshiftController *owner = weakSelf;
        if (!owner || generation != owner.generation) return;
        owner.pendingSeekScheduled = NO;
        [owner executePendingSeek];
    });
}

- (void)executePendingSeek {
    NSTimeInterval start = self.pendingStart, end = self.pendingEnd;
    NSString *channelID = self.pendingChannelID;
    void (^completion)(BOOL, NSError *) = self.pendingCompletion;
    self.pendingCompletion = nil;
    self.seekAttempts = 0;
    self.seekPreCheckPassed = NO;
    self.seekFirstFrameRecorded = NO;
    self.seekLatency = 0; self.seekFirstFrameLatency = 0;
    self.seekStart = start; self.seekEnd = end;
    [self setState:CCTVTimeshiftStateCheckingCopyright];
    NSUInteger generation = self.generation;
    [self checkCopyrightForStart:start channelID:channelID completion:^(BOOL allowed, NSError *error) {
        if (generation != self.generation) return; // 已被新请求/取消取代。
        if (self.state != CCTVTimeshiftStateCheckingCopyright) return;
        if (error) {
            // 预检本身失败/超时：放行 seek，SDK seek 会再校验版权。
            [self issueSeekToStart:start end:end channelID:channelID completion:completion];
            return;
        }
        if (!allowed) {
            NSError *noCopyright = [self errorWithCode:CCTVTimeshiftErrorNoCopyright message:@"该时段节目无回看版权，请返回直播或选择其他节目"];
            [self failWithError:noCopyright completion:completion];
            return;
        }
        self.seekPreCheckPassed = YES;
        [self issueSeekToStart:start end:end channelID:channelID completion:completion];
    }];
}

- (void)checkCopyrightForStart:(NSTimeInterval)start channelID:(NSString *)channelID completion:(void (^)(BOOL allowed, NSError *error))completion {
    NSString *key = [NSString stringWithFormat:@"%@|%lld", channelID ?: @"", (long long)start];
    NSDictionary *cached = self.copyrightCache[key];
    if (cached) {
        NSTimeInterval at = [cached[@"at"] doubleValue];
        if (NSProcessInfo.processInfo.systemUptime - at < CCTVTimeshiftCopyrightCacheTTL) {
            BOOL allowed = [cached[@"public"] boolValue];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(allowed, nil); });
            return;
        }
        [self.copyrightCache removeObjectForKey:key];
    }
    // 运行时校验签名：checkPublicPlaytime:completionBlock:（double, block）。
    SEL sel = @selector(checkPublicPlaytime:completionBlock:);
    NSMethodSignature *signature = [(NSObject *)self.player methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments != 4 || [signature getArgumentTypeAtIndex:2][0] != 'd' || strcmp([signature getArgumentTypeAtIndex:3], "@?") != 0) {
        // 播放器未实现版权预检接口：跳过预检，直接 seek（SDK seek 会校验）。
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, [NSError errorWithDomain:CCTVTimeshiftErrorDomain code:CCTVTimeshiftErrorUnsupportedPlayer userInfo:nil]); });
        return;
    }
    __block BOOL delivered = NO;
    __weak typeof(self) weakSelf = self;
    void (^deliver)(BOOL, NSError *) = ^(BOOL allowed, NSError *error) {
        if (delivered) return;
        delivered = YES;
        CCTVTimeshiftController *owner = weakSelf;
        if (!owner) return;
        if (!error) owner.copyrightCache[key] = @{@"public": @(allowed), @"at": @(NSProcessInfo.processInfo.systemUptime)};
        dispatch_async(dispatch_get_main_queue(), ^{ completion(allowed, error); });
    };
    @try {
        [(id<CCTVPublicCheckPlayer>)self.player checkPublicPlaytime:start completionBlock:^(BOOL isPublic, id programChecked, NSError *error) {
            deliver(isPublic, error);
        }];
    } @catch (NSException *exception) {
        deliver(YES, [NSError errorWithDomain:CCTVTimeshiftErrorDomain code:CCTVTimeshiftErrorUnsupportedPlayer userInfo:nil]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CCTVTimeshiftCopyrightCheckTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        deliver(YES, [NSError errorWithDomain:CCTVTimeshiftErrorDomain code:CCTVTimeshiftErrorTimeout userInfo:nil]);
    });
}

- (void)issueSeekToStart:(NSTimeInterval)start end:(NSTimeInterval)end channelID:(NSString *)channelID completion:(void (^)(BOOL, NSError *))completion {
    self.seekAttempts += 1;
    [self setState:CCTVTimeshiftStateSeeking];
    self.seekIssuedAt = NSProcessInfo.processInfo.systemUptime;
    self.seekCheckAt = self.seekIssuedAt;
    NSUInteger generation = self.generation;
    __weak typeof(self) weakSelf = self;
    NSError *seekError = nil;
    BOOL accepted = [self.session seekStart:start end:end now:NSDate.date.timeIntervalSince1970 error:&seekError completion:^(BOOL allowed, NSError *error) {
        CCTVTimeshiftController *owner = weakSelf;
        if (!owner || generation != owner.generation) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!owner || generation != owner.generation) return;
            [owner handleSeekCompletionAllowed:allowed error:error start:start end:end channelID:channelID completion:completion];
        });
    }];
    if (!accepted) {
        NSError *error = seekError ?: [self errorWithCode:CCTVTimeshiftErrorUnsupportedPlayer message:@"当前播放器不支持时移定位接口"];
        [self failWithError:error completion:completion];
    }
}

- (void)handleSeekCompletionAllowed:(BOOL)allowed error:(NSError *)error start:(NSTimeInterval)start end:(NSTimeInterval)end channelID:(NSString *)channelID completion:(void (^)(BOOL, NSError *))completion {
    if (allowed && !error) {
        self.seekLatency = NSProcessInfo.processInfo.systemUptime - self.seekIssuedAt;
        // 首帧可能已先于本回调到达（已转 PlayingReplay），接受仍要回调宿主；
        // 首帧尚未确认时留待 SeekSucceed / FirstRender 回调再转态。
        if (completion) completion(YES, nil);
        return;
    }
    if (self.state != CCTVTimeshiftStateSeeking) return; // 已首帧成功，忽略迟到的失败。
    // 瞬时失败重试一次（同播放器实例，不重建、不重新请求 VDN）；
    // 仅在预检通过时重试——已知有版权，失败属瞬时；预检未做/失败时不重试，
    // 避免对无版权内容重复请求；超时（已等 10 秒）也不重试，直接失败。
    BOOL transient = error.code != CCTVTimeshiftErrorTimeout;
    if (transient && self.seekAttempts < 2 && self.seekPreCheckPassed) {
        [self issueSeekToStart:start end:end channelID:channelID completion:completion];
        return;
    }
    NSError *finalError = error ?: [self errorWithCode:CCTVTimeshiftErrorSeekRejected message:@"频道未允许该时间的时移/回看，请返回直播或重新选台。"];
    [self failWithError:finalError completion:completion];
}

#pragma mark - 返回直播

- (void)returnToLive {
    self.cancelledByUs = YES;
    [self.session cancel];
    self.pendingCompletion = nil;
    self.pendingSeekScheduled = NO;
    [self setState:CCTVTimeshiftStateReturningToLive];
    if (![self.session backToLive]) {
        // SDK 不支持 backToLive：宿主整台重播（重新起播，不经过时移接口）。
        [self setState:CCTVTimeshiftStateFailed];
        if (self.onReturnToLiveFallback) self.onReturnToLiveFallback();
    }
}

- (void)noteReturnedToLive {
    self.seekStart = 0; self.seekEnd = 0; self.behindLiveSeconds = 0;
    self.stalled = NO;
    [self setState:CCTVTimeshiftStateIdle];
}

#pragma mark - SDK 回调转发

- (void)noteLoadState:(NSUInteger)state {
    if (state == CCTVTimeshiftLoadStateSeekSucceed) {
        if (self.state == CCTVTimeshiftStateSeeking) [self recordSeekFirstFrame];
        return;
    }
    if (state == CCTVTimeshiftLoadStateStalled) {
        if (self.state == CCTVTimeshiftStatePlayingReplay && !self.stalled) {
            self.stalled = YES; self.stallCount += 1;
        }
        return;
    }
    if (state == CCTVTimeshiftLoadStateStalledRecovery) {
        self.stalled = NO;
        return;
    }
    if (state == CCTVTimeshiftLoadStateCancelled) {
        if (self.state == CCTVTimeshiftStateSeeking && !self.cancelledByUs) {
            NSError *error = [self errorWithCode:CCTVTimeshiftErrorSeekRejected message:@"时移定位被取消，请重试或返回直播"];
            [self failWithError:error completion:nil];
        }
        self.cancelledByUs = NO;
        return;
    }
}

- (void)noteStatEvent:(NSUInteger)event {
    if (event == CCTVTimeshiftStatEventVODSeekStart) {
        if (self.state == CCTVTimeshiftStateSeeking) self.seekCheckAt = NSProcessInfo.processInfo.systemUptime;
        return;
    }
    if (event == CCTVTimeshiftStatEventVODSeekCompletion) {
        if (self.state == CCTVTimeshiftStateSeeking) [self recordSeekFirstFrame];
        return;
    }
    if (event == CCTVTimeshiftStatEventFirstRenderDidStart) {
        if (self.state == CCTVTimeshiftStateSeeking) [self recordSeekFirstFrame];
        return;
    }
}

- (void)recordSeekFirstFrame {
    if (self.seekFirstFrameRecorded) return;
    self.seekFirstFrameRecorded = YES;
    self.seekFirstFrameLatency = NSProcessInfo.processInfo.systemUptime - self.seekIssuedAt;
    [self setState:CCTVTimeshiftStatePlayingReplay];
    [self updateBehindLive];
}

- (void)noteCopyrightChanged:(BOOL)isPublic error:(NSError *)error {
    if (isPublic) return;
    if (self.state != CCTVTimeshiftStateSeeking && self.state != CCTVTimeshiftStatePlayingReplay) return;
    self.cancelledByUs = YES;
    [self.session cancel];
    NSError *copyrightError = [self errorWithCode:CCTVTimeshiftErrorNoCopyright message:@"该节目版权已变更，无法继续回看，请返回直播"];
    [self failWithError:copyrightError completion:nil];
}

- (void)notePeriodicTick {
    if (self.state != CCTVTimeshiftStatePlayingReplay) return;
    [self updateBehindLive];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSTimeInterval position = MAX(0, now - self.seekStart);
    if (self.onProgress) self.onProgress(self.behindLiveSeconds, position);
}

- (void)updateBehindLive {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // 有界回看：距直播按节目结束算；开放时移：距直播按回看起点算。
    self.behindLiveSeconds = self.seekEnd > 0 ? MAX(0, now - self.seekEnd) : MAX(0, now - self.seekStart);
}

- (void)cancel {
    self.generation++;
    self.cancelledByUs = YES;
    [self.session cancel];
    self.pendingCompletion = nil;
    self.pendingSeekScheduled = NO;
    if (self.state != CCTVTimeshiftStateIdle) [self setState:CCTVTimeshiftStateIdle];
}

@end
