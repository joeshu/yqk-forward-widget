#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaSourceHealthStore : NSObject
+ (instancetype)shared;
- (BOOL)isDeprioritizedSourceID:(NSString *)sourceID;
- (void)recordSourceID:(NSString *)sourceID success:(BOOL)success elapsed:(NSTimeInterval)elapsed;
- (NSTimeInterval)averageLatencyForSourceID:(NSString *)sourceID;
- (NSString *)lineHealthKeyForSourceID:(NSString *)sourceID lineID:(NSString *)lineID;
- (void)recordLineResolutionForSourceID:(NSString *)sourceID lineID:(NSString *)lineID success:(BOOL)success elapsed:(NSTimeInterval)elapsed;
@end
NS_ASSUME_NONNULL_END
