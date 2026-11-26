#import "PlaybackStartupTrace.h"
@interface PlaybackStartupTrace ()
@property(nonatomic, assign) NSTimeInterval startedAt;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *mutableStages;
@property(nonatomic, copy, nullable) NSString *attemptID;
@property(nonatomic, assign) NSUInteger generation;
@end
@implementation PlaybackStartupTrace
- (instancetype)initWithStartTime:(NSTimeInterval)time {
    return [self initWithStartTime:time attemptID:nil generation:0];
}
- (instancetype)initWithStartTime:(NSTimeInterval)time
                        attemptID:(NSString *)attemptID
                       generation:(NSUInteger)generation {
    if (self = [super init]) {
        _startedAt = time;
        _mutableStages = [NSMutableDictionary dictionary];
        _attemptID = [attemptID copy];
        _generation = generation;
    }
    return self;
}
- (NSDictionary<NSString *, NSNumber *> *)stages {
    @synchronized(self){return self.mutableStages.copy;}
}
- (BOOL)record:(NSString *)stage atTime:(NSTimeInterval)time {
    return [self record:stage atTime:time attemptID:self.attemptID generation:self.generation];
}
- (BOOL)record:(NSString *)stage
        atTime:(NSTimeInterval)time
     attemptID:(NSString *)attemptID
    generation:(NSUInteger)generation {
    @synchronized(self){
    if (!stage.length || self.mutableStages[stage] || time < self.startedAt)
        return NO;
    // T01: an identified trace only accepts records for its own attempt.
    // Legacy unattributed traces (attemptID nil) keep the old behavior.
    if (self.attemptID.length &&
        (![self.attemptID isEqualToString:attemptID ?: @""] || generation != self.generation))
        return NO;
    self.mutableStages[stage] = @(time - self.startedAt);
    return YES;
    }
}
- (BOOL)shouldRecoverMissingSetupAtTime:(NSTimeInterval)time alreadyRetried:(BOOL)retried failed:(BOOL)failed {
    @synchronized(self){
    // A metadata-prepared player may reuse its completed VDN result without
    // emitting another VDN callback after ownership passes to the live view.
    NSNumber *vdn=self.mutableStages[@"vdn"]?:self.mutableStages[@"preloadedVDN"];
    return !retried && !failed && vdn && !self.mutableStages[@"setup"] && !self.mutableStages[@"frame"] &&
        time-self.startedAt>=8.0 && time-self.startedAt-vdn.doubleValue>=6.0;
    }
}
- (NSString *)summary {
    @synchronized(self){
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in @[
             @"service", @"recovery", @"teardown", @"preloadedVDN", @"configure", @"prepareCall", @"vdn", @"setup", @"bufferTuned", @"itemReady",
             @"prepared", @"frame"
         ]) {
        NSNumber *value = self.mutableStages[key];
        if (value)
            [parts addObject:[NSString stringWithFormat:@"%@=%.2fs", key, value.doubleValue]];
    }
    return [parts componentsJoinedByString:@" · "];
    }
}
@end
