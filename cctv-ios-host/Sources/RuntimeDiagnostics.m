#import "RuntimeDiagnostics.h"
#import "HostLogRedactor.h"
#import <UIKit/UIKit.h>
#import <MetricKit/MetricKit.h>
#import <mach/mach.h>

static NSString * const RuntimeDiagnosticsPreferenceKey = @"runtimeDiagnosticsEnabled";
static unsigned long long const RuntimeDiagnosticsMaximumBytes = 4 * 1024 * 1024;
static unsigned long long const RuntimeDiagnosticsRetainedBytes = 3 * 1024 * 1024;
static NSUInteger const RuntimeDiagnosticsMaximumSessions = 24;
static unsigned long long const RuntimeDiagnosticsMaximumTotalBytes = 32 * 1024 * 1024;
static void *RuntimeDiagnosticsQueueKey = &RuntimeDiagnosticsQueueKey;
static RuntimeDiagnostics *RuntimeDiagnosticsExceptionTarget;
static NSUncaughtExceptionHandler *RuntimeDiagnosticsPreviousExceptionHandler;
static BOOL RuntimeDiagnosticsExceptionHandlerInstalled;
static BOOL RuntimeDiagnosticsHandlingException;

static NSString *RuntimeDiagnosticsStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static void RuntimeDiagnosticsCollectCallStackFrames(id value, NSMutableArray<NSString *> *frames, NSUInteger depth) {
    if (depth > 16 || frames.count >= 16) return;
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            RuntimeDiagnosticsCollectCallStackFrames(item, frames, depth + 1);
            if (frames.count >= 16) break;
        }
        return;
    }
    if (![value isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dictionary = value;
    NSString *binaryUUID = RuntimeDiagnosticsStringValue(dictionary[@"binaryUUID"] ?: dictionary[@"binaryUuid"]);
    NSString *binaryName = RuntimeDiagnosticsStringValue(dictionary[@"binaryName"] ?: dictionary[@"imageName"]);
    NSString *offset = RuntimeDiagnosticsStringValue(dictionary[@"offsetIntoBinaryTextSegment"] ?: dictionary[@"offset"]);
    NSString *sampleCount = RuntimeDiagnosticsStringValue(dictionary[@"sampleCount"]);
    if (offset.length) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (binaryName.length) [parts addObject:[NSString stringWithFormat:@"image=%@", binaryName]];
        if (binaryUUID.length) [parts addObject:[NSString stringWithFormat:@"uuid=%@", binaryUUID]];
        if (offset.length) [parts addObject:[NSString stringWithFormat:@"offset=%@", offset]];
        // Addresses are intentionally omitted; UUID plus image offset is enough
        // to locate a frame against the matching dSYM and is more stable.
        if (sampleCount.length) [parts addObject:[NSString stringWithFormat:@"samples=%@", sampleCount]];
        [frames addObject:[parts componentsJoinedByString:@" "]];
    }
    for (id key in dictionary) {
        if (![key isKindOfClass:NSString.class]) continue;
        if ([key isEqualToString:@"binaryImages"] || [key isEqualToString:@"binaryImageList"]) continue;
        RuntimeDiagnosticsCollectCallStackFrames(dictionary[key], frames, depth + 1);
        if (frames.count >= 16) break;
    }
}

static void RuntimeDiagnosticsHandleUncaughtException(NSException *exception) {
    if (!RuntimeDiagnosticsHandlingException) {
        RuntimeDiagnosticsHandlingException = YES;
        @autoreleasepool {
            RuntimeDiagnostics *diagnostics = RuntimeDiagnosticsExceptionTarget;
            if (diagnostics.enabled) {
                NSArray<NSString *> *stack = exception.callStackSymbols ?: @[];
                NSArray<NSString *> *topFrames = [stack subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, stack.count))];
                NSDictionary *fields = @{
                    @"exception_name":exception.name ?: @"NSException",
                    @"exception_reason":exception.reason ?: @"",
                    @"stack_frame_count":@(stack.count),
                    @"top_stack_frames":topFrames
                };
                [diagnostics recordEventSynchronously:@"uncaught_objc_exception" category:@"crash" fields:fields];
            }
        }
        RuntimeDiagnosticsHandlingException = NO;
    }
    NSUncaughtExceptionHandler *previous = RuntimeDiagnosticsPreviousExceptionHandler;
    if (previous && previous != RuntimeDiagnosticsHandleUncaughtException) previous(exception);
}

