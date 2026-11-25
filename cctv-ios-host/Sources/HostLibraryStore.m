#import "HostLibraryStore.h"
#import <sqlite3.h>

NSString *const HostLibraryLegacyFavoritesKey = @"favorites";
NSString *const HostLibraryLegacyRecentsKey = @"recents";
NSString *const HostLibraryMigrationMarkerKey = @"cctv.libraryStore.migrated.v1";
const NSUInteger HostLibraryRecentsLimit = 24;

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

@interface HostLibraryStore ()
@property (nonatomic, copy) NSString *databasePath;
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) sqlite3 *db;
@property (nonatomic, assign) BOOL openAttempted;
- (void)performSync:(dispatch_block_t)block;
- (void)performAsync:(dispatch_block_t)block;
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
        return NO;
    }
    if (![self.defaults boolForKey:HostLibraryMigrationMarkerKey]) {
        if (![self migrateFromDefaultsLocked]) {
            [self closeLocked];
            NSLog(@"[HostLibraryStore] migration failed, fallback to NSUserDefaults");
            return NO;
        }
        [self.defaults setBool:YES forKey:HostLibraryMigrationMarkerKey];
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
    }
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

- (NSArray<NSString *> *)allFavorites {
    __block NSArray<NSString *> *result = @[];
    [self performSync:^{
        if ([self prepareLocked]) {
            NSMutableArray<NSString *> *rows = [NSMutableArray array];
            for (id value in [self payloadsLocked:"SELECT payload FROM favorites ORDER BY position ASC;"]) {
                if ([value isKindOfClass:NSString.class]) [rows addObject:value];
            }
            result = rows;
        } else {
            result = [self.defaults arrayForKey:HostLibraryLegacyFavoritesKey] ?: @[];
        }
    }];
    return result;
}

- (BOOL)isFavorite:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return NO;
    __block BOOL found = NO;
    [self performSync:^{
        if ([self prepareLocked]) {
            found = [self stepLocked:"SELECT 1 FROM favorites WHERE key = ? LIMIT 1;" text:key] == SQLITE_ROW;
        } else {
            found = [[self.defaults arrayForKey:HostLibraryLegacyFavoritesKey] containsObject:key];
        }
    }];
    return found;
}

- (void)addFavorite:(NSString *)key {
    if (![key isKindOfClass:NSString.class] || !key.length) return;
    NSString *favoriteKey = [key copy];
    [self performAsync:^{
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
    [self performAsync:^{
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
    [self performAsync:^{
        if ([self prepareLocked]) {
            NSArray<NSString *> *normalized = HostLibraryNormalizedFavorites(snapshot);
            [self transactionLocked:^BOOL{
                return [self writeFavoritesLocked:normalized];
            }];
        } else {
            [self.defaults setObject:snapshot forKey:HostLibraryLegacyFavoritesKey];
        }
    }];
}

- (NSArray<NSDictionary *> *)recents {
    __block NSArray<NSDictionary *> *result = @[];
    [self performSync:^{
        if ([self prepareLocked]) {
            NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
            for (id value in [self payloadsLocked:"SELECT payload FROM recents ORDER BY position ASC;"]) {
                if ([value isKindOfClass:NSDictionary.class]) [rows addObject:value];
            }
            result = rows;
        } else {
            result = [self.defaults arrayForKey:HostLibraryLegacyRecentsKey] ?: @[];
        }
    }];
    return result;
}

- (void)appendRecent:(NSDictionary *)entry {
    NSString *key = HostLibraryRecentKey(entry);
    if (!key.length) return;
    NSDictionary *snapshot = [entry copy];
    [self performAsync:^{
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
    [self performAsync:^{
        if ([self prepareLocked]) {
            NSArray<NSDictionary *> *normalized = HostLibraryNormalizedRecents(snapshot);
            [self transactionLocked:^BOOL{
                return [self writeRecentsLocked:normalized];
            }];
        } else {
            [self.defaults setObject:snapshot forKey:HostLibraryLegacyRecentsKey];
        }
    }];
}

- (void)clearRecents {
    [self replaceRecents:@[]];
}

@end
