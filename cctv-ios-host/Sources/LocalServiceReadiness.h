#import <Foundation/Foundation.h>

/// A cancellable, deadline-bound HTTP readiness check. All callbacks run on main.
@interface LocalServiceReadiness : NSObject
@property(nonatomic, copy) NSError *(^failureProvider)(void);
@property(nonatomic, readonly) NSUInteger attemptCount;
@property(nonatomic, copy) NSDictionary *diagnosticContext;
- (void)cancelWithReason:(NSString *)reason;
- (NSDictionary<NSString *, id> *)diagnosticSummary;
- (instancetype)initWithURL:(NSURL *)url timeout:(NSTimeInterval)timeout requiresHealthJSON:(BOOL)health;
- (void)start:(void (^)(NSError *error, NSTimeInterval elapsed))completion;
- (void)cancel;
@end
