#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaSourceHealthStore : NSObject
+ (instancetype)shared;
- (BOOL)isDeprioritizedSourceID:(NSString *)sourceID;
- (void)recordSourceID:(NSString *)sourceID success:(BOOL)success elapsed:(NSTimeInterval)elapsed;
@end
NS_ASSUME_NONNULL_END
