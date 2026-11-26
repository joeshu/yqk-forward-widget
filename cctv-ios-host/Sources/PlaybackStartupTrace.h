#import <Foundation/Foundation.h>
@interface PlaybackStartupTrace : NSObject
@property(nonatomic, readonly) NSTimeInterval startedAt;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *stages;
/// Attempt identity (T01 / PERF-07): the controller's
/// currentRemotePlaybackAttemptID and playbackGeneration at trace creation.
/// Nil / 0 means "unattributed" (legacy callers); identified traces reject
/// stage records whose identity does not match, so an old callback can
/// never write into a new attempt's trace.
@property(nonatomic, readonly, copy, nullable) NSString *attemptID;
@property(nonatomic, readonly) NSUInteger generation;
- (instancetype)initWithStartTime:(NSTimeInterval)time;
- (instancetype)initWithStartTime:(NSTimeInterval)time
                        attemptID:(nullable NSString *)attemptID
                       generation:(NSUInteger)generation;
/// Returns YES only the first time a stage is recorded. Ignores backwards clocks.
- (BOOL)record:(NSString *)stage atTime:(NSTimeInterval)time;
/// Same, but rejects the record when the trace is identified and the
/// caller's attempt identity does not match (stale callback).
- (BOOL)record:(NSString *)stage
        atTime:(NSTimeInterval)time
     attemptID:(nullable NSString *)attemptID
    generation:(NSUInteger)generation;
/// Recover only a stalled VDN-to-core transition, never buffering/auth failures.
- (BOOL)shouldRecoverMissingSetupAtTime:(NSTimeInterval)time alreadyRetried:(BOOL)retried failed:(BOOL)failed;
- (NSString *)summary;
@end
