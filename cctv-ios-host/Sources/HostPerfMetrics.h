#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight performance baseline recorder.
///
/// Every mark is emitted as a `perf_*` event through RuntimeDiagnostics (category
/// `performance`) and is also kept in an in-memory ring buffer holding the most
/// recent HostPerfMetricsRingCapacity entries, which can be exported as JSON.
/// All methods are thread-safe; none of them block on disk I/O.
FOUNDATION_EXPORT NSUInteger const HostPerfMetricsRingCapacity;

@interface HostPerfMetrics : NSObject

+ (instancetype)shared;

/// Process start time (seconds since 1970) read from sysctl(KERN_PROC).p_starttime; 0 when unavailable.
@property(nonatomic, readonly) NSTimeInterval processStartEpoch;
/// YES when iOS launched the process as a prewarm (ActivePrewarm=1); launch offsets then include idle prewarm time.
@property(nonatomic, readonly, getter=isPrewarmedLaunch) BOOL prewarmedLaunch;
@property(nonatomic, readonly) BOOL hasReachedFirstScreen;

/// Call once at the start of application:didFinishLaunchingWithOptions: (emits perf_process_start).
- (void)markLaunchStarted;
/// Call at the end of application:didFinishLaunchingWithOptions: (emits perf_did_finish_launching).
- (void)markDidFinishLaunching;
/// Records the first root page viewDidAppear (emits perf_first_screen_interactive).
/// Returns YES only for the first call in this process, so callers can gate one-shot deferred work.
- (BOOL)markFirstScreenInteractive:(NSString *)screen;
/// Records a first video frame reported by PlaybackStartupTrace's "frame" stage.
/// `engine` classifies the playback core (e.g. cnplayer / avplayer / adapter class).
/// `elapsedSeconds` is the trace-relative time of the frame stage (selection -> frame).
/// Emits perf_first_frame, plus perf_launch_first_frame for the first frame of the process,
/// plus perf_channel_switch when the frame belongs to a different channel than the previous one.
- (void)recordFirstFrameWithEngine:(NSString *)engine
                         channelID:(nullable NSString *)channelID
                    elapsedSeconds:(NSTimeInterval)elapsedSeconds
                            stages:(nullable NSDictionary<NSString *, NSNumber *> *)stages;
/// Generic perf mark (name is prefixed with "perf_" when missing).
- (void)recordMark:(NSString *)name fields:(nullable NSDictionary<NSString *, id> *)fields;

/// Snapshot of the ring buffer, oldest first.
- (NSArray<NSDictionary<NSString *, id> *> *)recentEntries;
/// Summary dictionary: launch milestones, per-engine first-frame stats, switch stats and recent entries.
- (NSDictionary<NSString *, id> *)summary;
/// JSON-encoded summary (pretty printed, sorted keys); nil only if serialization fails.
- (nullable NSData *)exportJSONData;
/// Writes the JSON summary to a temporary file and returns its URL.
- (nullable NSURL *)exportJSONToTemporaryFileWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
