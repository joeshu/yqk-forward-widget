#import <Foundation/Foundation.h>
@interface NativeTimeshiftSession : NSObject
- (instancetype)initWithPlayer:(id)player;
- (BOOL)seekStart:(NSTimeInterval)start end:(NSTimeInterval)end now:(NSTimeInterval)now completion:(void (^)(BOOL allowed,NSError *error))completion;
- (BOOL)backToLive;
- (void)cancel;
@end
