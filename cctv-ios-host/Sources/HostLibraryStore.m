#import "HostLibraryStore.h"
#import "RuntimeDiagnostics.h"
#import <sqlite3.h>

NSString *const HostLibraryLegacyFavoritesKey = @"favorites";
NSString *const HostLibraryLegacyRecentsKey = @"recents";
NSString *const HostLibraryMigrationMarkerKey = @"cctv.libraryStore.migrated.v1";
NSString *const HostLibraryFallbackPendingKey = @"cctv.libraryStore.fallbackPending.v1";
NSString *const HostLibraryRestorePendingKey = @"cctv.libraryStore.restorePending.v1";
const NSUInteger HostLibraryRecentsLimit = 24;
const NSUInteger HostMediaWatchHistoryLimit = 100;
NSString *const HostLibraryStoreMediaHistoryWriteFailedNotification = @"cctv.libraryStore.mediaHistoryWriteFailed.v1";
static NSString *const HostMediaFavoritesKey = @"cctv.mediaFavorites.v1"; // mediaFavorites storage key
static NSString *const HostMediaHistoryKey = @"cctv.mediaWatchHistory.v1";
static NSString *const HostMediaFavoritesMarker = @"cctv.mediaFavoritesStore.migrated.v1";
static NSString *const HostMediaHistoryMarker = @"cctv.mediaHistoryStore.migrated.v1";

static char kHostLibraryQueueKey;

static NSArray<NSString *> *HostLibraryNormalizedFavorites(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:NSString.class] || ![(NSString *)item length]) continue;
        if ([seen containsObject:item]) continue;
        [seen addObject:item];
        [result addObject:item];
    }
    return result;
}

static NSString *HostLibraryRecentKey(id entry) {
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    id identifier = ((NSDictionary *)entry)[@"id"];
    if (![identifier isKindOfClass:NSString.class] || ![(NSString *)identifier length]) return nil;
    return identifier;
}

static NSData *HostLibraryJSONData(id object) {
    if (!object) return nil;
    if ([object isKindOfClass:NSString.class]) {
        return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:NULL];
    }
    if (![NSJSONSerialization isValidJSONObject:object]) return nil;
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

static NSArray<NSDictionary *> *HostLibraryNormalizedRecents(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (id item in (NSArray *)value) {
        NSString *key = HostLibraryRecentKey(item);
        if (!key.length || [seen containsObject:key]) continue;
        if (![NSJSONSerialization isValidJSONObject:item]) continue;
        [seen addObject:key];
        [result addObject:item];
    }
    return result;
}

static double HostLibraryWatchedAt(NSDictionary *entry) {
    id value = entry[@"watchedAt"];
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value doubleValue];
    return NSDate.date.timeIntervalSince1970;
}

// M12：回退层（NSUserDefaults）的行级历史合并：去掉同 key 与旧 key 的行，
// 新条目置顶并按 100 条上限裁剪；与 SQLite 事务内的 DELETE + INSERT + trim 同义。
static NSArray *HostLibraryHistoryRowsByUpserting(NSArray *rows, NSDictionary *entry, NSString *previousKey) {
    NSMutableArray *kept = [NSMutableArray array];
    NSString *key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : nil;
    for (id raw in rows ?: @[]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *rowKey = [raw[@"key"] isKindOfClass:NSString.class] ? raw[@"key"] : nil;
        if ([rowKey isEqualToString:key] || (previousKey.length && [rowKey isEqualToString:previousKey])) continue;
        [kept addObject:raw];
    }
    [kept insertObject:entry atIndex:0];
    while (kept.count > HostMediaWatchHistoryLimit) [kept removeLastObject];
    return kept;
}

@interface HostLibraryStore ()
@property (nonatomic, copy) NSString *databasePath;
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, assign) BOOL openAttempted;
// T19/PERF-10：读用不可变快照。快照只在串行队列上构建（与写同一队列），读到
// loadedSnapshotEpoch==snapshotEpoch 的线程直接取快照，不用 dispatch_sync 等
// SQLite 查询 + 全量 JSON 解析；写块开始先自增 epoch（脏标记），结束时刷新快照。
@property (atomic, strong) NSArray<NSString *> *snapshotFavorites;
@property (atomic, strong) NSArray<NSDictionary *> *snapshotRecents;
@property (atomic, strong) NSDictionary<NSString *, NSDictionary *> *snapshotMediaFavorites;
@property (atomic, strong) NSArray<NSDictionary *> *snapshotMediaHistory;
@property (atomic) NSUInteger snapshotEpoch;
@property (atomic) NSUInteger loadedSnapshotEpoch;
- (void)performSync:(dispatch_block_t)block;
- (void)performAsync:(dispatch_block_t)block;
- (void)performWrite:(dispatch_block_t)block;
- (void)refreshSnapshotsLocked;
- (NSArray<NSString *> *)favoritesLockedWithPrepared:(BOOL)prepared;
- (NSArray<NSDictionary *> *)recentsLockedWithPrepared:(BOOL)prepared;
- (NSDictionary<NSString *, NSDictionary *> *)mediaFavoritesLockedWithPrepared:(BOOL)prepared;
- (NSArray<NSDictionary *> *)mediaWatchHistoryLockedWithPrepared:(BOOL)prepared;
- (BOOL)execLocked:(const char *)sql;
- (void)closeLocked;
- (BOOL)prepareLocked;
- (BOOL)migrateFromDefaultsLocked;
- (BOOL)transactionLocked:(BOOL (^)(void))work;
- (BOOL)insertLocked:(const char *)sql key:(NSString *)key payload:(NSData *)payload time:(double)time position:(sqlite3_int64)position;
- (int)stepLocked:(const char *)sql text:(NSString *)text;
- (sqlite3_int64)int64Locked:(const char *)sql;
- (NSArray *)payloadsLocked:(const char *)sql;
- (BOOL)writeFavoritesLocked:(NSArray<NSString *> *)favorites;
- (BOOL)writeRecentsLocked:(NSArray<NSDictionary *> *)recents;
- (BOOL)writeMediaFavoritesLocked:(NSDictionary *)favorites;
- (BOOL)writeMediaHistoryLocked:(NSArray *)history;
- (BOOL)reconcileFallbackDataLocked;
- (BOOL)replaceFromDefaultsLocked;
@end

