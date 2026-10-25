#import "MediaPlaybackStateStore.h"
#import <math.h>

static NSString * const MediaWatchHistoryDefaultsKey = @"cctv.mediaWatchHistory.v1";
static NSString * const MediaSkipPointsDefaultsKey = @"cctv.mediaSkipPoints.v1";
static const NSUInteger MediaWatchHistoryLimit = 100;

static NSString *MediaPlaybackString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

static NSString *MediaPlaybackCompositeKey(NSArray<NSString *> *parts) {
    NSMutableString *key = [NSMutableString string];
    for (NSString *part in parts) [key appendFormat:@"%lu:%@", (unsigned long)part.length, part];
    return key;
}

static BOOL MediaPlaybackIsWebURL(NSString *value) {
    NSURLComponents *parts=[NSURLComponents componentsWithString:value?:@""];
    return [@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]&&parts.host.length>0;
}

static NSDictionary *MediaPlaybackComponents(NSDictionary *context, NSInteger lineIndex, NSInteger episodeIndex) {
    NSDictionary *source = [context[@"source"] isKindOfClass:NSDictionary.class] ? context[@"source"] : @{};
    NSDictionary *item = [context[@"item"] isKindOfClass:NSDictionary.class] ? context[@"item"] : @{};
    NSDictionary *detail = [context[@"detail"] isKindOfClass:NSDictionary.class] ? context[@"detail"] : @{};
    NSArray *lines = [detail[@"lines"] isKindOfClass:NSArray.class] ? detail[@"lines"] : @[];
    NSDictionary *line = lineIndex >= 0 && lineIndex < (NSInteger)lines.count && [lines[(NSUInteger)lineIndex] isKindOfClass:NSDictionary.class] ? lines[(NSUInteger)lineIndex] : @{};
    NSArray *episodes = [line[@"episodes"] isKindOfClass:NSArray.class] ? line[@"episodes"] : @[];
    NSDictionary *episode = episodeIndex >= 0 && episodeIndex < (NSInteger)episodes.count && [episodes[(NSUInteger)episodeIndex] isKindOfClass:NSDictionary.class] ? episodes[(NSUInteger)episodeIndex] : @{};
    NSString *sourceID = MediaPlaybackString(source[@"id"]);
    NSString *provider = MediaPlaybackString(context[@"provider"]);
    NSString *itemID = MediaPlaybackString(item[@"id"] ?: detail[@"id"]);
    NSString *lineID = MediaPlaybackString(line[@"id"]);
    NSString *episodeID = MediaPlaybackString(episode[@"id"]);
    // Some sources use the signed media URL itself as an episode ID. Never persist it.
    if (MediaPlaybackIsWebURL(lineID)) lineID=@"";
    if (MediaPlaybackIsWebURL(episodeID)) episodeID=@"";
    NSString *lineKey=lineID.length?lineID:[NSString stringWithFormat:@"index:%ld",(long)lineIndex];
    NSString *episodeKey=episodeID.length?episodeID:[NSString stringWithFormat:@"index:%ld",(long)episodeIndex];
    NSString *title = MediaPlaybackString(detail[@"name"] ?: item[@"name"]);
    NSString *episodeName = MediaPlaybackString(episode[@"name"]);
    if (!episodeName.length) episodeName = [NSString stringWithFormat:@"第 %ld 集", (long)episodeIndex + 1];
    NSString *poster = MediaPlaybackString(detail[@"poster"] ?: item[@"poster"]);
    NSDictionary *historyItem = @{@"id": itemID, @"name": title, @"poster": poster,
                                  @"remarks": MediaPlaybackString(item[@"remarks"])};
    return @{@"sourceID": sourceID, @"sourceName": MediaPlaybackString(source[@"name"]),
             @"provider": provider, @"itemID": itemID, @"lineID": lineID,
             @"episodeID": episodeID, @"episodeName": episodeName, @"lineName": MediaPlaybackString(line[@"name"]),
             @"item": historyItem, @"lineIndex": @(MAX(0, lineIndex)), @"episodeIndex": @(MAX(0, episodeIndex)),
             @"key": MediaPlaybackCompositeKey(@[sourceID, provider, itemID, lineKey, episodeKey]),
             @"seriesKey": MediaPlaybackCompositeKey(@[sourceID, provider, itemID])};
}

