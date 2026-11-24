#import "ChannelSQLiteIndex.h"
#import <sqlite3.h>

@interface ChannelSQLiteIndex ()
@property (nonatomic, copy) NSString *databasePath;
@property (nonatomic, strong) dispatch_queue_t dbQueue;
@property (nonatomic, assign) sqlite3 *db;
- (BOOL)openIfNeededLocked;
- (BOOL)execSQL:(const char *)sql;
@end

@implementation ChannelSQLiteIndex

+ (instancetype)shared {
    static ChannelSQLiteIndex *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        NSString *dir = [appSupport stringByAppendingPathComponent:@"ChannelIndex"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        instance = [[self alloc] initWithDatabasePath:[dir stringByAppendingPathComponent:@"channels_v1.sqlite"]];
    });
    return instance;
}

- (instancetype)initWithDatabasePath:(NSString *)databasePath {
    if ((self = [super init])) {
        _databasePath = [databasePath copy];
        _dbQueue = dispatch_queue_create("com.cctvhost.channel.sqlite", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (BOOL)execSQL:(const char *)sql {
    if (!self.db || !sql) return NO;
    char *err = NULL;
    int rc = sqlite3_exec(self.db, sql, NULL, NULL, &err);
    if (err) sqlite3_free(err);
    return rc == SQLITE_OK;
}

- (BOOL)openIfNeededLocked {
    if (self.db) return YES;
    NSString *dir = self.databasePath.stringByDeletingLastPathComponent;
    if (dir.length) {
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    sqlite3 *handle = NULL;
    if (sqlite3_open_v2(self.databasePath.UTF8String, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (handle) sqlite3_close(handle);
        return NO;
    }
    self.db = handle;
    sqlite3_busy_timeout(self.db, 2000);
    [self execSQL:"PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;"];
    [self execSQL:
        "CREATE TABLE IF NOT EXISTS channels ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  source_id TEXT NOT NULL,"
        "  name TEXT NOT NULL,"
        "  group_name TEXT NOT NULL DEFAULT '',"
        "  url TEXT NOT NULL,"
        "  logo TEXT NOT NULL DEFAULT '',"
        "  tvg_id TEXT NOT NULL DEFAULT ''"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_channels_source ON channels(source_id);"
        "CREATE VIRTUAL TABLE IF NOT EXISTS channels_fts USING fts5("
        "  name, group_name, source_id, content='channels', content_rowid='id'"
        ");"
        "CREATE TRIGGER IF NOT EXISTS channels_ai AFTER INSERT ON channels BEGIN "
        "  INSERT INTO channels_fts(rowid, name, group_name, source_id) VALUES (new.id, new.name, new.group_name, new.source_id);"
        "END;"
        "CREATE TRIGGER IF NOT EXISTS channels_ad AFTER DELETE ON channels BEGIN "
        "  INSERT INTO channels_fts(channels_fts, rowid, name, group_name, source_id) VALUES('delete', old.id, old.name, old.group_name, old.source_id);"
        "END;"
        "CREATE TABLE IF NOT EXISTS epg_programs ("
        "  channel_key TEXT NOT NULL,"
        "  title TEXT NOT NULL,"
        "  start_ts REAL NOT NULL,"
        "  end_ts REAL NOT NULL"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_epg_channel_time ON epg_programs(channel_key, start_ts, end_ts);"
    ];
    return YES;
}

- (BOOL)replaceChannels:(NSArray<NSDictionary *> *)channels forSourceID:(NSString *)sourceID {
    NSString *src = sourceID ?: @"default";
    NSArray<NSDictionary *> *snapshot = channels ? [channels copy] : @[];
    __block BOOL ok = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openIfNeededLocked]) return;
        if (![self execSQL:"BEGIN IMMEDIATE;"]) return;
        sqlite3_stmt *delStmt = NULL;
        if (sqlite3_prepare_v2(self.db, "DELETE FROM channels WHERE source_id = ?;", -1, &delStmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(delStmt, 1, src.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(delStmt);
            sqlite3_finalize(delStmt);
        }
        sqlite3_stmt *insStmt = NULL;
        const char *insSQL = "INSERT INTO channels(source_id, name, group_name, url, logo, tvg_id) VALUES(?, ?, ?, ?, ?, ?);";
        if (sqlite3_prepare_v2(self.db, insSQL, -1, &insStmt, NULL) == SQLITE_OK) {
            for (NSDictionary *ch in snapshot) {
                if (![ch isKindOfClass:NSDictionary.class]) continue;
                NSString *name = [ch[@"name"] isKindOfClass:NSString.class] ? ch[@"name"] : @"";
                NSString *url = [ch[@"url"] isKindOfClass:NSString.class] ? ch[@"url"] : @"";
                if (!name.length || !url.length) continue;
                NSString *group = [ch[@"group"] isKindOfClass:NSString.class] ? ch[@"group"] : @"";
                NSString *logo = [ch[@"logo"] isKindOfClass:NSString.class] ? ch[@"logo"] : @"";
                NSString *tvgId = [ch[@"tvgId"] isKindOfClass:NSString.class] ? ch[@"tvgId"] : @"";
                sqlite3_reset(insStmt);
                sqlite3_clear_bindings(insStmt);
                sqlite3_bind_text(insStmt, 1, src.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(insStmt, 2, name.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(insStmt, 3, group.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(insStmt, 4, url.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(insStmt, 5, logo.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(insStmt, 6, tvgId.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_step(insStmt);
            }
            sqlite3_finalize(insStmt);
            ok = [self execSQL:"COMMIT;"];
        } else {
            [self execSQL:"ROLLBACK;"];
        }
    });
    return ok;
}

- (NSArray<NSDictionary *> *)searchChannelsWithQuery:(NSString *)query
                                            sourceID:(NSString *)sourceID
                                               limit:(NSUInteger)limit {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!trimmed.length) return @[];
    NSUInteger cappedLimit = limit > 0 ? MIN(limit, 500) : 100;
    __block NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openIfNeededLocked]) return;
        NSString *escaped = [[trimmed stringByReplacingOccurrencesOfString:@"\"" withString:@""] stringByAppendingString:@"*"];
        const char *sql = sourceID.length
            ? "SELECT c.source_id, c.name, c.group_name, c.url, c.logo, c.tvg_id "
              "FROM channels_fts f JOIN channels c ON c.id = f.rowid "
              "WHERE channels_fts MATCH ? AND c.source_id = ? LIMIT ?;"
            : "SELECT c.source_id, c.name, c.group_name, c.url, c.logo, c.tvg_id "
              "FROM channels_fts f JOIN channels c ON c.id = f.rowid "
              "WHERE channels_fts MATCH ? LIMIT ?;";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, escaped.UTF8String, -1, SQLITE_TRANSIENT);
            if (sourceID.length) {
                sqlite3_bind_text(stmt, 2, sourceID.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int(stmt, 3, (int)cappedLimit);
            } else {
                sqlite3_bind_int(stmt, 2, (int)cappedLimit);
            }
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *s0 = sqlite3_column_text(stmt, 0);
                const unsigned char *s1 = sqlite3_column_text(stmt, 1);
                const unsigned char *s2 = sqlite3_column_text(stmt, 2);
                const unsigned char *s3 = sqlite3_column_text(stmt, 3);
                const unsigned char *s4 = sqlite3_column_text(stmt, 4);
                const unsigned char *s5 = sqlite3_column_text(stmt, 5);
                [results addObject:@{
                    @"sourceId": s0 ? [NSString stringWithUTF8String:(const char *)s0] : @"",
                    @"name": s1 ? [NSString stringWithUTF8String:(const char *)s1] : @"",
                    @"group": s2 ? [NSString stringWithUTF8String:(const char *)s2] : @"",
                    @"url": s3 ? [NSString stringWithUTF8String:(const char *)s3] : @"",
                    @"logo": s4 ? [NSString stringWithUTF8String:(const char *)s4] : @"",
                    @"tvgId": s5 ? [NSString stringWithUTF8String:(const char *)s5] : @"",
                }];
            }
            sqlite3_finalize(stmt);
        }
    });
    return results.copy;
}

- (NSUInteger)totalChannelCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.dbQueue, ^{
        if (![self openIfNeededLocked]) return;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM channels;", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) count = (NSUInteger)sqlite3_column_int64(stmt, 0);
            sqlite3_finalize(stmt);
        }
    });
    return count;
}