@implementation HostLibraryStore

+ (instancetype)shared {
    static HostLibraryStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        NSString *dir = [appSupport stringByAppendingPathComponent:@"HostLibrary"];
        instance = [[self alloc] initWithDatabasePath:[dir stringByAppendingPathComponent:@"library_v1.sqlite"]
                                             defaults:NSUserDefaults.standardUserDefaults];
    });
    return instance;
}

- (instancetype)initWithDatabasePath:(NSString *)databasePath defaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _databasePath = [databasePath copy];
        _defaults = defaults ?: NSUserDefaults.standardUserDefaults;
        _queue = dispatch_queue_create("com.cctvhost.library.sqlite", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, &kHostLibraryQueueKey, (__bridge void *)self, NULL);
        _loadedSnapshotEpoch = NSUIntegerMax; // 无快照：首次读走 performSync 构建
    }
    return self;
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

#pragma mark - Queue

- (void)performSync:(dispatch_block_t)block {
    if (dispatch_get_specific(&kHostLibraryQueueKey) == (__bridge void *)self) {
        block();
    } else {
        dispatch_sync(self.queue, block);
    }
}

- (void)performAsync:(dispatch_block_t)block {
    dispatch_async(self.queue, block);
}

- (void)flush {
    [self performSync:^{}];
}

/// 外部直接改了底层 NSUserDefaults 回退数据（如备份恢复的两面写）后调用：
/// 只自增 epoch 使快照失效，下次读重建；不碰队列、不读盘。
- (void)invalidateSnapshots {
    self.snapshotEpoch++;
}

- (void)performWrite:(dispatch_block_t)block {
    // T19/PERF-10：写块开始先自增 epoch（脏标记——块执行期间的读会走 performSync
    // 等本块完成，不会拿到写了一半的快照），结束时刷新快照再发布。
    [self performAsync:^{
        self.snapshotEpoch++;
        block();
        [self refreshSnapshotsLocked];
    }];
}

/// 只在串行队列上调用。按当前有效源（SQLite 优先，回退时 NSUserDefaults）
/// 重建四个集合的不可变快照；先发布集合，最后更新 loadedSnapshotEpoch。
- (void)refreshSnapshotsLocked {
    BOOL prepared = [self prepareLocked];
    self.snapshotFavorites = [self favoritesLockedWithPrepared:prepared];
    self.snapshotRecents = [self recentsLockedWithPrepared:prepared];
    self.snapshotMediaFavorites = [self mediaFavoritesLockedWithPrepared:prepared];
    self.snapshotMediaHistory = [self mediaWatchHistoryLockedWithPrepared:prepared];
    self.loadedSnapshotEpoch = self.snapshotEpoch;
}

- (NSArray<NSString *> *)favoritesLockedWithPrepared:(BOOL)prepared {
    if (prepared) {
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (id value in [self payloadsLocked:"SELECT payload FROM favorites ORDER BY position ASC;"]) {
            if ([value isKindOfClass:NSString.class]) [rows addObject:value];
        }
        return [rows copy];
    }
    return [self.defaults arrayForKey:HostLibraryLegacyFavoritesKey] ?: @[];
}

- (NSArray<NSDictionary *> *)recentsLockedWithPrepared:(BOOL)prepared {
    if (prepared) {
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
        for (id value in [self payloadsLocked:"SELECT payload FROM recents ORDER BY position ASC;"]) {
            if ([value isKindOfClass:NSDictionary.class]) [rows addObject:value];
        }
        return [rows copy];
    }
    return [self.defaults arrayForKey:HostLibraryLegacyRecentsKey] ?: @[];
}

- (NSDictionary<NSString *, NSDictionary *> *)mediaFavoritesLockedWithPrepared:(BOOL)prepared {
    if (!prepared) return [self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{};
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(self.db, "SELECT key,payload FROM media_favorites ORDER BY position ASC;", -1, &st, NULL) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const char *k = (const char *)sqlite3_column_text(st, 0);
            const void *b = sqlite3_column_blob(st, 1);
            int n = sqlite3_column_bytes(st, 1);
            if (k && b && n > 0) {
                NSString *key = [NSString stringWithUTF8String:k];
                id v = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:b length:(NSUInteger)n] options:NSJSONReadingFragmentsAllowed error:NULL];
                if (key && [v isKindOfClass:NSDictionary.class]) rows[key] = v;
            }
        }
    }
    if (st) sqlite3_finalize(st);
    return [rows copy];
}