@interface RuntimeDiagnostics () <MXMetricManagerSubscriber>
@property(nonatomic, copy) NSString *logPath;
@property(nonatomic, copy) NSString *sessionsDirectoryPath;
@property(nonatomic, copy) NSString *legacyLogPath;
@property(nonatomic, copy) NSString *sessionMarkerPath;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) BOOL diagnosticModeEnabled;
@property(nonatomic, copy) NSString *previousUnclosedSessionID;
@property(nonatomic, copy, readwrite) NSString *previousSessionTerminationState;
- (id)safeValue:(id)value key:(NSString *)key depth:(NSUInteger)depth;
- (NSString *)safeText:(NSString *)text;
- (NSDictionary * _Nullable)readSessionMarker;
- (BOOL)writeSessionMarker:(NSDictionary *)marker;
- (void)migrateLegacyLogIfNeeded;
- (NSString * _Nullable)pathForSessionID:(NSString *)sessionID;
- (void)pruneOldSessions;
- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(nullable NSDictionary<NSString *, id> *)fields synchronously:(BOOL)synchronously;
@end

@implementation RuntimeDiagnostics

+ (instancetype)shared {
    static RuntimeDiagnostics *diagnostics;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ diagnostics = [RuntimeDiagnostics new]; });
    return diagnostics;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *directory = [[support stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"diagnostics"];
        self.sessionsDirectoryPath = [directory stringByAppendingPathComponent:@"sessions"];
        self.legacyLogPath = [[directory stringByAppendingPathComponent:@"runtime-debug"] stringByAppendingPathExtension:@"jsonl"];
        self.sessionMarkerPath = [directory stringByAppendingPathComponent:@"runtime-session.json"];
        self.sessionID = NSUUID.UUID.UUIDString.lowercaseString;
        self.logPath = [self pathForSessionID:self.sessionID];
        self.queue = dispatch_queue_create("com.cctvhost.runtime-diagnostics", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(self.queue, RuntimeDiagnosticsQueueKey, (__bridge void *)self, NULL);
        _previousSessionTerminationState = @"unknown";
        _diagnosticModeEnabled = [NSUserDefaults.standardUserDefaults boolForKey:RuntimeDiagnosticsPreferenceKey];
        RuntimeDiagnosticsExceptionTarget = self;
        if (!RuntimeDiagnosticsExceptionHandlerInstalled) {
            RuntimeDiagnosticsPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
            NSSetUncaughtExceptionHandler(RuntimeDiagnosticsHandleUncaughtException);
            RuntimeDiagnosticsExceptionHandlerInstalled = YES;
        }
        if (@available(iOS 13.0, *)) [[MXMetricManager sharedManager] addSubscriber:self];
        dispatch_async(self.queue, ^{ [self migrateLegacyLogIfNeeded]; [self pruneOldSessions]; });
    }
    return self;
}

- (NSString *)pathForSessionID:(NSString *)sessionID {
    if (![sessionID isKindOfClass:NSString.class] || !sessionID.length || sessionID.length > 80) return nil;
    NSString *lower = sessionID.lowercaseString;
    BOOL isUUID = [[NSUUID alloc] initWithUUIDString:lower] != nil;
    BOOL isLegacy = [lower hasPrefix:@"legacy-"];
    if (!isUUID && !isLegacy) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"];
    if ([lower rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return [[self.sessionsDirectoryPath stringByAppendingPathComponent:lower] stringByAppendingPathExtension:@"jsonl"];
}

- (void)migrateLegacyLogIfNeeded {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSData *legacy = [NSData dataWithContentsOfFile:self.legacyLogPath options:0 error:NULL];
    if (!legacy.length) return;
    if (legacy.length > RuntimeDiagnosticsMaximumBytes) legacy = [legacy subdataWithRange:NSMakeRange(legacy.length - RuntimeDiagnosticsMaximumBytes, RuntimeDiagnosticsMaximumBytes)];
    NSString *text = [[NSString alloc] initWithData:legacy encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        id object = [NSJSONSerialization JSONObjectWithData:lineData options:NSJSONReadingFragmentsAllowed error:NULL];
        NSString *sessionID = [object isKindOfClass:NSDictionary.class] ? object[@"session_id"] : nil;
        if (![self pathForSessionID:sessionID]) sessionID = @"legacy-unknown";
        if (!groups[sessionID]) groups[sessionID] = [NSMutableArray array];
        [groups[sessionID] addObject:line];
    }
    if (!groups.count) return;
    [fm createDirectoryAtPath:self.sessionsDirectoryPath withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *sessionID in groups) {
        NSString *path = [self pathForSessionID:sessionID];
        NSData *existingData = [NSData dataWithContentsOfFile:path options:0 error:NULL];
        NSString *existingText = existingData.length ? [[NSString alloc] initWithData:existingData encoding:NSUTF8StringEncoding] : @"";
        NSMutableArray<NSString *> *merged = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *line in [existingText componentsSeparatedByString:@"\n"]) if (line.length && ![seen containsObject:line]) { [seen addObject:line]; [merged addObject:line]; }
        for (NSString *line in groups[sessionID]) if (![seen containsObject:line]) { [seen addObject:line]; [merged addObject:line]; }
        NSString *combined = [[merged componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
        if (![combined writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return;
    }
    // Remove the old aggregate only after all per-session files were written.
    [fm removeItemAtPath:self.legacyLogPath error:NULL];
}

- (void)pruneOldSessions {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:self.sessionsDirectoryPath error:NULL];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSString *name in files) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"jsonl"]) continue;
        NSString *path = [self.sessionsDirectoryPath stringByAppendingPathComponent:name];
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
        unsigned long long size = [attributes fileSize];
        total += size;
        [items addObject:@{@"path":path, @"name":name, @"size":@(size), @"date":attributes[NSFileModificationDate] ?: NSDate.distantPast}];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"date"] compare:b[@"date"]]; }];
    // Reserve one maximum-sized file for the active app run. This keeps the
    // combined directory within its advertised 32 MiB cap as that file grows.
    unsigned long long retainedBytesBudget = RuntimeDiagnosticsMaximumTotalBytes - RuntimeDiagnosticsMaximumBytes;
    while (items.count > 1 && (items.count > RuntimeDiagnosticsMaximumSessions || total > retainedBytesBudget)) {
        NSDictionary *oldest = items.firstObject;
        if ([oldest[@"name"] isEqualToString:[self.logPath lastPathComponent]]) {
            [items removeObjectAtIndex:0];
            [items addObject:oldest];
            if (items.count == 1) break;
            continue;
        }
        if ([fm removeItemAtPath:oldest[@"path"] error:NULL]) total -= [oldest[@"size"] unsignedLongLongValue];
        [items removeObjectAtIndex:0];
    }
}

