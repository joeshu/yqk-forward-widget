#import <Foundation/Foundation.h>
@interface ServiceStore : NSObject
+ (NSArray<NSDictionary *> *)services;
+ (NSDictionary *)resolvedService:(NSDictionary *)service;
+ (NSString *)directory;
+ (NSString *)scriptPath:(NSDictionary *)service;
+ (NSString *)codePath:(NSDictionary *)service;
+ (BOOL)isMediaService:(NSDictionary *)service;
/// Whether an imported service exposes a VOD browsing/playback flow. Manifest
/// services can also be live-only; keep this separate from isMediaService,
/// which selects the local media-service runtime.
+ (BOOL)isVODMediaService:(NSDictionary *)service;
+ (BOOL)isLiveMediaService:(NSDictionary *)service;
/// 集中判定资源的 vod/live/both/unknown：无能力元数据时沿用
/// isVODMediaService 的旧规则默认当影视，但已有直播证据（live 能力或
/// 订阅地址）时不再默认 vod，否则纯直播服务会被误标为 both。
+ (NSString *)resourceKindForService:(NSDictionary *)service subscriptionURL:(NSString *)subscriptionURL;
+ (nullable NSString *)inferredPlaylistPathInCode:(NSString *)source;
+ (NSArray<NSString *> *)playlistPathCandidatesForService:(NSDictionary *)service;
+ (nullable NSString *)playlistPathForService:(NSDictionary *)service;
+ (nullable NSString *)subscriptionURLForService:(NSDictionary *)service;
+ (nullable NSString *)epgURLForService:(NSDictionary *)service;
+ (void)associateLegacyLoopbackSubscriptionsForService:(NSDictionary *)service;
+ (void)save:(NSDictionary *)service;
/// Caller must first confirm that this service is stopped. Retains code for rollback and all user data.
+ (NSDictionary *)replaceImportedService:(NSDictionary *)existing withService:(NSDictionary *)incoming error:(NSError **)error;
+ (NSDictionary *)rollbackImportedService:(NSDictionary *)service error:(NSError **)error;
+ (void)remove:(NSString *)identifier;
+ (NSString *)activeIdentifier;
+ (NSString *)dataDirectoryForService:(NSDictionary *)service error:(NSError **)error;
@end
