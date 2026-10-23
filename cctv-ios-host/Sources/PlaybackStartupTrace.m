#import "PlaybackStartupTrace.h"
@interface PlaybackStartupTrace ()
@property(nonatomic, assign) NSTimeInterval startedAt;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *mutableStages;
@end
@implementation PlaybackStartupTrace
- (instancetype)initWithStartTime:(NSTimeInterval)time {
    if (self = [super init]) {
        _startedAt = time;
        _mutableStages = [NSMutableDictionary dictionary];
    }
    return self;
}
- (NSDictionary<NSString *, NSNumber *> *)stages {
    return self.mutableStages.copy;
}
- (BOOL)record:(NSString *)stage atTime:(NSTimeInterval)time {
    if (!stage.length || self.mutableStages[stage] || time < self.startedAt)
        return NO;
    self.mutableStages[stage] = @(time - self.startedAt);
    return YES;
}
- (NSString *)summary {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in @[
             @"service", @"teardown", @"preloadedVDN", @"configure", @"prepareCall", @"vdn", @"setup", @"bufferTuned", @"itemReady",
             @"prepared", @"frame"
         ]) {
        NSNumber *value = self.mutableStages[key];
        if (value)
            [parts addObject:[NSString stringWithFormat:@"%@=%.2fs", key, value.doubleValue]];
    }
    return [parts componentsJoinedByString:@" · "];
}
@end
