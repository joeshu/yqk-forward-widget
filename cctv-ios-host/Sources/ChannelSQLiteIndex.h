#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 万级频道与 EPG 的 SQLite (WAL + FTS5) 检索引擎，支持 30,000+ 频道毫秒级全文搜索与按时间区间查询 EPG。
@interface ChannelSQLiteIndex : NSObject

+ (instancetype)shared;

/// 使用自定义数据库路径初始化（供单元测试与隔离场景使用）。
- (instancetype)initWithDatabasePath:(NSString *)databasePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// 原子批量替换某订阅源下的全部频道并同步更新 FTS5 索引。
- (BOOL)replaceChannels:(NSArray<NSDictionary *> *)channels forSourceID:(NSString *)sourceID;

/// 毫秒级 FTS5 全文搜索频道（支持按名称、分组、订阅源过滤）。
- (NSArray<NSDictionary *> *)searchChannelsWithQuery:(NSString *)query
                                            sourceID:(nullable NSString *)sourceID
                                               limit:(NSUInteger)limit;

/// 返回当前索引的频道总数。
- (NSUInteger)totalChannelCount;

/// 批量写入某频道的 EPG 节目单。
- (BOOL)replacePrograms:(NSArray<NSDictionary *> *)programs forChannelKey:(NSString *)channelKey;

/// 按时间区间查询某频道 EPG 节目列表。
- (NSArray<NSDictionary *> *)programsForChannelKey:(NSString *)channelKey
                                         fromEpoch:(NSTimeInterval)startEpoch
                                           toEpoch:(NSTimeInterval)endEpoch;

/// 关闭数据库连接。
- (void)close;

@end

NS_ASSUME_NONNULL_END