- (BOOL)replacePrograms:(NSArray<NSDictionary *> *)programs forChannelKey:(NSString *)channelKey {
    if (!channelKey.length) return NO;
    NSArray<NSDictionary *> *snapshot = programs ? [programs copy] : @[];
    __block BOOL ok = NO;
    dispatch_sync(self.dbQueue, ^{
        if (![self openIfNeededLocked]) return;
        if (![self execSQL:"BEGIN IMMEDIATE;"]) return;
        sqlite3_stmt *delStmt = NULL;
        if (sqlite3_prepare_v2(self.db, "DELETE FROM epg_programs WHERE channel_key = ?;", -1, &delStmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(delStmt, 1, channelKey.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(delStmt);
            sqlite3_finalize(delStmt);
        }
        sqlite3_stmt *insStmt = NULL;
        if (sqlite3_prepare_v2(self.db, "INSERT INTO epg_programs(channel_key, title, start_ts, end_ts) VALUES(?, ?, ?, ?);", -1, &insStmt, NULL) == SQLITE_OK) {
            for (NSDictionary *prog in snapshot) {
                NSString *title = [prog[@"title"] isKindOfClass:NSString.class] ? prog[@"title"] : @"";
                double startTs = [prog[@"start"] doubleValue];
                double endTs = [prog[@"end"] doubleValue];
                if (!title.length || endTs <= startTs) continue;
                sqlite3_reset(insStmt);
                sqlite3_clear_bindings(insStmt);
                sqlite3_bind_text(insStmt, 1, channelKey.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(insStmt, 2, title.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_double(insStmt, 3, startTs);
                sqlite3_bind_double(insStmt, 4, endTs);
                sqlite3_step(insStmt);
            }
            sqlite3_finalize(insStmt);
            ok = [self execSQL:"COMMIT;"];
        } else {
            [self execSQL:"ROLLBACK;"];
        }
    });
    return ok;
}

- (NSArray<NSDictionary *> *)programsForChannelKey:(NSString *)channelKey
                                         fromEpoch:(NSTimeInterval)startEpoch
                                           toEpoch:(NSTimeInterval)endEpoch {
    if (!channelKey.length) return @[];
    __block NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    dispatch_sync(self.dbQueue, ^{
        if (![self openIfNeededLocked]) return;
        sqlite3_stmt *stmt = NULL;
        const char *sql = "SELECT title, start_ts, end_ts FROM epg_programs "
                          "WHERE channel_key = ? AND end_ts >= ? AND start_ts <= ? ORDER BY start_ts ASC;";
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, channelKey.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(stmt, 2, startEpoch);
            sqlite3_bind_double(stmt, 3, endEpoch);
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *t = sqlite3_column_text(stmt, 0);
                [rows addObject:@{
                    @"title": t ? [NSString stringWithUTF8String:(const char *)t] : @"",
                    @"start": @(sqlite3_column_double(stmt, 1)),
                    @"end": @(sqlite3_column_double(stmt, 2)),
                }];
            }
            sqlite3_finalize(stmt);
        }
    });
    return rows.copy;
}

- (void)close {
    if (!self.dbQueue) return;
    dispatch_sync(self.dbQueue, ^{
        if (self.db) {
            sqlite3_close(self.db);
            self.db = NULL;
        }
    });
}

@end