@implementation MediaPlaybackStateStore
+ (NSArray<NSDictionary *> *)watchHistory {
    id rows = [NSUserDefaults.standardUserDefaults objectForKey:MediaWatchHistoryDefaultsKey];
    if (![rows isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];BOOL migrated=NO;
    for (id row in (NSArray *)rows) {
        if (![row isKindOfClass:NSDictionary.class]||![row[@"item"] isKindOfClass:NSDictionary.class]||![row[@"sourceID"] isKindOfClass:NSString.class])continue;
        NSMutableDictionary *clean=[row mutableCopy];
        NSString *lineID=MediaPlaybackString(clean[@"lineID"]),*episodeID=MediaPlaybackString(clean[@"episodeID"]);
        if(MediaPlaybackIsWebURL(lineID)){clean[@"lineID"]=@"";lineID=@"";migrated=YES;}
        if(MediaPlaybackIsWebURL(episodeID)){clean[@"episodeID"]=@"";episodeID=@"";migrated=YES;}
        NSString *lineKey=lineID.length?lineID:[NSString stringWithFormat:@"index:%ld",(long)[clean[@"lineIndex"] integerValue]];
        NSString *episodeKey=episodeID.length?episodeID:[NSString stringWithFormat:@"index:%ld",(long)[clean[@"episodeIndex"] integerValue]];
        NSString *key=MediaPlaybackCompositeKey(@[MediaPlaybackString(clean[@"sourceID"]),MediaPlaybackString(clean[@"provider"]),MediaPlaybackString(clean[@"itemID"]),lineKey,episodeKey]);
        if(![clean[@"key"] isEqual:key]){clean[@"key"]=key;migrated=YES;}
        [valid addObject:clean];
    }
    if(migrated)[NSUserDefaults.standardUserDefaults setObject:valid forKey:MediaWatchHistoryDefaultsKey];
    return [valid sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *left = [a[@"updatedAt"] isKindOfClass:NSDate.class] ? a[@"updatedAt"] : NSDate.distantPast;
        NSDate *right = [b[@"updatedAt"] isKindOfClass:NSDate.class] ? b[@"updatedAt"] : NSDate.distantPast;
        return [right compare:left];
    }];
}
+ (NSDictionary *)historyEntryForContext:(NSDictionary *)context lineIndex:(NSInteger)lineIndex episodeIndex:(NSInteger)episodeIndex {
    NSString *key = MediaPlaybackComponents(context ?: @{}, lineIndex, episodeIndex)[@"key"];
    for (NSDictionary *entry in self.watchHistory) if ([entry[@"key"] isEqual:key]) return entry;
    return nil;
}
+ (NSDictionary *)latestHistoryForSourceID:(NSString *)sourceID provider:(NSString *)provider itemID:(NSString *)itemID {
    for (NSDictionary *entry in self.watchHistory) {
        if ([entry[@"sourceID"] isEqual:sourceID ?: @""] && [entry[@"provider"] isEqual:provider ?: @""] && [entry[@"itemID"] isEqual:itemID ?: @""]) return entry;
    }
    return nil;
}
+ (void)recordContext:(NSDictionary *)context lineIndex:(NSInteger)lineIndex episodeIndex:(NSInteger)episodeIndex position:(NSTimeInterval)position duration:(NSTimeInterval)duration completed:(BOOL)completed {
    NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, lineIndex, episodeIndex);
    if (![parts[@"sourceID"] length] || ![parts[@"itemID"] length] || ![parts[@"key"] length]) return;
    if (!isfinite(position) || position < 0) return;
    if (!isfinite(duration) || duration < 0) duration = 0;
    BOOL finished = completed || (duration > 0 && position >= duration - 2.0);
    NSMutableDictionary *entry = [parts mutableCopy];
    entry[@"position"] = @(finished ? duration : position);
    entry[@"duration"] = @(duration);
    entry[@"completed"] = @(finished);
    entry[@"updatedAt"] = NSDate.date;
    NSMutableArray *rows = [self.watchHistory mutableCopy];
    NSIndexSet *matches = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) { return [candidate[@"key"] isEqual:entry[@"key"]]; }];
    [rows removeObjectsAtIndexes:matches];
    [rows insertObject:entry atIndex:0];
    if (rows.count > MediaWatchHistoryLimit) [rows removeObjectsInRange:NSMakeRange(MediaWatchHistoryLimit, rows.count - MediaWatchHistoryLimit)];
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:MediaWatchHistoryDefaultsKey];
}
+ (void)removeHistoryEntryWithKey:(NSString *)key {
    if (!key.length) return;
    NSMutableArray *rows = [self.watchHistory mutableCopy];
    NSIndexSet *matches = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) { return [entry[@"key"] isEqual:key]; }];
    [rows removeObjectsAtIndexes:matches];
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:MediaWatchHistoryDefaultsKey];
}
+ (void)clearWatchHistory { [NSUserDefaults.standardUserDefaults removeObjectForKey:MediaWatchHistoryDefaultsKey]; }
+ (NSDictionary *)skipPointsForContext:(NSDictionary *)context {
    NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, 0, 0);
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSkipPointsDefaultsKey][parts[@"seriesKey"]] ?: @{};
}
+ (NSTimeInterval)introEndForContext:(NSDictionary *)context { id value=[self skipPointsForContext:context][@"introEnd"];return [value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:0; }
+ (NSTimeInterval)outroSkipForContext:(NSDictionary *)context { id value=[self skipPointsForContext:context][@"outroSkip"];return [value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:0; }
+ (void)setSkipValue:(NSTimeInterval)value key:(NSString *)key context:(NSDictionary *)context {
    NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, 0, 0);
    NSString *seriesKey = parts[@"seriesKey"];
    if (![parts[@"sourceID"] length] || ![parts[@"itemID"] length] || !seriesKey.length) return;
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSkipPointsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = [all[seriesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value > 0) entry[key] = @(MIN(value, 3600.0)); else [entry removeObjectForKey:key];
    if (entry.count) all[seriesKey] = entry; else [all removeObjectForKey:seriesKey];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:MediaSkipPointsDefaultsKey];
}
+ (void)setIntroEnd:(NSTimeInterval)seconds forContext:(NSDictionary *)context { [self setSkipValue:seconds key:@"introEnd" context:context]; }
+ (void)setOutroSkip:(NSTimeInterval)seconds forContext:(NSDictionary *)context { [self setSkipValue:seconds key:@"outroSkip" context:context]; }
+ (void)clearSkipPointsForContext:(NSDictionary *)context {
    NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, 0, 0);
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSkipPointsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    [all removeObjectForKey:parts[@"seriesKey"]];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:MediaSkipPointsDefaultsKey];
}
@end
