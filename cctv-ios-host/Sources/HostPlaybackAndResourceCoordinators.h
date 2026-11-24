#import <Foundation/Foundation.h>
#import "CCTVPlaybackEngineProtocol.h"
#import "M3UParser.h"

NS_ASSUME_NONNULL_BEGIN

/// 直播播放协调器（P2-2）：统一创建直播全能解码引擎与管理实时睡眠倒计时。
@interface HostLivePlayerCoordinator : NSObject
+ (instancetype)shared;
/// 根据运行期可用性与用户偏好构建直播/点播通用引擎（优先 MPV Universal，回退 Cicada）。
- (id<CCTVPlaybackEngine>)createUniversalEngineWithURL:(NSURL *)url
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