- (NSArray<NSDictionary *> *)mediaWatchHistoryLockedWithPrepared:(BOOL)prepared {
    if (!prepared) return [self.defaults arrayForKey:HostMediaHistoryKey] ?: @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (id value in [self payloadsLocked:"SELECT payload FROM media_watch_history ORDER BY position ASC;"]) {
        if ([value isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *row = [value mutableCopy];
            if ([row[@"updatedAt"] isKindOfClass:NSNumber.class]) row[@"updatedAt"] = [NSDate dateWithTimeIntervalSince1970:[row[@"updatedAt"] doubleValue]];
            [rows addObject:row];
        }
    }
    return [rows copy];
}

#pragma mark - SQLite (queue only)

- (BOOL)execLocked:(const char *)sql {
    if (!self.db || !sql) return NO;
    char *err = NULL;
    int rc = sqlite3_exec(self.db, sql, NULL, NULL, &err);
    if (err) sqlite3_free(err);
    return rc == SQLITE_OK;
}

- (void)closeLocked {
    if (self.db) {
        sqlite3_close(self.db);
        self.db = NULL;
    }
}

/// 打开数据库、建表并在首次运行时迁移；返回 NO 表示回退到 NSUserDefaults。
- (BOOL)prepareLocked {
    if (self.db) return YES;
    if (self.openAttempted) return NO;
    self.openAttempted = YES;
    NSString *dir = self.databasePath.stringByDeletingLastPathComponent;
    if (dir.length) {
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    sqlite3 *handle = NULL;
    if (sqlite3_open_v2(self.databasePath.UTF8String, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (handle) sqlite3_close(handle);
        NSLog(@"[HostLibraryStore] sqlite open failed, fallback to NSUserDefaults");
        [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
        return NO;
    }
    self.db = handle;
    sqlite3_busy_timeout(self.db, 2000);
    [self execLocked:"PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"];
    BOOL created = [self execLocked:
        "CREATE TABLE IF NOT EXISTS favorites ("
        "  key TEXT PRIMARY KEY NOT NULL,"
        "  payload BLOB NOT NULL,"
        "  updated_at REAL NOT NULL,"
        "  position INTEGER NOT NULL DEFAULT 0"
        ");"
        "CREATE TABLE IF NOT EXISTS media_favorites (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0);"
        "CREATE TABLE IF NOT EXISTS media_watch_history (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, watched_at REAL NOT NULL, position INTEGER NOT NULL DEFAULT 0);"
        "CREATE TABLE IF NOT EXISTS recents ("
        "  key TEXT PRIMARY KEY NOT NULL,"
        "  payload BLOB NOT NULL,"
        "  watched_at REAL NOT NULL,"
        "  position INTEGER NOT NULL DEFAULT 0"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_favorites_position ON favorites(position);"
        "CREATE INDEX IF NOT EXISTS idx_recents_position ON recents(position);"];
    if (!created) {
        [self closeLocked];
        NSLog(@"[HostLibraryStore] schema creation failed, fallback to NSUserDefaults");
        [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
        return NO;
    }
    if (![self.defaults boolForKey:HostLibraryMigrationMarkerKey]) {
        if (![self migrateFromDefaultsLocked]) {
            [self closeLocked];
            NSLog(@"[HostLibraryStore] migration failed, fallback to NSUserDefaults");
            [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
            return NO;
        }
        [self.defaults setBool:YES forKey:HostLibraryMigrationMarkerKey];
    }
    if (![self.defaults boolForKey:HostMediaFavoritesMarker]) {
        NSDictionary *legacy=[self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{};
        if (![self transactionLocked:^BOOL{ return [self writeMediaFavoritesLocked:legacy]; }]) { [self closeLocked]; [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey]; return NO; }
        [self.defaults setBool:YES forKey:HostMediaFavoritesMarker];
    }
    if (![self.defaults boolForKey:HostMediaHistoryMarker]) {
        NSArray *legacy=[self.defaults arrayForKey:HostMediaHistoryKey] ?: @[];
        if (![self transactionLocked:^BOOL{ return [self writeMediaHistoryLocked:legacy]; }]) { [self closeLocked]; [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey]; return NO; }
        [self.defaults setBool:YES forKey:HostMediaHistoryMarker];
    }
    // SQLite 恢复后对账：合并 fallback 期间写入 NSUserDefaults 的数据，避免丢失。
    if ([self.defaults boolForKey:HostLibraryFallbackPendingKey]) {
        if ([self.defaults boolForKey:HostLibraryRestorePendingKey]) {
            if (![self replaceFromDefaultsLocked]) { [self closeLocked]; [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey]; return NO; }
            [self.defaults setBool:NO forKey:HostLibraryRestorePendingKey];
        } else {
            if (![self reconcileFallbackDataLocked]) { [self closeLocked]; [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey]; return NO; }
        }
        [self.defaults setBool:NO forKey:HostLibraryFallbackPendingKey];
    }
    return YES;
}

/// 一次性迁移：读取原 NSUserDefaults 键写入 SQLite；原键保留不删。
- (BOOL)migrateFromDefaultsLocked {
    NSArray<NSString *> *favorites = HostLibraryNormalizedFavorites([self.defaults objectForKey:HostLibraryLegacyFavoritesKey]);
    NSArray<NSDictionary *> *recents = HostLibraryNormalizedRecents([self.defaults objectForKey:HostLibraryLegacyRecentsKey]);
    return [self transactionLocked:^BOOL{
        return [self writeFavoritesLocked:favorites] && [self writeRecentsLocked:recents];
    }];
}

/// 备份恢复时 SQLite 不可用 → 用 NSUserDefaults 数据全量替换 SQLite（REPLACE 语义）。
- (BOOL)replaceFromDefaultsLocked {
    NSArray<NSString *> *favorites = HostLibraryNormalizedFavorites([self.defaults objectForKey:HostLibraryLegacyFavoritesKey]);
    NSArray<NSDictionary *> *recents = HostLibraryNormalizedRecents([self.defaults objectForKey:HostLibraryLegacyRecentsKey]);
    NSDictionary *mediaFav = [self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{};
    NSArray *mediaHist = [self.defaults arrayForKey:HostMediaHistoryKey] ?: @[];
    return [self transactionLocked:^BOOL{
        return [self writeFavoritesLocked:favorites] && [self writeRecentsLocked:recents]
            && [self writeMediaFavoritesLocked:mediaFav] && [self writeMediaHistoryLocked:mediaHist];
    }];
}

/// 对账合并：SQLite 恢复后将 fallback 期间写入 NSUserDefaults 的数据合并进 SQLite（MERGE 语义）。
/// 合并策略为并集——fallback 期间新增的条目追加到 SQLite，不丢弃 SQLite 中已有数据。
/// 幂等：重复执行结果相同（追加项已存在时跳过）。
- (BOOL)reconcileFallbackDataLocked {
    // 收藏：将 defaults 中有但 SQLite 没有的追加到末尾
    NSArray<NSString *> *defaultsFavorites = HostLibraryNormalizedFavorites([self.defaults objectForKey:HostLibraryLegacyFavoritesKey]);
    NSArray<NSString *> *sqliteFavorites = [self payloadsLocked:"SELECT payload FROM favorites ORDER BY position ASC;"];
    NSMutableSet<NSString *> *existingFav = [NSMutableSet set];
    for (id v in sqliteFavorites) { if ([v isKindOfClass:NSString.class]) [existingFav addObject:v]; }
    NSMutableArray<NSString *> *mergedFavorites = [NSMutableArray array];
    for (id v in sqliteFavorites) { if ([v isKindOfClass:NSString.class]) [mergedFavorites addObject:v]; }
    for (NSString *fav in defaultsFavorites) { if (![existingFav containsObject:fav]) [mergedFavorites addObject:fav]; }

    // 最近观看：按 id 合并，保留 watchedAt 更大者；按 watchedAt 降序排序后裁剪到上限
    NSMutableArray<NSDictionary *> *mergedRecents = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *recentById = [NSMutableDictionary dictionary];
    // SQLite 现有条目
    for (id v in [self payloadsLocked:"SELECT payload FROM recents ORDER BY position ASC;"]) {
        if (![v isKindOfClass:NSDictionary.class]) continue;
        NSString *key = HostLibraryRecentKey(v);
        if (!key.length) continue;
        recentById[key] = v;
    }
    // defaults 条目（fallback 期间的写入源）
    for (id v in HostLibraryNormalizedRecents([self.defaults objectForKey:HostLibraryLegacyRecentsKey])) {
        NSString *key = HostLibraryRecentKey(v);
        if (!key.length) continue;
        NSDictionary *existing = recentById[key];
        if (!existing || HostLibraryWatchedAt(v) > HostLibraryWatchedAt(existing)) recentById[key] = v;
    }
    NSMutableArray *allRecents = [recentById.allValues mutableCopy];
    [allRecents sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = HostLibraryWatchedAt(a), tb = HostLibraryWatchedAt(b);
        return tb < ta ? NSOrderedAscending : (tb > ta ? NSOrderedDescending : NSOrderedSame);
    }];
    for (NSUInteger i = 0; i < allRecents.count && i < HostLibraryRecentsLimit; i++) [mergedRecents addObject:allRecents[i]];

    // 点播收藏：defaults 中有但 SQLite 没有的 key 追加
    NSMutableDictionary *mergedMediaFav = [NSMutableDictionary dictionary];
    sqlite3_stmt *mf = NULL;
    if (sqlite3_prepare_v2(self.db, "SELECT key,payload FROM media_favorites ORDER BY position ASC;", -1, &mf, NULL) == SQLITE_OK) {
        while (sqlite3_step(mf) == SQLITE_ROW) {
            const char *k = (const char *)sqlite3_column_text(mf, 0);
            const void *b = sqlite3_column_blob(mf, 1); int n = sqlite3_column_bytes(mf, 1);
            if (k && b && n > 0) {
                NSString *key = [NSString stringWithUTF8String:k];
                id v = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:b length:(NSUInteger)n] options:NSJSONReadingFragmentsAllowed error:NULL];
                if (key && [v isKindOfClass:NSDictionary.class]) mergedMediaFav[key] = v;
            }
        }
    }
    if (mf) sqlite3_finalize(mf);
    NSDictionary *defaultsMediaFav = [self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{};
    for (NSString *key in defaultsMediaFav) {
        id v = defaultsMediaFav[key];
        if ([key isKindOfClass:NSString.class] && [v isKindOfClass:NSDictionary.class] && !mergedMediaFav[key]) mergedMediaFav[key] = v;
    }

    // 观看历史：按 key 合并，保留 watchedAt 更大者；裁剪到上限
    NSMutableDictionary<NSString *, NSDictionary *> *histByKey = [NSMutableDictionary dictionary];
    for (id v in [self payloadsLocked:"SELECT payload FROM media_watch_history ORDER BY position ASC;"]) {
        if (![v isKindOfClass:NSDictionary.class]) continue;
        NSString *key = [v[@"key"] isKindOfClass:NSString.class] ? v[@"key"] : nil;
        if (!key.length) continue;
        id date = v[@"updatedAt"]; double t = [date isKindOfClass:NSNumber.class] ? [date doubleValue] : 0;
        NSDictionary *existing = histByKey[key];
        if (!existing) { histByKey[key] = v; continue; }
        id ed = existing[@"updatedAt"]; double et = [ed isKindOfClass:NSNumber.class] ? [ed doubleValue] : 0;
        if (t > et) histByKey[key] = v;
    }
    for (id v in ([self.defaults arrayForKey:HostMediaHistoryKey] ?: @[])) {
        if (![v isKindOfClass:NSDictionary.class]) continue;
        NSString *key = [v[@"key"] isKindOfClass:NSString.class] ? v[@"key"] : nil;
        if (!key.length) continue;
        id date = v[@"updatedAt"]; double t = [date isKindOfClass:NSNumber.class] ? [date doubleValue] : 0;
        NSDictionary *existing = histByKey[key];
        if (!existing) { histByKey[key] = v; continue; }
        id ed = existing[@"updatedAt"]; double et = [ed isKindOfClass:NSNumber.class] ? [ed doubleValue] : 0;
        if (t > et) histByKey[key] = v;
    }
    NSMutableArray *allHist = [histByKey.allValues mutableCopy];
    [allHist sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ta = [a[@"updatedAt"] isKindOfClass:NSNumber.class] ? [a[@"updatedAt"] doubleValue] : 0;
        double tb = [b[@"updatedAt"] isKindOfClass:NSNumber.class] ? [b[@"updatedAt"] doubleValue] : 0;
        return tb < ta ? NSOrderedAscending : (tb > ta ? NSOrderedDescending : NSOrderedSame);
    }];
    NSMutableArray *mergedHist = [NSMutableArray array];
    for (NSUInteger i = 0; i < allHist.count && i < HostMediaWatchHistoryLimit; i++) [mergedHist addObject:allHist[i]];

    return [self transactionLocked:^BOOL{
        return [self writeFavoritesLocked:mergedFavorites] && [self writeRecentsLocked:mergedRecents]
            && [self writeMediaFavoritesLocked:mergedMediaFav] && [self writeMediaHistoryLocked:mergedHist];
    }];
}

- (BOOL)transactionLocked:(BOOL (^)(void))work {
    if (![self execLocked:"BEGIN IMMEDIATE;"]) return NO;
    BOOL ok = work();
    if (ok) ok = [self execLocked:"COMMIT;"];
    if (!ok) [self execLocked:"ROLLBACK;"];
    return ok;
}

- (BOOL)insertLocked:(const char *)sql key:(NSString *)key payload:(NSData *)payload time:(double)time position:(sqlite3_int64)position {
    if (!key.length || !payload.length) return NO;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        if (stmt) sqlite3_finalize(stmt);
        return NO;
    }
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_blob(stmt, 2, payload.bytes, (int)payload.length, SQLITE_TRANSIENT);
    sqlite3_bind_double(stmt, 3, time);
    sqlite3_bind_int64(stmt, 4, position);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

/// 执行带单个文本参数的语句，返回首次 step 的结果码。
- (int)stepLocked:(const char *)sql text:(NSString *)text {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        if (stmt) sqlite3_finalize(stmt);
        return SQLITE_ERROR;
    }
    sqlite3_bind_text(stmt, 1, (text ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc;
}

- (sqlite3_int64)int64Locked:(const char *)sql {
    sqlite3_stmt *stmt = NULL;
    sqlite3_int64 value = 0;
    if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        if (stmt) sqlite3_finalize(stmt);
        return 0;
    }
    if (sqlite3_step(stmt) == SQLITE_ROW) value = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return value;
}

- (NSArray *)payloadsLocked:(const char *)sql {
    NSMutableArray *rows = [NSMutableArray array];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        if (stmt) sqlite3_finalize(stmt);
        return rows;
    }
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const void *bytes = sqlite3_column_blob(stmt, 0);
        int length = sqlite3_column_bytes(stmt, 0);
        if (!bytes || length <= 0) continue;
        NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];
        if (value) [rows addObject:value];
    }
    sqlite3_finalize(stmt);
    return rows;
}

- (BOOL)writeFavoritesLocked:(NSArray<NSString *> *)favorites {
    if (![self execLocked:"DELETE FROM favorites;"]) return NO;
    double now = NSDate.date.timeIntervalSince1970;
    sqlite3_int64 position = 0;
    for (NSString *key in favorites) {
        NSData *payload = HostLibraryJSONData(key);
        if (!payload) continue;
        if (![self insertLocked:"INSERT OR REPLACE INTO favorites(key, payload, updated_at, position) VALUES(?, ?, ?, ?);"
                            key:key payload:payload time:now position:position]) return NO;
        position++;
    }
    return YES;
}

- (BOOL)writeRecentsLocked:(NSArray<NSDictionary *> *)recents {
    if (![self execLocked:"DELETE FROM recents;"]) return NO;
    sqlite3_int64 position = 0;
    for (NSDictionary *entry in recents) {
        NSString *key = HostLibraryRecentKey(entry);
        NSData *payload = HostLibraryJSONData(entry);
        if (!key.length || !payload) continue;
        if (![self insertLocked:"INSERT OR REPLACE INTO recents(key, payload, watched_at, position) VALUES(?, ?, ?, ?);"
                            key:key payload:payload time:HostLibraryWatchedAt(entry) position:position]) return NO;
        position++;
        if (position >= HostLibraryRecentsLimit) break;
    }
    return YES;
}

- (BOOL)writeMediaFavoritesLocked:(NSDictionary *)favorites {
    if (![self execLocked:"DELETE FROM media_favorites;"]) return NO;
    sqlite3_int64 pos=0; double now=NSDate.date.timeIntervalSince1970;
    for (id key in favorites) { id value=favorites[key]; if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSDictionary.class]) continue; NSData *payload=HostLibraryJSONData(value); if (!payload) continue; if (![self insertLocked:"INSERT OR REPLACE INTO media_favorites(key,payload,updated_at,position) VALUES(?,?,?,?);" key:key payload:payload time:now position:pos++]) return NO; }
    return YES;
}
- (BOOL)writeMediaHistoryLocked:(NSArray *)history {
    if (![self execLocked:"DELETE FROM media_watch_history;"]) return NO;
    sqlite3_int64 pos=0; NSMutableSet *seen=[NSMutableSet set];
    for (id raw in history) { if (![raw isKindOfClass:NSDictionary.class]) continue; NSDictionary *entry=raw; NSString *key=[entry[@"key"] isKindOfClass:NSString.class]?entry[@"key"]:nil; if (!key.length || [seen containsObject:key]) continue; [seen addObject:key]; NSMutableDictionary *serialized=[entry mutableCopy]; id date=serialized[@"updatedAt"]; if ([date isKindOfClass:NSDate.class]) serialized[@"updatedAt"]=@([date timeIntervalSince1970]); NSData *payload=HostLibraryJSONData(serialized); if (!payload) continue; double time=[entry[@"updatedAt"] isKindOfClass:NSDate.class]?[entry[@"updatedAt"] timeIntervalSince1970]:[entry[@"updatedAt"] doubleValue]; if (![self insertLocked:"INSERT OR REPLACE INTO media_watch_history(key,payload,watched_at,position) VALUES(?,?,?,?);" key:key payload:payload time:time position:pos++]) return NO; if (pos>=HostMediaWatchHistoryLimit) break; }
    return YES;
}