- (BOOL)isEnabled {
    @synchronized (self) { return _diagnosticModeEnabled; }
}

- (void)setEnabled:(BOOL)enabled {
    @synchronized (self) {
        if (_diagnosticModeEnabled == enabled) return;
        if (!enabled) {
            [self recordEventSynchronously:@"diagnostics_disabled" category:@"diagnostics" fields:nil];
            [self writeSessionMarker:@{@"open":@NO, @"session_id":self.sessionID ?: @"unknown", @"last_checkpoint":@"diagnostics_disabled", @"last_checkpoint_at":[[NSISO8601DateFormatter new] stringFromDate:NSDate.date]}];
        }
        _diagnosticModeEnabled = enabled;
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:RuntimeDiagnosticsPreferenceKey];
    }
    if (enabled) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
        NSDictionary *fields = @{
            @"app_version":version, @"app_build":build, @"ios_version":UIDevice.currentDevice.systemVersion ?: @"unknown"
        };
        [self recordEventSynchronously:@"diagnostics_enabled" category:@"diagnostics" fields:fields];
        [self recordLifecycleCheckpoint:@"diagnostics_session_opened" fields:fields];
    }
}

- (NSDictionary *)readSessionMarker {
    NSData *data = [NSData dataWithContentsOfFile:self.sessionMarkerPath options:0 error:NULL];
    id value = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

- (BOOL)writeSessionMarker:(NSDictionary *)marker {
    if (![marker isKindOfClass:NSDictionary.class]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:marker options:0 error:NULL];
    if (!data.length) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:self.sessionMarkerPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    return [data writeToFile:self.sessionMarkerPath options:NSDataWritingAtomic error:NULL];
}

- (void)beginAppSessionWithFields:(NSDictionary<NSString *,id> *)fields {
    if (!self.enabled) return;
    NSDictionary *previous = [self readSessionMarker];
    self.previousSessionTerminationState = !previous ? @"unknown" : ([previous[@"open"] boolValue] ? @"unclosed" : @"closed");
    if ([previous[@"open"] boolValue]) {
        self.previousUnclosedSessionID = [previous[@"session_id"] isKindOfClass:NSString.class] ? previous[@"session_id"] : @"";
        NSMutableDictionary *recovery = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"session_id", @"started_at", @"last_checkpoint", @"last_checkpoint_at", @"last_checkpoint_context", @"app_version", @"app_build", @"ios_version", @"application_state", @"system_uptime_seconds", @"process_phys_footprint_bytes", @"process_phys_footprint_sample_checkpoint", @"active_playback_attempt_id", @"active_playback_service_id", @"active_playback_source_host", @"active_playback_outcome", @"last_playback_attempt_id", @"last_playback_outcome", @"last_playback_source_host", @"last_playback_failure_kind", @"last_playback_http_status", @"last_playback_line_index", @"last_playback_episode_index"])
            if (previous[key]) recovery[key] = previous[key];
        // Older builds mislabeled NSProcessInfo.systemUptime as process uptime.
        if (!recovery[@"system_uptime_seconds"] && previous[@"process_uptime_seconds"])
            recovery[@"system_uptime_seconds"] = previous[@"process_uptime_seconds"];
        recovery[@"termination_reason"] = @"unknown";
        recovery[@"interpretation"] = @"上次会话未记录到正常结束；可能是崩溃、系统回收、强制关闭或设备重启，不能仅据此判定原因";
        [self recordEventSynchronously:@"previous_session_unclosed" category:@"lifecycle" fields:recovery];
    }
    NSString *now = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    NSMutableDictionary *marker = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    marker[@"open"] = @YES;
    marker[@"session_id"] = self.sessionID ?: @"unknown";
    marker[@"started_at"] = now;
    marker[@"last_checkpoint"] = @"process_launch";
    marker[@"last_checkpoint_at"] = now;
    BOOL markerSaved = [self writeSessionMarker:marker];
    NSMutableDictionary *startupFields = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    startupFields[@"session_marker_saved"] = @(markerSaved);
    [self recordEventSynchronously:@"app_started" category:@"lifecycle" fields:startupFields];
}

- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
    if (!self.enabled) return;
    for (MXMetricPayload *payload in payloads ?: @[]) {
        if (@available(iOS 14.0, *)) {
            MXAppExitMetric *exitMetric = payload.applicationExitMetrics;
            if (exitMetric) {
                NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionaryWithDictionary:@{
                    @"report_is_aggregate":@YES,
                    @"includes_multiple_application_versions":@(payload.includesMultipleApplicationVersions)
                }];
                if (payload.timeStampBegin)
                    fields[@"metric_period_start"] = [[NSISO8601DateFormatter new] stringFromDate:payload.timeStampBegin];
                if (payload.timeStampEnd)
                    fields[@"metric_period_end"] = [[NSISO8601DateFormatter new] stringFromDate:payload.timeStampEnd];

                MXForegroundExitData *foreground = exitMetric.foregroundExitData;
                if (foreground) {
                    fields[@"foreground_normal_exit_count"] = @(foreground.cumulativeNormalAppExitCount);
                    fields[@"foreground_abnormal_exit_count"] = @(foreground.cumulativeAbnormalExitCount);
                    fields[@"foreground_watchdog_exit_count"] = @(foreground.cumulativeAppWatchdogExitCount);
                    fields[@"foreground_memory_limit_exit_count"] = @(foreground.cumulativeMemoryResourceLimitExitCount);
                    fields[@"foreground_bad_access_exit_count"] = @(foreground.cumulativeBadAccessExitCount);
                    fields[@"foreground_illegal_instruction_exit_count"] = @(foreground.cumulativeIllegalInstructionExitCount);
                }

                MXBackgroundExitData *background = exitMetric.backgroundExitData;
                if (background) {
                    fields[@"background_normal_exit_count"] = @(background.cumulativeNormalAppExitCount);
                    fields[@"background_abnormal_exit_count"] = @(background.cumulativeAbnormalExitCount);
                    fields[@"background_watchdog_exit_count"] = @(background.cumulativeAppWatchdogExitCount);
                    fields[@"background_memory_limit_exit_count"] = @(background.cumulativeMemoryResourceLimitExitCount);
                    fields[@"background_memory_pressure_exit_count"] = @(background.cumulativeMemoryPressureExitCount);
                    fields[@"background_cpu_limit_exit_count"] = @(background.cumulativeCPUResourceLimitExitCount);
                    fields[@"background_bad_access_exit_count"] = @(background.cumulativeBadAccessExitCount);
                    fields[@"background_illegal_instruction_exit_count"] = @(background.cumulativeIllegalInstructionExitCount);
                    fields[@"background_task_timeout_exit_count"] = @(background.cumulativeBackgroundTaskAssertionTimeoutExitCount);
                    fields[@"background_locked_file_exit_count"] = @(background.cumulativeSuspendedWithLockedFileExitCount);
                }

                // MetricKit reports counts aggregated over a reporting interval, not
                // the exact exit time or session. Keep that distinction explicit.
                [self recordEventSynchronously:@"metrickit_app_exit_metrics_received" category:@"crash" fields:fields];
            }
        }
    }
}

- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads API_AVAILABLE(ios(14.0)) {
    if (!self.enabled) return;
    for (MXDiagnosticPayload *payload in payloads ?: @[]) {
        for (MXCrashDiagnostic *crash in payload.crashDiagnostics ?: @[]) {
            NSMutableDictionary *fields = [@{
                @"related_session_id":self.previousUnclosedSessionID.length ? self.previousUnclosedSessionID : @"unknown",
                @"exception_type":crash.exceptionType.stringValue ?: @"unknown",
                @"exception_code":crash.exceptionCode.stringValue ?: @"unknown",
                @"signal":crash.signal ?: @"",
                @"termination_reason":crash.terminationReason ?: @"",
                @"call_stack_available":@(crash.callStackTree != nil)
            } mutableCopy];
            if (crash.callStackTree) {
                NSData *stackJSON = [crash.callStackTree JSONRepresentation];
                fields[@"call_stack_tree_json_bytes"] = @(stackJSON.length);
                id stackObject = stackJSON.length ? [NSJSONSerialization JSONObjectWithData:stackJSON options:NSJSONReadingFragmentsAllowed error:NULL] : nil;
                NSMutableArray<NSString *> *frames = [NSMutableArray array];
                RuntimeDiagnosticsCollectCallStackFrames(stackObject, frames, 0);
                fields[@"call_stack_frame_summary_count"] = @(frames.count);
                fields[@"call_stack_summary_parsed"] = @(stackObject != nil);
                if (frames.count) fields[@"call_stack_frame_summaries"] = frames;
            }
            if (@available(iOS 17.0, *)) {
                MXCrashDiagnosticObjectiveCExceptionReason *reason = crash.exceptionReason;
                if (reason.composedMessage.length) fields[@"exception_reason"] = reason.composedMessage;
                if (reason.exceptionType.length) fields[@"exception_reason_type"] = reason.exceptionType;
                if (reason.exceptionName.length) fields[@"exception_reason_name"] = reason.exceptionName;
            }
            [self recordEventSynchronously:@"metrickit_crash_diagnostic_received" category:@"crash" fields:fields];
        }
    }
}

- (void)recordLifecycleCheckpoint:(NSString *)checkpoint fields:(NSDictionary<NSString *,id> *)fields {
    if (!checkpoint.length || !self.enabled) return;
    NSDictionary *previous = [self readSessionMarker];
    NSMutableDictionary *marker = [NSMutableDictionary dictionaryWithDictionary:previous ?: @{}];
    NSMutableDictionary *checkpointFields = [fields mutableCopy] ?: [NSMutableDictionary dictionary];
    task_vm_info_data_t memoryInfo = {0};
    mach_msg_type_number_t memoryInfoCount = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memoryInfo, &memoryInfoCount) == KERN_SUCCESS) {
        checkpointFields[@"process_phys_footprint_bytes"] = @(memoryInfo.phys_footprint);
        checkpointFields[@"process_phys_footprint_sample_checkpoint"] = checkpoint;
    }
    marker[@"open"] = @YES;
    marker[@"session_id"] = self.sessionID ?: @"unknown";
    marker[@"last_checkpoint"] = checkpoint;
    marker[@"last_checkpoint_at"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    NSSet<NSString *> *contextKeys = [NSSet setWithArray:@[@"service_id", @"source_generation", @"render_serial", @"item_count", @"category_count", @"home_mode", @"module_view_count", @"item_index", @"episode_index", @"page", @"provider_count", @"request_id"]];
    NSMutableDictionary *checkpointContext = [NSMutableDictionary dictionary];
    for (NSString *key in contextKeys) {
        id value = checkpointFields[key];
        if ([value isKindOfClass:NSNumber.class] || ([key isEqualToString:@"service_id"] && [value isKindOfClass:NSString.class] && [(NSString *)value length] <= 80)) checkpointContext[key] = value;
    }
    if (checkpointContext.count) marker[@"last_checkpoint_context"] = checkpointContext;
    else [marker removeObjectForKey:@"last_checkpoint_context"];
    if (checkpointFields.count) {
        for (NSString *key in @[@"app_version", @"app_build", @"ios_version", @"application_state", @"system_uptime_seconds", @"process_phys_footprint_bytes", @"process_phys_footprint_sample_checkpoint", @"active_playback_attempt_id", @"active_playback_service_id", @"active_playback_source_host", @"active_playback_outcome", @"last_playback_attempt_id", @"last_playback_outcome", @"last_playback_source_host", @"last_playback_failure_kind", @"last_playback_http_status", @"last_playback_line_index", @"last_playback_episode_index"])
            if (checkpointFields[key]) marker[key] = checkpointFields[key];
    }
    if (!checkpointFields[@"process_phys_footprint_bytes"]) {
        [marker removeObjectForKey:@"process_phys_footprint_bytes"];
        [marker removeObjectForKey:@"process_phys_footprint_sample_checkpoint"];
    }
    BOOL markerSaved = [self writeSessionMarker:marker];
    NSMutableDictionary *eventFields = [checkpointFields mutableCopy];
    eventFields[@"session_marker_saved"] = @(markerSaved);
    [self recordEventSynchronously:checkpoint category:@"lifecycle" fields:eventFields];
}

