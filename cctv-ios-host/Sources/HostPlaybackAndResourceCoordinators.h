#import <Foundation/Foundation.h>
#import "CCTVPlaybackEngineProtocol.h"
#import "MediaPlaybackDecodeRouter.h"
#import "M3UParser.h"

NS_ASSUME_NONNULL_BEGIN

/// 直播播放协调器（P2-2）：统一创建直播全能解码引擎与管理实时睡眠倒计时。
@interface HostLivePlayerCoordinator : NSObject
+ (instancetype)shared;
/// 按已决定的路由建引擎（单一工厂）：只建 route 指定的引擎，不再内部
/// 重选核。MPV 被禁用时 fail-closed（返回 nil，不实例化）；Cicada 不可
/// 用时同样返回 nil。调用方在 nil 时走统一终态。
+ (nullable id<CCTVPlaybackEngine>)engineForRoute:(MediaPlaybackDecodeRoute)route
                                               url:(NSURL *)url
                                           headers:(nullable NSDictionary<NSString *, NSString *> *)headers
                                    networkTimeout:(NSTimeInterval)timeout
                                    liveStreamHint:(BOOL)isLive;
/// 睡眠定时截止时间（nil 表示未开启）。
@property (nonatomic, strong, nullable) NSDate *sleepTimerFireDate;
/// 剩余睡眠定时秒数（0 表示未开启或已到期）。
- (NSTimeInterval)remainingSleepSeconds;
@end

/// 订阅同步与索引协调器（P2-2）：封装单源 udpxy 解析与 SQLite FTS5 异步同步。
@interface HostSubscriptionSyncCoordinator : NSObject
+ (instancetype)shared;
- (nullable NSString *)udpxyOverrideForSubscriptionURL:(NSString *)sourceURL;
- (nullable NSArray<M3UChannel *> *)parsePlaylistText:(NSString *)text
                                              baseURL:(nullable NSURL *)baseURL
                                            sourceKey:(NSString *)sourceKey
                                                error:(NSError * _Nullable * _Nullable)error;
- (void)indexChannelsAsync:(NSArray<NSDictionary *> *)channels forSourceID:(NSString *)sourceID;
@end

/// 配置备份导入导出协调器（P2-2）：集中校验与规范化 JSON 配置快照。
@interface HostResourceBackupCoordinator : NSObject
+ (nullable NSData *)serializedBackupDataFromPayload:(NSDictionary *)payload error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSDictionary *)validatedBackupPayloadFromData:(NSData *)data error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