#pragma mark - Public

- (BOOL)usingDefaultsFallback {
    __block BOOL fallback = NO;
    [self performSync:^{
        fallback = ![self prepareLocked];
    }];
    return fallback;
}

- (void)markRestorePendingIfFallback {
    [self performSync:^{
        if (![self prepareLocked]) {
            [self.defaults setBool:YES forKey:HostLibraryRestorePendingKey];
            [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
        }
    }];
}

- (NSArray<NSString *> *)allFavorites {
    // T19/PERF-10：快照命中直接返回（可变副本，保持旧返回类型），不进队列等 SQLite
    // 查询 + 全量 JSON 解析。
    NSArray<NSString *> *snapshot = self.snapshotFavorites;
    if (snapshot && self.loadedSnapshotEpoch == self.snapshotEpoch) return [snapshot mutableCopy];
    __block NSArray<NSString *> *result = @[];
    CFTimeInterval rebuildStartedAt = CACurrentMediaTime();
    [self performSync:^{
        [self refreshSnapshotsLocked];
        result = self.snapshotFavorites ?: @[];
    }];
    if (RuntimeDiagnostics.shared.enabled) {
        [RuntimeDiagnostics.shared recordEvent:@"library_store_snapshot_rebuild" category:@"media_api" fields:@{@"collection":@"favorites",@"elapsed_ms":@((NSInteger)(MAX(0, CACurrentMediaTime() - rebuildStartedAt) * 1000))}];
    }
    return [result mutableCopy];
}

- (BOOL)isFavorite:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return NO;
    NSArray<NSString *> *snapshot = self.snapshotFavorites;
    if (snapshot && self.loadedSnapshotEpoch == self.snapshotEpoch) return [snapshot containsObject:key];
    __block BOOL found = NO;
    [self performSync:^{
        [self refreshSnapshotsLocked];
        found = [self.snapshotFavorites containsObject:key];
    }];
    return found;
}

