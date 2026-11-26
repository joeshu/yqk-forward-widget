#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 旧版 NSUserDefaults 键（迁移来源，迁移后保留不删，便于回滚）。
FOUNDATION_EXPORT NSString *const HostLibraryLegacyFavoritesKey;   // @"favorites"
FOUNDATION_EXPORT NSString *const HostLibraryLegacyRecentsKey;     // @"recents"
/// 一次性迁移完成标记键。
FOUNDATION_EXPORT NSString *const HostLibraryMigrationMarkerKey;   // @"cctv.libraryStore.migrated.v1"
/// 回退待对账标记键：SQLite 不可用期间写入了 NSUserDefaults，下次 SQLite 恢复时需对账合并。
FOUNDATION_EXPORT NSString *const HostLibraryFallbackPendingKey;   // @"cctv.libraryStore.fallbackPending.v1"
/// 备份恢复待对账标记键：恢复时 SQLite 不可用需用 REPLACE 语义对账。
FOUNDATION_EXPORT NSString *const HostLibraryRestorePendingKey;    // @"cctv.libraryStore.restorePending.v1"
/// 点播观看历史上限。
FOUNDATION_EXPORT const NSUInteger HostMediaWatchHistoryLimit;
/// 历史行级写入的 SQLite 事务失败、已回退写入 NSUserDefaults 时发出的通知名。
FOUNDATION_EXPORT NSString *const HostLibraryStoreMediaHistoryWriteFailedNotification;
/// 最近观看条数上限（与原 rememberChannel 的 24 条保持一致）。
FOUNDATION_EXPORT const NSUInteger HostLibraryRecentsLimit;

/// 直播收藏 / 最近观看的 SQLite 存储（独立数据库文件，WAL，串行队列访问）。
/// 数据格式与原 NSUserDefaults 一致：收藏为频道 ID 字符串数组（有序），最近观看为字典数组（最新在前）。
/// SQLite 打开或迁移失败时自动回退为读写原 NSUserDefaults 键。
@interface HostLibraryStore : NSObject

+ (instancetype)shared;

/// 自定义数据库路径与 defaults（供测试与隔离场景使用）。
- (instancetype)initWithDatabasePath:(NSString *)databasePath defaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// YES 表示 SQLite 不可用，当前读写回退到原 NSUserDefaults。
@property (nonatomic, readonly) BOOL usingDefaultsFallback;

#pragma mark - 收藏
- (NSArray<NSString *> *)allFavorites;
- (BOOL)isFavorite:(NSString *)key;
- (void)addFavorite:(NSString *)key;
- (void)removeFavorite:(NSString *)key;
/// 整体替换（用于排序调整、ID 迁移、清空、备份恢复），保持数组顺序，重复项保留首个。
- (void)replaceFavorites:(nullable NSArray *)favorites;

#pragma mark - 最近观看
- (NSArray<NSDictionary *> *)recents;
/// 追加到最前；按 entry[@"id"] 去重；超过上限的旧记录被裁剪。
- (void)appendRecent:(NSDictionary *)entry;
/// 整体替换（用于移除单条、ID 迁移、备份恢复），保持数组顺序。
- (void)replaceRecents:(nullable NSArray *)recents;
- (void)clearRecents;

#pragma mark - 点播收藏与历史
/// 字典格式保持 cctv.mediaFavorites.v1：key → {sourceID, sourceName, provider, item}。
- (NSDictionary<NSString *, NSDictionary *> *)mediaFavorites;
- (void)replaceMediaFavorites:(nullable NSDictionary *)favorites;
/// 历史为最新在前的字典数组，updatedAt 对外仍为 NSDate。
- (NSArray<NSDictionary *> *)mediaWatchHistory;
- (void)replaceMediaWatchHistory:(nullable NSArray *)history;
- (void)clearMediaWatchHistory;
/// 行级写入单条历史：同 key 覆盖并置顶；previousKey 非空且与新 key 不同时，
/// 同一事务内一并删除旧行（线路/分集身份变化导致 key 改变的场景）。
/// 100 条上限由 SQL 裁剪，不再整表 DELETE + INSERT。
- (void)upsertMediaWatchHistoryEntry:(NSDictionary *)entry replacingKey:(nullable NSString *)previousKey;
/// 行级删除单条历史。
- (void)removeMediaWatchHistoryEntryWithKey:(NSString *)key;
/// 行级写入单条收藏（按 key 覆盖）。
- (void)upsertMediaFavoriteWithKey:(NSString *)key payload:(NSDictionary *)payload;
/// 行级删除单条收藏。
- (void)removeMediaFavoriteWithKey:(NSString *)key;

/// 等待所有已排队的写入完成。
- (void)flush;

/// 外部直接改了底层 NSUserDefaults 回退数据（如备份恢复的两面写）后调用：
/// 只自增快照 epoch 使快照失效，下次读重建；不碰队列、不读盘。
- (void)invalidateSnapshots;

/// 若当前处于回退模式，标记备份恢复待对账（下次 SQLite 恢复时以 REPLACE 语义合并）。
- (void)markRestorePendingIfFallback;

@end

NS_ASSUME_NONNULL_END