- (void)endAppSession {
    if (!self.enabled) return;
    [self recordLifecycleCheckpoint:@"app_will_terminate" fields:nil];
    NSDictionary *previous = [self readSessionMarker];
    NSMutableDictionary *marker = [NSMutableDictionary dictionaryWithDictionary:previous ?: @{}];
    marker[@"open"] = @NO;
    marker[@"last_checkpoint"] = @"app_will_terminate";
    marker[@"last_checkpoint_at"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    BOOL closed = [self writeSessionMarker:marker];
    [self recordEventSynchronously:@"app_session_closed" category:@"lifecycle" fields:@{
        @"session_marker_closed":@(closed),
        @"last_checkpoint":@"app_will_terminate"
    }];
}

- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary<NSString *,id> *)fields {
    [self recordEvent:event category:category fields:fields synchronously:NO];
}

- (void)recordEventSynchronously:(NSString *)event category:(NSString *)category fields:(NSDictionary<NSString *,id> *)fields {
    [self recordEvent:event category:category fields:fields synchronously:YES];
}

- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary<NSString *,id> *)fields synchronously:(BOOL)synchronously {
    if (!event.length || !category.length) return;
    @synchronized (self) { if (!self.enabled) return; }
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"time"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    record[@"session_id"] = self.sessionID ?: @"unknown";
    record[@"event_id"] = NSUUID.UUID.UUIDString.lowercaseString;
    record[@"category"] = [self safeText:category];
    record[@"event"] = [self safeText:event];
    if ([fields isKindOfClass:NSDictionary.class] && fields.count) {
        record[@"fields"] = [self safeValue:fields key:@"fields" depth:0] ?: @{};
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingFragmentsAllowed error:NULL];
    if (!json.length) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    if (line.length > 8192) return;
    dispatch_block_t write = ^{
        @autoreleasepool {
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm createDirectoryAtPath:self.logPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            BOOL newSessionFile = ![fm fileExistsAtPath:self.logPath];
            if (newSessionFile) [fm createFileAtPath:self.logPath contents:nil attributes:nil];
            unsigned long long size = [[fm attributesOfItemAtPath:self.logPath error:NULL] fileSize];
            if (size + line.length > RuntimeDiagnosticsMaximumBytes) [self trimLogToTail];
            NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
            @try {
                [file seekToEndOfFile];
                [file writeData:line];
                if (synchronously) [file synchronizeFile];
                [file closeFile];
                if (newSessionFile) [self pruneOldSessions];
            }
            @catch (__unused NSException *exception) { @try { [file closeFile]; } @catch (__unused NSException *ignored) {} }
        }
    };
    if (!synchronously) dispatch_async(self.queue, write);
    else if (dispatch_get_specific(RuntimeDiagnosticsQueueKey) == (__bridge void *)self) write();
    else dispatch_sync(self.queue, write);
}

- (void)trimLogToTail {
    NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:self.logPath];
    if (!reader) return;
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:self.logPath error:NULL] fileSize];
    unsigned long long offset = size > RuntimeDiagnosticsRetainedBytes ? size - RuntimeDiagnosticsRetainedBytes : 0;
    [reader seekToFileOffset:offset];
    NSData *tail = [reader readDataToEndOfFile];
    [reader closeFile];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange boundary = [tail rangeOfData:newline options:0 range:NSMakeRange(0, tail.length)];
    NSData *retained = boundary.location == NSNotFound ? tail : [tail subdataWithRange:NSMakeRange(NSMaxRange(boundary), tail.length - NSMaxRange(boundary))];
    [retained writeToFile:self.logPath atomically:YES];
}

- (NSArray<NSDictionary *> *)readEventsAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!text.length) return @[];
    NSMutableArray *events = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        id item = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL];
        if ([item isKindOfClass:NSDictionary.class]) [events addObject:item];
    }
    return events;
}