- (void)addFavorite:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    NSString *favoriteKey = [key copy];
    [self performWrite:^{
        if ([self prepareLocked]) {
            if ([self stepLocked:"SELECT 1 FROM favorites WHERE key = ? LIMIT 1;" text:favoriteKey] == SQLITE_ROW) return;
            sqlite3_int64 position = [self int64Locked:"SELECT COALESCE(MAX(position), -1) + 1 FROM favorites;"];
            NSData *payload = HostLibraryJSONData(favoriteKey);
            [self insertLocked:"INSERT OR REPLACE INTO favorites(key, payload, updated_at, position) VALUES(?, ?, ?, ?);"
                           key:favoriteKey payload:payload time:NSDate.date.timeIntervalSince1970 position:position];
        } else {
            NSMutableArray *favorites = [[self.defaults arrayForKey:HostLibraryLegacyFavoritesKey] ?: @[] mutableCopy];
            if (![favorites containsObject:favoriteKey]) [favorites addObject:favoriteKey];
            [self.defaults setObject:favorites forKey:HostLibraryLegacyFavoritesKey];
        }
    }];
}

- (void)removeFavorite:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    NSString *favoriteKey = [key copy];
    [self performWrite:^{
        if ([self prepareLocked]) {
            [self stepLocked:"DELETE FROM favorites WHERE key = ?;" text:favoriteKey];
        } else {
            NSMutableArray *favorites = [[self.defaults arrayForKey:HostLibraryLegacyFavoritesKey] ?: @[] mutableCopy];
            [favorites removeObject:favoriteKey];
            [self.defaults setObject:favorites forKey:HostLibraryLegacyFavoritesKey];
        }
    }];
}

