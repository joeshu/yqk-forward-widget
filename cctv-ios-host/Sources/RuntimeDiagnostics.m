#import "RuntimeDiagnostics.h"
#import "HostLogRedactor.h"
#import <UIKit/UIKit.h>

static NSString * const RuntimeDiagnosticsPreferenceKey = @"runtimeDiagnosticsEnabled";
static unsigned long long const RuntimeDiagnosticsMaximumBytes = 1024 * 1024;
static unsigned long long const RuntimeDiagnosticsRetainedBytes = 768 * 1024;

@interface RuntimeDiagnostics ()
@property(nonatomic, copy) NSString *logPath;
@property(nonatomic, copy) NSString *sessionID;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) BOOL diagnosticModeEnabled;
- (id)safeValue:(id)value key:(NSString *)key depth:(NSUInteger)depth;
- (NSString *)safeText:(NSString *)text;
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
        self.logPath = [[[[support stringByAppendingPathComponent:@"ysp"] stringByAppendingPathComponent:@"diagnostics"] stringByAppendingPathComponent:@"runtime-debug"] stringByAppendingPathExtension:@"jsonl"];
        self.sessionID = NSUUID.UUID.UUIDString.lowercaseString;
        self.queue = dispatch_queue_create("com.cctvhost.runtime-diagnostics", DISPATCH_QUEUE_SERIAL);
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
            [self recordEvent:@"diagnostics_disabled" category:@"diagnostics" fields:nil];
        }
        _diagnosticModeEnabled = enabled;
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:RuntimeDiagnosticsPreferenceKey];
    }
    if (enabled) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
        NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
        [self recordEvent:@"diagnostics_enabled" category:@"diagnostics" fields:@{
            @"app_version":version, @"app_build":build, @"ios_version":UIDevice.currentDevice.systemVersion ?: @"unknown"
        }];
    }
}

- (void)recordEvent:(NSString *)event category:(NSString *)category fields:(NSDictionary<NSString *,id> *)fields {
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
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm createDirectoryAtPath:self.logPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
            if (![fm fileExistsAtPath:self.logPath]) [fm createFileAtPath:self.logPath contents:nil attributes:nil];
            unsigned long long size = [[fm attributesOfItemAtPath:self.logPath error:NULL] fileSize];
            if (size + line.length > RuntimeDiagnosticsMaximumBytes) [self trimLogToTail];
            NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
            @try { [file seekToEndOfFile]; [file writeData:line]; [file closeFile]; }
            @catch (__unused NSException *exception) { @try { [file closeFile]; } @catch (__unused NSException *ignored) {} }
        }
    });
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