- (NSDictionary *)summaryForSessionID:(NSString *)sessionID path:(NSString *)path marker:(NSDictionary *)marker {
    NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!reader) return nil;
    __block NSUInteger eventCount = 0;
    __block NSString *firstTime = nil, *lastTime = nil, *lastEvent = nil, *version = nil, *build = nil;
    __block BOOL cleanlyEnded = NO;
    void (^consumeLine)(NSData *) = ^(NSData *lineData) {
        if (!lineData.length || lineData.length > 8192) return;
        id event = [NSJSONSerialization JSONObjectWithData:lineData options:NSJSONReadingFragmentsAllowed error:NULL];
        if (![event isKindOfClass:NSDictionary.class]) return;
        eventCount++;
        NSString *time = [event[@"time"] isKindOfClass:NSString.class] ? event[@"time"] : nil;
        if (!firstTime) firstTime = time;
        if (time) lastTime = time;
        if ([event[@"event"] isKindOfClass:NSString.class]) lastEvent = event[@"event"];
        NSDictionary *fields = [event[@"fields"] isKindOfClass:NSDictionary.class] ? event[@"fields"] : nil;
        if ([fields[@"app_version"] isKindOfClass:NSString.class]) version = fields[@"app_version"];
        if ([fields[@"app_build"] isKindOfClass:NSString.class]) build = fields[@"app_build"];
        if ([event[@"event"] isEqualToString:@"app_session_closed"] || [event[@"event"] isEqualToString:@"diagnostics_disabled"]) cleanlyEnded = YES;
    };
    NSMutableData *pending = [NSMutableData data];
    NSData *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    @try {
        while (YES) {
            NSData *chunk = [reader readDataOfLength:64 * 1024];
            if (!chunk.length) break;
            [pending appendData:chunk];
            NSRange boundary;
            while ((boundary = [pending rangeOfData:newline options:0 range:NSMakeRange(0, pending.length)]).location != NSNotFound) {
                NSData *line = [pending subdataWithRange:NSMakeRange(0, boundary.location)];
                consumeLine(line);
                NSUInteger consumed = NSMaxRange(boundary);
                [pending replaceBytesInRange:NSMakeRange(0, consumed) withBytes:NULL length:0];
            }
            // Malformed/oversized legacy records are skipped without allowing a
            // newline-free corrupt file to grow the temporary buffer without bound.
            if (pending.length > 8192) [pending setLength:0];
        }
        consumeLine(pending);
    } @catch (__unused NSException *exception) {
        @try { [reader closeFile]; } @catch (__unused NSException *ignored) {}
        return nil;
    }
    [reader closeFile];
    if (!eventCount) return nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    return @{@"session_id":sessionID, @"event_count":@(eventCount), @"bytes":@([attributes fileSize]), @"started_at":firstTime ?: @"", @"ended_at":lastTime ?: firstTime ?: @"", @"last_event":lastEvent ?: @"", @"is_current":@([sessionID isEqualToString:self.sessionID]), @"is_open":@([marker[@"open"] boolValue] && [marker[@"session_id"] isEqualToString:sessionID]), @"cleanly_ended":@(cleanlyEnded), @"app_version":version ?: @"", @"app_build":build ?: @""};
}

- (void)loadSessionsWithCompletion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    if (!completion) return;
    dispatch_async(self.queue, ^{
        [self migrateLegacyLogIfNeeded];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:self.sessionsDirectoryPath error:NULL] ?: @[];
        NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
        NSDictionary *marker = [self readSessionMarker];
        for (NSString *name in files) {
            if (![name.pathExtension.lowercaseString isEqualToString:@"jsonl"]) continue;
            NSString *sessionID = [name stringByDeletingPathExtension].lowercaseString;
            NSString *path = [self pathForSessionID:sessionID];
            if (!path) continue;
            NSDictionary *summary = [self summaryForSessionID:sessionID path:path marker:marker];
            if (summary) [sessions addObject:summary];
        }
        [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"started_at"] compare:a[@"started_at"]]; }];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sessions, nil); });
    });
}

- (void)loadEventsForSessionID:(NSString *)sessionID completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion {
    if (!completion) return;
    dispatch_async(self.queue, ^{
        NSString *path = [self pathForSessionID:sessionID];
        NSError *error = nil;
        NSArray *events = path ? [self readEventsAtPath:path] : @[];
        if (!path || !events.count) error = [NSError errorWithDomain:@"CCTVHostDiagnostics" code:2 userInfo:@{NSLocalizedDescriptionKey:@"这次运行没有可读取的诊断记录，记录可能已清理或过期。"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(events, error); });
    });
}

