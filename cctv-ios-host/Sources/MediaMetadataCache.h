#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 来源连接配置指纹（T04/M04：统一 revision 的唯一定义）。
/// 只取决定连接行为的字段（id、port、protocol、packageRoot、api、header/headers、
/// manifest、playUrl、options、tvboxType、jar、subscriptionURL），显示名等展示字段
/// 不参与——同 ID 来源改了显示名不重建 client，改了连接字段才重建。
/// 返回 64 位小写 hex（SHA-256）；source 为 nil 或非字典时返回 @""。
FOUNDATION_EXPORT NSString *MediaSourceConnectionFingerprint(NSDictionary * _Nullable source);

/// 指纹的数值 revision（供 HostPerfMetrics sourceRevision 与诊断字段分组用）：
/// 取指纹前 8 位 hex 转数值；无指纹时为 0。不是单调版本号，只用于区分配置。
FOUNDATION_EXPORT NSUInteger MediaSourceConnectionRevision(NSDictionary * _Nullable source);

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
/// T15/M10：缓存年龄（秒）。-1 表示无记录，或存入时间在未来（时钟回拨，
/// 视为未知——与 resultForSource 把 age<0 当无缓存一致）。只读，不触发
/// 持久化回填；供首页/列表把“旧缓存可见”标出年龄与重试入口。
- (NSTimeInterval)ageOfResultForSource:(NSDictionary *)source
                             operation:(NSString *)operation
                             arguments:(NSDictionary *)arguments;
- (void)removeResultsForSourceID:(NSString *)sourceID;
- (NSDictionary<NSString *, NSNumber *> *)summary;
- (void)evictMemoryCache;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