- (void)replaceFavorites:(NSArray *)favorites {
    NSArray *snapshot = [favorites isKindOfClass:NSArray.class] ? [favorites copy] : @[];
    [self performWrite:^{
        // 归一化（去重/过滤空串）在两层共用，确保 NSUserDefaults 回退镜像与 SQLite 一致，
        // 避免备份含重复收藏时回退层出现重复条目、与 SQLite 层分叉。
        NSArray<NSString *> *normalized = HostLibraryNormalizedFavorites(snapshot);
        if ([self prepareLocked]) {
            if (![self transactionLocked:^BOOL{
                return [self writeFavoritesLocked:normalized];
            }]) {
                [self closeLocked];
                [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
                [self.defaults setObject:normalized forKey:HostLibraryLegacyFavoritesKey];
            }
        } else {
            [self.defaults setObject:normalized forKey:HostLibraryLegacyFavoritesKey];
        }
    }];
}

- (NSArray<NSDictionary *> *)recents {
    NSArray<NSDictionary *> *snapshot = self.snapshotRecents;
    if (snapshot && self.loadedSnapshotEpoch == self.snapshotEpoch) return [snapshot mutableCopy];
    __block NSArray<NSDictionary *> *result = @[];
    [self performSync:^{
        [self refreshSnapshotsLocked];
        result = self.snapshotRecents ?: @[];
    }];
    return [result mutableCopy];
}

- (void)appendRecent:(NSDictionary *)entry {
    NSString *key = HostLibraryRecentKey(entry);
    if (!key.length) return;
    NSDictionary *snapshot = [entry copy];
    [self performWrite:^{
        if ([self prepareLocked]) {
            NSData *payload = HostLibraryJSONData(snapshot);
            if (!payload) return;
            NSString *trimSQL = [NSString stringWithFormat:@"DELETE FROM recents WHERE key NOT IN (SELECT key FROM recents ORDER BY position ASC LIMIT %lu);", (unsigned long)HostLibraryRecentsLimit];
            [self transactionLocked:^BOOL{
                [self stepLocked:"DELETE FROM recents WHERE key = ?;" text:key];
                sqlite3_int64 position = [self int64Locked:"SELECT COALESCE(MIN(position), 1) - 1 FROM recents;"];
                if (![self insertLocked:"INSERT OR REPLACE INTO recents(key, payload, watched_at, position) VALUES(?, ?, ?, ?);"
                                    key:key payload:payload time:HostLibraryWatchedAt(snapshot) position:position]) return NO;
                return [self execLocked:trimSQL.UTF8String];
            }];
        } else {
            NSMutableArray *merged = [NSMutableArray arrayWithObject:snapshot];
            for (id existing in [self.defaults arrayForKey:HostLibraryLegacyRecentsKey] ?: @[]) {
                if (![HostLibraryRecentKey(existing) isEqualToString:key] && merged.count < HostLibraryRecentsLimit) [merged addObject:existing];
            }
            [self.defaults setObject:merged forKey:HostLibraryLegacyRecentsKey];
        }
    }];
}

- (void)replaceRecents:(NSArray *)recents {
    NSArray *snapshot = [recents isKindOfClass:NSArray.class] ? [recents copy] : @[];
    [self performWrite:^{
        // 归一化（按 id 去重/过滤无 id 项/确保可序列化）在两层共用，确保 NSUserDefaults 回退镜像与 SQLite 一致，
        // 避免备份含无 id 或重复 id 条目时回退层保留无效/重复项、与 SQLite 层分叉导致再快照丢数据。
        NSArray<NSDictionary *> *normalized = HostLibraryNormalizedRecents(snapshot);
        // 与 replaceMediaWatchHistory 一致：按 Store 上限裁剪，确保备份恢复路径与 appendRecent /
        // reconcileFallbackDataLocked 的 24 条上限一致，避免超大导入在 SQLite 或回退镜像中残留超限条目。
        NSMutableArray<NSDictionary *> *bounded = [NSMutableArray array];
        for (NSUInteger i = 0; i < normalized.count && i < HostLibraryRecentsLimit; i++) [bounded addObject:normalized[i]];
        if ([self prepareLocked]) {
            if (![self transactionLocked:^BOOL{
                return [self writeRecentsLocked:bounded];
            }]) {
                [self closeLocked];
                [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
                [self.defaults setObject:bounded forKey:HostLibraryLegacyRecentsKey];
            }
        } else {
            [self.defaults setObject:bounded forKey:HostLibraryLegacyRecentsKey];
        }
    }];
}

- (void)clearRecents {
    [self replaceRecents:@[]];
}

- (NSDictionary<NSString *,NSDictionary *> *)mediaFavorites {
    NSDictionary *snapshot = self.snapshotMediaFavorites;
    if (snapshot && self.loadedSnapshotEpoch == self.snapshotEpoch) return [snapshot mutableCopy];
    __block NSDictionary *out = @{};
    [self performSync:^{
        [self refreshSnapshotsLocked];
        out = self.snapshotMediaFavorites ?: @{};
    }];
    return [out mutableCopy];
}
- (void)replaceMediaFavorites:(NSDictionary *)favorites { NSDictionary *copy=[favorites isKindOfClass:NSDictionary.class]?[favorites copy]:@{}; [self performWrite:^{ if([self prepareLocked]) { if(![self transactionLocked:^BOOL{return [self writeMediaFavoritesLocked:copy];}]){[self closeLocked];[self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];[self.defaults setObject:copy forKey:HostMediaFavoritesKey];} } else [self.defaults setObject:copy forKey:HostMediaFavoritesKey]; }]; }
- (NSArray<NSDictionary *> *)mediaWatchHistory {
    NSArray *snapshot = self.snapshotMediaHistory;
    if (snapshot && self.loadedSnapshotEpoch == self.snapshotEpoch) return [snapshot mutableCopy];
    __block NSArray *out = @[];
    [self performSync:^{
        [self refreshSnapshotsLocked];
        out = self.snapshotMediaHistory ?: @[];
    }];
    return [out mutableCopy];
}
- (void)replaceMediaWatchHistory:(NSArray *)history { NSArray *copy=[history isKindOfClass:NSArray.class]?[history copy]:@[]; [self performWrite:^{ NSMutableArray *(^boundedHistory)(void)=^NSMutableArray *{NSMutableArray *bounded=[NSMutableArray array]; NSMutableSet *seen=[NSMutableSet set]; for(id raw in copy){ if(![raw isKindOfClass:NSDictionary.class])continue; NSString *key=[raw[@"key"] isKindOfClass:NSString.class]?raw[@"key"]:nil; if(!key.length||[seen containsObject:key])continue; [seen addObject:key]; [bounded addObject:raw]; if(bounded.count>=HostMediaWatchHistoryLimit)break; } return bounded;}; if([self prepareLocked]) {if(![self transactionLocked:^BOOL{return [self writeMediaHistoryLocked:boundedHistory()];}]){[self closeLocked];[self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];[self.defaults setObject:boundedHistory() forKey:HostMediaHistoryKey];}} else [self.defaults setObject:boundedHistory() forKey:HostMediaHistoryKey]; }]; }
- (void)clearMediaWatchHistory { [self replaceMediaWatchHistory:@[]]; }
- (void)upsertMediaWatchHistoryEntry:(NSDictionary *)entry replacingKey:(NSString *)previousKey {
    if (![entry isKindOfClass:NSDictionary.class]) return;
    NSString *key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : nil;
    if (!key.length) return;
    NSDictionary *snapshot = [entry copy];
    NSString *previous = [previousKey isKindOfClass:NSString.class] ? [previousKey copy] : nil;
    if ([previous isEqualToString:key]) previous = nil;
    [self performWrite:^{
        NSMutableDictionary *serialized = [snapshot mutableCopy];
        id date = serialized[@"updatedAt"];
        double time = [date isKindOfClass:NSDate.class] ? [date timeIntervalSince1970] : [date doubleValue];
        if ([date isKindOfClass:NSDate.class]) serialized[@"updatedAt"] = @(time);
        NSData *payload = HostLibraryJSONData(serialized);
        if (!payload) return;
        if ([self prepareLocked]) {
            NSString *trimSQL = [NSString stringWithFormat:@"DELETE FROM media_watch_history WHERE key NOT IN (SELECT key FROM media_watch_history ORDER BY position ASC LIMIT %lu);", (unsigned long)HostMediaWatchHistoryLimit];
            BOOL ok = [self transactionLocked:^BOOL{
                if (previous.length) [self stepLocked:"DELETE FROM media_watch_history WHERE key = ?;" text:previous];
                [self stepLocked:"DELETE FROM media_watch_history WHERE key = ?;" text:key];
                sqlite3_int64 position = [self int64Locked:"SELECT COALESCE(MIN(position), 1) - 1 FROM media_watch_history;"];
                if (![self insertLocked:"INSERT OR REPLACE INTO media_watch_history(key, payload, watched_at, position) VALUES(?, ?, ?, ?);" key:key payload:payload time:time position:position]) return NO;
                return [self execLocked:trimSQL.UTF8String];
            }];
            if (!ok) {
                [self closeLocked];
                [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
                [self.defaults setObject:HostLibraryHistoryRowsByUpserting([self.defaults arrayForKey:HostMediaHistoryKey], snapshot, previous) forKey:HostMediaHistoryKey];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter postNotificationName:HostLibraryStoreMediaHistoryWriteFailedNotification object:self];
                });
            }
        } else {
            [self.defaults setObject:HostLibraryHistoryRowsByUpserting([self.defaults arrayForKey:HostMediaHistoryKey], snapshot, previous) forKey:HostMediaHistoryKey];
        }
    }];
}
- (void)removeMediaWatchHistoryEntryWithKey:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    NSString *historyKey = [key copy];
    [self performWrite:^{
        if ([self prepareLocked]) {
            [self stepLocked:"DELETE FROM media_watch_history WHERE key = ?;" text:historyKey];
        } else {
            NSMutableArray *kept = [NSMutableArray array];
            for (id raw in [self.defaults arrayForKey:HostMediaHistoryKey] ?: @[]) {
                if (![raw isKindOfClass:NSDictionary.class]) { [kept addObject:raw]; continue; }
                if ([[raw[@"key"] description] isEqualToString:historyKey]) continue;
                [kept addObject:raw];
            }
            [self.defaults setObject:kept forKey:HostMediaHistoryKey];
        }
    }];
}
- (void)upsertMediaFavoriteWithKey:(NSString *)key payload:(NSDictionary *)payload {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    if (![payload isKindOfClass:NSDictionary.class]) return;
    NSString *favoriteKey = [key copy];
    NSDictionary *snapshot = [payload copy];
    [self performWrite:^{
        NSData *data = HostLibraryJSONData(snapshot);
        if (!data) return;
        if ([self prepareLocked]) {
            BOOL ok = [self transactionLocked:^BOOL{
                sqlite3_int64 position = [self int64Locked:"SELECT COALESCE(MAX(position), -1) + 1 FROM media_favorites;"];
                return [self insertLocked:"INSERT OR REPLACE INTO media_favorites(key, payload, updated_at, position) VALUES(?, ?, ?, ?);" key:favoriteKey payload:data time:NSDate.date.timeIntervalSince1970 position:position];
            }];
            if (!ok) {
                [self closeLocked];
                [self.defaults setBool:YES forKey:HostLibraryFallbackPendingKey];
                NSMutableDictionary *fallback = [[self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{} mutableCopy];
                fallback[favoriteKey] = snapshot;
                [self.defaults setObject:fallback forKey:HostMediaFavoritesKey];
            }
        } else {
            NSMutableDictionary *fallback = [[self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{} mutableCopy];
            fallback[favoriteKey] = snapshot;
            [self.defaults setObject:fallback forKey:HostMediaFavoritesKey];
        }
    }];
}
- (void)removeMediaFavoriteWithKey:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    NSString *favoriteKey = [key copy];
    [self performWrite:^{
        if ([self prepareLocked]) {
            [self stepLocked:"DELETE FROM media_favorites WHERE key = ?;" text:favoriteKey];
        } else {
            NSMutableDictionary *favorites = [[self.defaults dictionaryForKey:HostMediaFavoritesKey] ?: @{} mutableCopy];
            [favorites removeObjectForKey:favoriteKey];
            [self.defaults setObject:favorites forKey:HostMediaFavoritesKey];
        }
    }];
}

@end