- (void)prepareExportForSessionID:(NSString *)sessionID completion:(void (^)(NSURL *, NSError *))completion {
    if (!completion) return;
    dispatch_async(self.queue, ^{
        NSString *sourcePath = [self pathForSessionID:sessionID];
        NSData *data = sourcePath ? [NSData dataWithContentsOfFile:sourcePath options:0 error:NULL] : nil;
        NSError *error = nil;
        NSURL *url = nil;
        if (!data.length) error = [NSError errorWithDomain:@"CCTVHostDiagnostics" code:1 userInfo:@{NSLocalizedDescriptionKey:@"这次运行暂无诊断记录。请先开启运行诊断并复现问题。"}];
        else {
            NSString *timestamp = [[[NSISO8601DateFormatter new] stringFromDate:NSDate.date] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
            NSString *shortID = sessionID.length > 8 ? [sessionID substringToIndex:8] : sessionID;
            NSString *name = [NSString stringWithFormat:@"CCTVHost-运行诊断-%@-%@.jsonl", timestamp, shortID];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            if ([data writeToFile:path options:NSDataWritingAtomic error:&error]) url = [NSURL fileURLWithPath:path];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    });
}

- (void)deleteSessionID:(NSString *)sessionID completion:(void (^)(NSError *))completion {
    dispatch_async(self.queue, ^{
        NSString *path = [self pathForSessionID:sessionID];
        NSError *error = nil;
        if (!path) error = [NSError errorWithDomain:@"CCTVHostDiagnostics" code:3 userInfo:@{NSLocalizedDescriptionKey:@"无效的运行记录编号。"}];
        else if ([NSFileManager.defaultManager fileExistsAtPath:path] && ![NSFileManager.defaultManager removeItemAtPath:path error:&error]) { }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}

- (void)clearAllSessionsWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:self.sessionsDirectoryPath] && ![fm removeItemAtPath:self.sessionsDirectoryPath error:&error]) { }
        if (!error && [fm fileExistsAtPath:self.legacyLogPath]) [fm removeItemAtPath:self.legacyLogPath error:&error];
        if (!error && self.enabled) {
            [fm createDirectoryAtPath:self.sessionsDirectoryPath withIntermediateDirectories:YES attributes:nil error:&error];
        }
        if (!error) {
            if (self.enabled) {
                NSDictionary *previous = [self readSessionMarker] ?: @{};
                NSMutableDictionary *marker = [NSMutableDictionary dictionary];
                for (NSString *key in @[@"started_at", @"app_version", @"app_build", @"ios_version", @"application_state", @"system_uptime_seconds"]) if (previous[key]) marker[key] = previous[key];
                if (!marker[@"system_uptime_seconds"] && previous[@"process_uptime_seconds"])
                    marker[@"system_uptime_seconds"] = previous[@"process_uptime_seconds"];
                marker[@"open"] = @YES; marker[@"session_id"] = self.sessionID ?: @"unknown"; marker[@"last_checkpoint"] = @"diagnostics_cleared"; marker[@"last_checkpoint_at"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
                [self writeSessionMarker:marker];
            }
            else [fm removeItemAtPath:self.sessionMarkerPath error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}

- (id)safeValue:(id)value key:(NSString *)key depth:(NSUInteger)depth {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 3) return @"[truncated]";
    NSString *lower = key.lowercaseString;
    if (([lower isEqualToString:@"request_header_count"] || [lower isEqualToString:@"request_user_agent_present"] || [lower isEqualToString:@"request_referrer_present"] || [lower isEqualToString:@"request_origin_present"] || [lower isEqualToString:@"request_auth_material_present"]) && [value isKindOfClass:NSNumber.class]) return value;
    // This field is a boolean about URL presence, not a URL value. Keeping it
    // makes media-resolution failures diagnosable without exposing an address.
    if ([lower isEqualToString:@"result_has_media_url"] && [value isKindOfClass:NSNumber.class]) return value;
    for (NSString *sensitive in @[@"url", @"token", @"cookie", @"auth", @"secret", @"password", @"signature", @"credential", @"header", @"path", @"query", @"body", @"argument"])
        if ([lower containsString:sensitive]) return @"[redacted]";
    if ([value isKindOfClass:NSString.class]) return [self safeText:value];
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSDate.class]) return [[NSISO8601DateFormatter new] stringFromDate:value];
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *array = [NSMutableArray array];
        for (id item in [(NSArray *)value subarrayWithRange:NSMakeRange(0, MIN([(NSArray *)value count], 32))]) [array addObject:[self safeValue:item key:key depth:depth + 1] ?: NSNull.null];
        return array;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        NSUInteger count = 0;
        for (id rawKey in value) {
            if (![rawKey isKindOfClass:NSString.class] || count++ >= 32) continue;
            NSString *safeKey = [self safeText:rawKey];
            dictionary[safeKey] = [self safeValue:value[rawKey] key:rawKey depth:depth + 1] ?: NSNull.null;
        }
        return dictionary;
    }
    return [self safeText:[value description] ?: @""];
}

- (NSString *)safeText:(NSString *)text {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *safe = [HostLogRedactor redactText:text];
    safe = [safe stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    safe = [safe stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSError *regexError = nil;
    NSRegularExpression *urlPattern = [NSRegularExpression regularExpressionWithPattern:@"(?i)(https?|file)://[^\\s\\\"'<>]+" options:0 error:&regexError];
    if (urlPattern) safe = [urlPattern stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0, safe.length) withTemplate:@"[URL redacted]"];
    NSRegularExpression *pathPattern = [NSRegularExpression regularExpressionWithPattern:@"(?:/private/var/|/var/mobile/|/Users/)[^\\s,;]+" options:0 error:NULL];
    if (pathPattern) safe = [pathPattern stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0, safe.length) withTemplate:@"[path redacted]"];
    if (safe.length > 512) { NSUInteger end = 512; unichar last = [safe characterAtIndex:end - 1]; if (last >= 0xd800 && last <= 0xdbff) end--; safe = [[safe substringToIndex:end] stringByAppendingString:@"…"]; }
    return safe;
}

- (void)prepareExportWithCompletion:(void (^)(NSURL *, NSError *))completion {
    [self prepareExportForSessionID:self.sessionID completion:completion];
}

@end
