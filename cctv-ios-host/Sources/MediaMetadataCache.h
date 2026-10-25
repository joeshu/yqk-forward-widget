#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Small, process-local cache for browse metadata only. Playback URLs and request
/// headers are never cached by this store.
@interface MediaMetadataCache : NSObject
+ (instancetype)shared;
- (nullable id)resultForSource:(NSDictionary *)source
                     operation:(NSString *)operation
                     arguments:(NSDictionary *)arguments
                     maximumAge:(NSTimeInterval)maximumAge
                       isStale:(BOOL * _Nullable)isStale;
- (void)storeResult:(id)result
         forSource:(NSDictionary *)source
         operation:(NSString *)operation
         arguments:(NSDictionary *)arguments;
- (void)removeResultsForSourceID:(NSString *)sourceID;
- (NSDictionary<NSString *, NSNumber *> *)summary;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
