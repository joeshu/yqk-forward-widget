#import "HostPerfMetrics.h"
#import "RuntimeDiagnostics.h"
#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <string.h>
#include <math.h>

NSUInteger const HostPerfMetricsRingCapacity = 50;
static NSString *const HostPerfMetricsCategory = @"performance";

static NSTimeInterval HostPerfReadProcessStartEpoch(void) {
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return 0;
    struct timeval start = info.kp_proc.p_starttime;
    if (start.tv_sec <= 0) return 0;
    return (NSTimeInterval)start.tv_sec + (NSTimeInterval)start.tv_usec / 1000000.0;
}

static NSNumber *HostPerfMilliseconds(NSTimeInterval seconds) {
    return @((NSInteger)llround(seconds * 1000.0));
}

@interface HostPerfMetrics ()
@property(nonatomic, assign) NSTimeInterval processStartEpoch;
@property(nonatomic, assign, getter=isPrewarmedLaunch) BOOL prewarmedLaunch;
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *ring;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *milestones;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *firstFrameStats;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *switchStats;
@property(nonatomic, copy) NSString *lastFrameChannelID;
@property(nonatomic, assign) BOOL launchStartedMarked;
@property(nonatomic, assign) BOOL didFinishLaunchingMarked;
@property(nonatomic, assign) BOOL firstScreenMarked;
@property(nonatomic, assign) BOOL launchFirstFrameMarked;
@end

@implementation HostPerfMetrics

+ (instancetype)shared {
    static HostPerfMetrics *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [HostPerfMetrics new]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _processStartEpoch = HostPerfReadProcessStartEpoch();
        _prewarmedLaunch = [NSProcessInfo.processInfo.environment[@"ActivePrewarm"] isEqualToString:@"1"];
        _ring = [NSMutableArray arrayWithCapacity:HostPerfMetricsRingCapacity];
        _milestones = [NSMutableDictionary dictionary];
        _firstFrameStats = [NSMutableDictionary dictionary];
        _switchStats = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)hasReachedFirstScreen {
    @synchronized (self) { return self.firstScreenMarked; }
}

#pragma mark - Recording

/// Milliseconds since process start, or nil when sysctl was unavailable.
- (NSNumber *)sinceProcessStartMillisecondsAtEpoch:(NSTimeInterval)epoch {
    if (self.processStartEpoch <= 0 || epoch < self.processStartEpoch) return nil;
    return HostPerfMilliseconds(epoch - self.processStartEpoch);
}

- (void)emit:(NSString *)event fields:(NSDictionary<NSString *, id> *)fields {
    NSTimeInterval epoch = NSDate.date.timeIntervalSince1970;
    NSMutableDictionary<NSString *, id> *entry = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    entry[@"event"] = event;
    entry[@"epoch_ms"] = @((long long)llround(epoch * 1000.0));
    entry[@"media_time_ms"] = HostPerfMilliseconds(CACurrentMediaTime());
    NSNumber *sinceStart = [self sinceProcessStartMillisecondsAtEpoch:epoch];
    if (sinceStart && !entry[@"since_process_start_ms"]) entry[@"since_process_start_ms"] = sinceStart;
    if (self.prewarmedLaunch) entry[@"prewarmed_launch"] = @YES;
    NSDictionary<NSString *, id> *snapshot = [entry copy];
    @synchronized (self) {
        [self.ring addObject:snapshot];
        while (self.ring.count > HostPerfMetricsRingCapacity) [self.ring removeObjectAtIndex:0];
    }
    NSMutableDictionary<NSString *, id> *diagnosticFields = [snapshot mutableCopy];
    [diagnosticFields removeObjectForKey:@"event"];
    [RuntimeDiagnostics.shared recordEvent:event category:HostPerfMetricsCategory fields:diagnosticFields];
}

