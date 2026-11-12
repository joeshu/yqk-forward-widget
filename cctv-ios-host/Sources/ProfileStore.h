#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const ProfileStoreMetadataDidChangeNotification;
@interface ProfileStore : NSObject
+ (BOOL)isSource:(id)source;
+ (BOOL)isHTTP:(id)source;
+ (NSDictionary *)metadata:(NSString *)source;
+ (void)update:(NSString *)source values:(NSDictionary *)values;
+ (void)removeValueForKey:(NSString *)key source:(NSString *)source;
+ (void)remove:(NSString *)source;
+ (NSArray<NSString *> *)orderedSources:(NSArray<NSString *> *)sources;
+ (void)move:(NSString *)source offset:(NSInteger)offset sources:(NSArray<NSString *> *)sources;
+ (nullable NSString *)epgSourceForChannel:(NSDictionary *)channel;
+ (NSString *)epgIDForChannel:(NSDictionary *)channel;
+ (NSString *)normalizedLogoSourceKey:(nullable NSString *)source;
+ (BOOL)isChannelLogoEnabledForSource:(nullable NSString *)source;
+ (void)setChannelLogoEnabled:(BOOL)enabled forSource:(nullable NSString *)source;
+ (BOOL)isPlayerCornerLogoEnabledForSource:(nullable NSString *)source;
+ (void)setPlayerCornerLogoEnabled:(BOOL)enabled forSource:(nullable NSString *)source;
+ (BOOL)isChannelLogoEnabledForChannel:(nullable NSDictionary *)channel;
+ (BOOL)isPlayerCornerLogoEnabledForChannel:(nullable NSDictionary *)channel;
+ (BOOL)isChannelPreviewEnabledForSource:(nullable NSString *)source;
+ (void)setChannelPreviewEnabled:(BOOL)enabled forSource:(nullable NSString *)source;
+ (BOOL)isChannelPreviewEnabledForChannel:(nullable NSDictionary *)channel;
+ (BOOL)isChannelTelemetryEnabledForSource:(nullable NSString *)source;
+ (void)setChannelTelemetryEnabled:(BOOL)enabled forSource:(nullable NSString *)source;
+ (BOOL)isChannelTelemetryEnabledForChannel:(nullable NSDictionary *)channel;
+ (void)migrateResourceDisplaySettingsFromSource:(nullable NSString *)oldSource toSource:(nullable NSString *)newSource;
+ (nullable NSString *)canonicalStationIDForChannel:(nullable NSDictionary *)channel;
+ (NSArray<NSString *> *)subscriptionSourcesForChannel:(nullable NSDictionary *)channel;
@end
NS_ASSUME_NONNULL_END
