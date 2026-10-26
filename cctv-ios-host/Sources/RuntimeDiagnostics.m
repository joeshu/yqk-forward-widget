#import "RuntimeDiagnostics.h"
#import "HostLogRedactor.h"
#import <UIKit/UIKit.h>

static NSString * const RuntimeDiagnosticsPreferenceKey = @"runtimeDiagnosticsEnabled";
static unsigned long long const RuntimeDiagnosticsMaximumBytes = 1024 * 1024;
static unsigned long long const RuntimeDiagnosticsRetainedBytes = 768 * 1024;
static void *RuntimeDiagnosticsQueueKey = &RuntimeDiagnosticsQueueKey;

@interface RuntimeDiagnostics ()
@property(nonatomic, copy) NSString *logPath;
@property(nonatomic, copy) NSString *sessionMarkerPath;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) BOOL diagnosticModeEnabled;
- (id)safeValue:(id)value key:(NSString *)key depth:(NSUInteger)depth;
- (NSString *)safeText:(NSString *)text;
- (NSDictionary * _Nullable)readSessionMarker;
- (BOOL)writeSessionMarker:(NSDictionary *)marker;
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
        self.logPath = [[directory stringByAppendingPathComponent:@"runtime-debug"] stringByAppendingPathExtension:@"jsonl"];
        self.sessionMarkerPath = [directory stringByAppendingPathComponent:@"runtime-session.json"];
        self.sessionID = NSUUID.UUID.UUIDString.lowercaseString;
        self.queue = dispatch_queue_create("com.cctvhost.runtime-diagnostics", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(self.queue, RuntimeDiagnosticsQueueKey, (__bridge void *)self, NULL);
        _diagnosticModeEnabled = [NSUserDefaults.standardUserDefaults boolForKey:RuntimeDiagnosticsPreferenceKey];
    }
    return self;
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
    if ([previous[@"open"] boolValue]) {
        NSMutableDictionary *recovery = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"session_id", @"started_at", @"last_checkpoint", @"last_checkpoint_at", @"app_version", @"app_build", @"ios_version", @"application_state", @"process_uptime_seconds"])
            if (previous[key]) recovery[key] = previous[key];
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

- (void)recordLifecycleCheckpoint:(NSString *)checkpoint fields:(NSDictionary<NSString *,id> *)fields {
    if (!checkpoint.length || !self.enabled) return;
    NSDictionary *previous = [self readSessionMarker];
    NSMutableDictionary *marker = [NSMutableDictionary dictionaryWithDictionary:previous ?: @{}];
    marker[@"open"] = @YES;
    marker[@"session_id"] = self.sessionID ?: @"unknown";
    marker[@"last_checkpoint"] = checkpoint;
    marker[@"last_checkpoint_at"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    if (fields.count) {
        for (NSString *key in @[@"app_version", @"app_build", @"ios_version", @"application_state", @"process_uptime_seconds"])
            if (fields[key]) marker[key] = fields[key];
    }
    BOOL markerSaved = [self writeSessionMarker:marker];
    NSMutableDictionary *eventFields = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
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
    [self writeSessionMarker:marker];
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
            if (![fm fileExistsAtPath:self.logPath]) [fm createFileAtPath:self.logPath contents:nil attributes:nil];
            unsigned long long size = [[fm attributesOfItemAtPath:self.logPath error:NULL] fileSize];
            if (size + line.length > RuntimeDiagnosticsMaximumBytes) [self trimLogToTail];
            NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
            @try {
                [file seekToEndOfFile];
                [file writeData:line];
                if (synchronously) [file synchronizeFile];
                [file closeFile];
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

- (id)safeValue:(id)value key:(NSString *)key depth:(NSUInteger)depth {
    if (!value || value == NSNull.null) return NSNull.null;
    if (depth > 3) return @"[truncated]";
    NSString *lower = key.lowercaseString;
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
    if (!completion) return;
    dispatch_async(self.queue, ^{
        NSData *data = [NSData dataWithContentsOfFile:self.logPath options:0 error:NULL];
        NSError *error = nil;
        NSURL *url = nil;
        if (!data.length) {
            error = [NSError errorWithDomain:@"CCTVHostDiagnostics" code:1 userInfo:@{NSLocalizedDescriptionKey:@"暂无调试记录。请先开启运行诊断模式、复现问题后再导出。"}];
        } else {
            NSString *timestamp = [[[NSISO8601DateFormatter new] stringFromDate:NSDate.date] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
            NSString *name = [NSString stringWithFormat:@"CCTVHost-运行诊断-%@.jsonl", timestamp];
            NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            if ([data writeToFile:path options:NSDataWritingAtomic error:&error]) url = [NSURL fileURLWithPath:path];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url, error); });
    });
}

@end