- (void)markLaunchStarted {
    @synchronized (self) {
        if (self.launchStartedMarked) return;
        self.launchStartedMarked = YES;
    }
    NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionary];
    fields[@"process_start_available"] = @(self.processStartEpoch > 0);
    if (self.processStartEpoch > 0)
        fields[@"process_start_epoch_ms"] = @((long long)llround(self.processStartEpoch * 1000.0));
    NSNumber *sinceStart = [self sinceProcessStartMillisecondsAtEpoch:NSDate.date.timeIntervalSince1970];
    if (sinceStart) {
        @synchronized (self) { self.milestones[@"pre_did_finish_launching_ms"] = sinceStart; }
        fields[@"pre_did_finish_launching_ms"] = sinceStart;
    }
    [self emit:@"perf_process_start" fields:fields];
}

- (void)markDidFinishLaunching {
    @synchronized (self) {
        if (self.didFinishLaunchingMarked) return;
        self.didFinishLaunchingMarked = YES;
    }
    NSNumber *sinceStart = [self sinceProcessStartMillisecondsAtEpoch:NSDate.date.timeIntervalSince1970];
    if (sinceStart) {
        @synchronized (self) { self.milestones[@"did_finish_launching_ms"] = sinceStart; }
    }
    [self emit:@"perf_did_finish_launching" fields:@{}];
}

- (BOOL)markFirstScreenInteractive:(NSString *)screen {
    @synchronized (self) {
        if (self.firstScreenMarked) return NO;
        self.firstScreenMarked = YES;
    }
    NSNumber *sinceStart = [self sinceProcessStartMillisecondsAtEpoch:NSDate.date.timeIntervalSince1970];
    if (sinceStart) {
        @synchronized (self) { self.milestones[@"first_screen_interactive_ms"] = sinceStart; }
    }
    [self emit:@"perf_first_screen_interactive" fields:@{@"screen":screen.length ? screen : @"unknown"}];
    return YES;
}

- (void)accumulate:(NSTimeInterval)seconds into:(NSMutableDictionary<NSString *, NSNumber *> *)stats {
    double ms = seconds * 1000.0;
    NSUInteger count = stats[@"count"].unsignedIntegerValue + 1;
    double total = stats[@"total_ms"].doubleValue + ms;
    stats[@"count"] = @(count);
    stats[@"total_ms"] = @(total);
    stats[@"avg_ms"] = @((NSInteger)llround(total / (double)count));
    stats[@"last_ms"] = @((NSInteger)llround(ms));
    if (!stats[@"min_ms"] || ms < stats[@"min_ms"].doubleValue) stats[@"min_ms"] = @((NSInteger)llround(ms));
    if (!stats[@"max_ms"] || ms > stats[@"max_ms"].doubleValue) stats[@"max_ms"] = @((NSInteger)llround(ms));
}

