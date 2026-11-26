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
/// Same as above, but also attributes the frame to a playback attempt for the
/// T01 attempt ledger (first-video milestone; duplicate frames for the same
/// attempt are ignored, stale callbacks for older attempts are ignored).
/// `attemptID` is the controller's currentRemotePlaybackAttemptID,
/// `generation` its playbackGeneration, `sourceRevision` its selectionVersion
/// (the revision of the selection that started this attempt; the true
/// source-config revision wiring arrives with T04).
- (void)recordFirstFrameWithEngine:(NSString *)engine
                         channelID:(nullable NSString *)channelID
                    elapsedSeconds:(NSTimeInterval)elapsedSeconds
                            stages:(nullable NSDictionary<NSString *, NSNumber *> *)stages
                         attemptID:(nullable NSString *)attemptID
                        generation:(NSUInteger)generation
                    sourceRevision:(NSUInteger)sourceRevision;
/// Playback attempt lifecycle (T01 / PERF-07). Identifiers are the same
/// correlation ids the playback controller already mints: session =
/// currentPlaybackTraceID, attempt = currentRemotePlaybackAttemptID,
/// generation = playbackGeneration. All methods are thread-safe and never
/// block on disk I/O; they feed the bounded in-memory attempt ledger and
/// emit perf_attempt_* events through RuntimeDiagnostics (dropped when
/// diagnostics is disabled). No URL, header or media content is recorded.
/// `engine` is the playback core name (avplayer / cicada / mpv / cnplayer);
/// `userAction` is select / retry / auto_recovery / resume.
- (void)beginPlaybackAttemptWithSessionID:(nullable NSString *)sessionID
                                attemptID:(nullable NSString *)attemptID
                               generation:(NSUInteger)generation
                           sourceRevision:(NSUInteger)sourceRevision
                                   engine:(nullable NSString *)engine
                               userAction:(nullable NSString *)userAction
                             expectsVideo:(BOOL)expectsVideo;
- (void)recordPlaybackAttemptFirstAudio:(nullable NSString *)attemptID
                             generation:(NSUInteger)generation
                                 engine:(nullable NSString *)engine;
- (void)recordPlaybackAttemptFirstVideo:(nullable NSString *)attemptID
                             generation:(NSUInteger)generation
                                 engine:(nullable NSString *)engine;
- (void)recordPlaybackAttemptFailed:(nullable NSString *)attemptID
                         generation:(NSUInteger)generation
                             engine:(nullable NSString *)engine
                              stage:(nullable NSString *)stage;
- (void)recordPlaybackAttemptCancelled:(nullable NSString *)attemptID
                            generation:(NSUInteger)generation;
/// Cancels the most recently begun attempt when it is still pending.
/// Used by navigation suspension, where the generation has already advanced.
- (void)cancelPendingPlaybackAttempt;
/// Generic perf mark (name is prefixed with "perf_" when missing).
- (void)recordMark:(NSString *)name fields:(nullable NSDictionary<NSString *, id> *)fields;

/// Snapshot of the ring buffer, oldest first.
- (NSArray<NSDictionary<NSString *, id> *> *)recentEntries;
/// Summary dictionary: launch milestones, per-engine first-frame stats, switch stats,
/// the T01 attempt ledger (counts, success rate, P50/P95 latencies) and recent entries.
/// The schema stays `cctvhost.perf.v1`; `attempts` is additive.
- (NSDictionary<NSString *, id> *)summary;
/// JSON-encoded summary (pretty printed, sorted keys); nil only if serialization fails.
- (nullable NSData *)exportJSONData;
/// Writes the JSON summary to a temporary file and returns its URL.
- (nullable NSURL *)exportJSONToTemporaryFileWithError:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
