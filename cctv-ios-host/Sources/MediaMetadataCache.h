#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bounded cache for browse metadata. Home/category results survive app restarts;
/// Detail results use a short-lived memory cache and exclude signed/proxy URLs.
/// Playback URLs, request headers, and credentials are excluded from disk storage.
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
- (void)removeResultForSource:(NSDictionary *)source
                    operation:(NSString *)operation
                    arguments:(NSDictionary *)arguments;
- (void)removeResultsForSourceID:(NSString *)sourceID;
- (NSDictionary<NSString *, NSNumber *> *)summary;
- (void)evictMemoryCache;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
