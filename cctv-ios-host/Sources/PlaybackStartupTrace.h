#import <Foundation/Foundation.h>
@interface PlaybackStartupTrace : NSObject
@property(nonatomic, readonly) NSTimeInterval startedAt;
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *stages;
- (instancetype)initWithStartTime:(NSTimeInterval)time;
/// Returns YES only the first time a stage is recorded. Ignores backwards clocks.
- (BOOL)record:(NSString *)stage atTime:(NSTimeInterval)time;
- (NSString *)summary;
@end