- (void)recordFirstFrameWithEngine:(NSString *)engine
                         channelID:(NSString *)channelID
                    elapsedSeconds:(NSTimeInterval)elapsedSeconds
                            stages:(NSDictionary<NSString *, NSNumber *> *)stages {
    if (elapsedSeconds < 0 || isnan(elapsedSeconds) || isinf(elapsedSeconds)) return;
    NSString *engineName = engine.length ? engine : @"unknown";
    NSString *channel = channelID.length ? [channelID copy] : @"";
    BOOL launchFirstFrame = NO;
    BOOL channelSwitch = NO;
    NSString *previousChannel = nil;
    @synchronized (self) {
        NSMutableDictionary<NSString *, NSNumber *> *stats = self.firstFrameStats[engineName];
        if (!stats) { stats = [NSMutableDictionary dictionary]; self.firstFrameStats[engineName] = stats; }
        [self accumulate:elapsedSeconds into:stats];
        if (!self.launchFirstFrameMarked) { self.launchFirstFrameMarked = YES; launchFirstFrame = YES; }
        previousChannel = self.lastFrameChannelID;
        channelSwitch = previousChannel.length > 0 && channel.length > 0 && ![previousChannel isEqualToString:channel];
        if (channelSwitch) [self accumulate:elapsedSeconds into:self.switchStats];
        if (channel.length) self.lastFrameChannelID = channel;
    }
    NSMutableDictionary<NSString *, id> *fields = [NSMutableDictionary dictionary];
    fields[@"engine"] = engineName;
    fields[@"channel_id"] = channel;
    fields[@"elapsed_ms"] = HostPerfMilliseconds(elapsedSeconds);
    NSMutableDictionary<NSString *, NSNumber *> *stageMs = [NSMutableDictionary dictionary];
    [stages enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
        if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSNumber.class]) stageMs[key] = HostPerfMilliseconds(value.doubleValue);
    }];
    if (stageMs.count) fields[@"stages_ms"] = stageMs;
    [self emit:@"perf_first_frame" fields:fields];
    if (launchFirstFrame) {
        NSNumber *sinceStart = [self sinceProcessStartMillisecondsAtEpoch:NSDate.date.timeIntervalSince1970];
        if (sinceStart) {
            @synchronized (self) { self.milestones[@"launch_first_frame_ms"] = sinceStart; }
        }
        [self emit:@"perf_launch_first_frame" fields:@{@"engine":engineName, @"channel_id":channel, @"elapsed_ms":HostPerfMilliseconds(elapsedSeconds)}];
    }
    if (channelSwitch) {
        [self emit:@"perf_channel_switch" fields:@{@"engine":engineName, @"from_channel_id":previousChannel ?: @"", @"to_channel_id":channel, @"switch_ms":HostPerfMilliseconds(elapsedSeconds)}];
    }
}

- (void)recordMark:(NSString *)name fields:(NSDictionary<NSString *, id> *)fields {
    if (!name.length) return;
    NSString *event = [name hasPrefix:@"perf_"] ? name : [@"perf_" stringByAppendingString:name];
    [self emit:event fields:fields ?: @{}];
}

#pragma mark - Export

- (NSArray<NSDictionary<NSString *, id> *> *)recentEntries {
    @synchronized (self) { return [self.ring copy]; }
}

- (NSDictionary<NSString *, id> *)summary {
    NSMutableDictionary<NSString *, id> *summary = [NSMutableDictionary dictionary];
    @synchronized (self) {
        NSMutableDictionary *frames = [NSMutableDictionary dictionary];
        [self.firstFrameStats enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary<NSString *, NSNumber *> *value, BOOL *stop) {
            frames[key] = [value copy];
        }];
        summary[@"schema"] = @"cctvhost.perf.v1";
        summary[@"ring_capacity"] = @(HostPerfMetricsRingCapacity);
        summary[@"process_start_available"] = @(self.processStartEpoch > 0);
        if (self.processStartEpoch > 0) summary[@"process_start_epoch_ms"] = @((long long)llround(self.processStartEpoch * 1000.0));
        summary[@"prewarmed_launch"] = @(self.prewarmedLaunch);
        summary[@"launch"] = [self.milestones copy];
        summary[@"first_frame_by_engine"] = frames;
        summary[@"channel_switch"] = [self.switchStats copy];
        summary[@"recent"] = [self.ring copy];
    }
    summary[@"generated_at_epoch_ms"] = @((long long)llround(NSDate.date.timeIntervalSince1970 * 1000.0));
    return summary;
}

- (NSData *)exportJSONData {
    NSDictionary *summary = [self summary];
    if (![NSJSONSerialization isValidJSONObject:summary]) return nil;
    return [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
}

- (NSURL *)exportJSONToTemporaryFileWithError:(NSError **)error {
    NSData *data = [self exportJSONData];
    if (!data) {
        if (error) *error = [NSError errorWithDomain:@"HostPerfMetrics" code:1 userInfo:@{NSLocalizedDescriptionKey:@"性能汇总无法序列化为 JSON"}];
        return nil;
    }
    NSString *name = [NSString stringWithFormat:@"cctvhost-perf-%lld.json", (long long)llround(NSDate.date.timeIntervalSince1970)];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return nil;
    return url;
}

@end
