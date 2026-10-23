#import <Foundation/Foundation.h>

/// A cancellable, deadline-bound HTTP readiness check. All callbacks run on main.
@interface LocalServiceReadiness : NSObject
- (instancetype)initWithURL:(NSURL *)url timeout:(NSTimeInterval)timeout requiresHealthJSON:(BOOL)health;
- (void)start:(void (^)(NSError *error, NSTimeInterval elapsed))completion;
- (void)cancel;
@end
