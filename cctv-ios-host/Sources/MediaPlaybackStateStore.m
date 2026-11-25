#import "MediaPlaybackStateStore.h"
#import "HostLibraryStore.h"
#import <math.h>

static NSString * const MediaWatchHistoryDefaultsKey = @"cctv.mediaWatchHistory.v1";
static NSString * const MediaSkipPointsDefaultsKey = @"cctv.mediaSkipPoints.v1";

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

// Never use signed URLs or array positions as durable identities. A name is
// usable only if it uniquely identifies the entry within the current list.
static NSString *MediaPlaybackNameKey(NSDictionary *entry, NSArray *siblings) {
    NSString *name=[[MediaPlaybackString(entry[@"name"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if(!name.length)return @"";
    NSUInteger matches=0;
    for(id raw in siblings){
        if(![raw isKindOfClass:NSDictionary.class])continue;
        NSString *other=[[MediaPlaybackString(raw[@"name"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if([other isEqual:name])matches++;
    }
    return matches==1?[@"name:" stringByAppendingString:name]:@"";
}

static NSString *MediaPlaybackStableKey(NSDictionary *entry, NSArray *siblings) {
    NSString *identifier=MediaPlaybackString(entry[@"id"]);
    if(identifier.length&&!MediaPlaybackIsWebURL(identifier)){
        NSUInteger matches=0;
        for(id raw in siblings)if([raw isKindOfClass:NSDictionary.class]&&[MediaPlaybackString(raw[@"id"]) isEqual:identifier])matches++;
        if(matches==1)return [@"id:" stringByAppendingString:identifier];
    }
    return MediaPlaybackNameKey(entry,siblings);
}

static BOOL MediaPlaybackSavedIdentityMatches(NSString *stable, NSString *nameKey, NSString *savedID, NSString *savedName) {
    if([stable hasPrefix:@"id:"]&&savedID.length&&[[stable substringFromIndex:3] isEqual:savedID])return YES;
    NSString *name=[[savedName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return name.length&&[nameKey hasPrefix:@"name:"]&&[[nameKey substringFromIndex:5] isEqual:name];
}

static NSDictionary *MediaPlaybackComponents(NSDictionary *context, NSInteger lineIndex, NSInteger episodeIndex) {
    NSDictionary *source = [context[@"source"] isKindOfClass:NSDictionary.class] ? context[@"source"] : @{};
    NSDictionary *item = [context[@"item"] isKindOfClass:NSDictionary.class] ? context[@"item"] : @{};
    NSDictionary *detail = [context[@"detail"] isKindOfClass:NSDictionary.class] ? context[@"detail"] : @{};
    NSArray *seasons=[detail[@"seasons"] isKindOfClass:NSArray.class]?detail[@"seasons"]:@[];
    NSInteger seasonIndex=[context[@"seasonIndex"] isKindOfClass:NSNumber.class]?[context[@"seasonIndex"] integerValue]:-1;
    NSDictionary *season=seasonIndex>=0&&seasonIndex<seasons.count&&[seasons[(NSUInteger)seasonIndex] isKindOfClass:NSDictionary.class]?seasons[(NSUInteger)seasonIndex]:@{};
    NSArray *seasonLines=[season[@"lines"] isKindOfClass:NSArray.class]?season[@"lines"]:@[];
    NSString *seasonID=MediaPlaybackString(season[@"id"]);
    if(MediaPlaybackIsWebURL(seasonID))seasonID=@"";
    NSString *seasonKey=MediaPlaybackStableKey(season,seasons);
    NSArray *lines = [detail[@"lines"] isKindOfClass:NSArray.class] ? detail[@"lines"] : @[];
    if(seasonLines.count)lines=seasonLines;
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
    NSString *lineKey=MediaPlaybackStableKey(line,lines);
    NSString *episodeKey=MediaPlaybackStableKey(episode,episodes);
    BOOL identityReliable=lineKey.length&&episodeKey.length&&(!season.count||seasonKey.length);
    // A unique per-position key still permits display of ambiguous history, but
    // historyEntryForContext will never apply it as a resume position.
    NSString *storedLineKey=lineKey.length?lineKey:[NSString stringWithFormat:@"index:%ld",(long)lineIndex];
    NSString *storedEpisodeKey=episodeKey.length?episodeKey:[NSString stringWithFormat:@"index:%ld",(long)episodeIndex];
    NSString *storedSeasonKey=seasonKey.length?seasonKey:[NSString stringWithFormat:@"index:%ld",(long)seasonIndex];
    NSString *title = MediaPlaybackString(detail[@"name"] ?: item[@"name"]);
    NSString *episodeName = MediaPlaybackString(episode[@"name"]);
    if (!episodeName.length) episodeName = [NSString stringWithFormat:@"第 %ld 集", (long)episodeIndex + 1];
    NSString *poster = MediaPlaybackString(detail[@"poster"] ?: item[@"poster"]);
    NSDictionary *historyItem = @{@"id": itemID, @"name": title, @"poster": poster,
                                  @"remarks": MediaPlaybackString(item[@"remarks"])};
    return @{@"sourceID": sourceID, @"sourceName": MediaPlaybackString(source[@"name"]),
             @"provider": provider, @"itemID": itemID, @"lineID": lineID,
             @"episodeID": episodeID, @"episodeName": episodeName, @"episodeNameSynthetic":@(!MediaPlaybackString(episode[@"name"]).length), @"lineName": MediaPlaybackString(line[@"name"]),
             @"item": historyItem, @"lineIndex": @(MAX(0, lineIndex)), @"episodeIndex": @(MAX(0, episodeIndex)),
             @"seasonIndex":@(season.count?seasonIndex:-1), @"seasonID":seasonID, @"seasonName":MediaPlaybackString(season[@"name"]),
             @"lineStableKey":lineKey, @"episodeStableKey":episodeKey, @"seasonStableKey":seasonKey,
             @"lineNameKey":MediaPlaybackNameKey(line,lines), @"episodeNameKey":MediaPlaybackNameKey(episode,episodes),
             @"seasonNameKey":MediaPlaybackNameKey(season,seasons), @"identityReliable":@(identityReliable),
             @"key": MediaPlaybackCompositeKey(season.count?@[sourceID, provider, itemID, storedSeasonKey, storedLineKey, storedEpisodeKey]:@[sourceID, provider, itemID, storedLineKey, storedEpisodeKey]),
             @"seriesKey": MediaPlaybackCompositeKey(@[sourceID, provider, itemID])};
}

@implementation MediaPlaybackStateStore
+ (NSArray<NSDictionary *> *)watchHistory {
    @synchronized(self){
    id rows = [HostLibraryStore.shared mediaWatchHistory];
    if (![rows isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];BOOL migrated=NO;
    for (id row in (NSArray *)rows) {
        if (![row isKindOfClass:NSDictionary.class]||![row[@"item"] isKindOfClass:NSDictionary.class]||![row[@"sourceID"] isKindOfClass:NSString.class])continue;
        NSMutableDictionary *clean=[row mutableCopy];
        NSString *lineID=MediaPlaybackString(clean[@"lineID"]),*episodeID=MediaPlaybackString(clean[@"episodeID"]);
        if(MediaPlaybackIsWebURL(lineID)){clean[@"lineID"]=@"";lineID=@"";migrated=YES;}
        if(MediaPlaybackIsWebURL(episodeID)){clean[@"episodeID"]=@"";episodeID=@"";migrated=YES;}
        NSString *lineKey=MediaPlaybackString(clean[@"lineStableKey"]);
        NSString *episodeKey=MediaPlaybackString(clean[@"episodeStableKey"]);
        if(!lineKey.length)lineKey=lineID.length?lineID:[NSString stringWithFormat:@"index:%ld",(long)[clean[@"lineIndex"] integerValue]];
        if(!episodeKey.length)episodeKey=episodeID.length?episodeID:[NSString stringWithFormat:@"index:%ld",(long)[clean[@"episodeIndex"] integerValue]];
        NSMutableArray *parts=[NSMutableArray arrayWithArray:@[MediaPlaybackString(clean[@"sourceID"]),MediaPlaybackString(clean[@"provider"]),MediaPlaybackString(clean[@"itemID"])]];
        NSNumber *seasonIndex=[clean[@"seasonIndex"] isKindOfClass:NSNumber.class]?clean[@"seasonIndex"]:nil;
        NSString *seasonID=MediaPlaybackString(clean[@"seasonID"]);
        if(seasonID.length||(seasonIndex&&seasonIndex.integerValue>=0)){
            NSString *seasonKey=MediaPlaybackString(clean[@"seasonStableKey"]);
            [parts addObject:seasonKey.length?seasonKey:(seasonID.length?seasonID:[NSString stringWithFormat:@"index:%ld",(long)seasonIndex.integerValue])];
        }
        [parts addObjectsFromArray:@[lineKey,episodeKey]];
        NSString *key=MediaPlaybackCompositeKey(parts);
        if(![clean[@"key"] isEqual:key]){clean[@"key"]=key;migrated=YES;}
        [valid addObject:clean];
    }
    if(migrated)[HostLibraryStore.shared replaceMediaWatchHistory:valid];
    return [valid sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *left = [a[@"updatedAt"] isKindOfClass:NSDate.class] ? a[@"updatedAt"] : NSDate.distantPast;
        NSDate *right = [b[@"updatedAt"] isKindOfClass:NSDate.class] ? b[@"updatedAt"] : NSDate.distantPast;
        return [right compare:left];
    }];

    }
}
+ (NSDictionary *)historyEntryForContext:(NSDictionary *)context lineIndex:(NSInteger)lineIndex episodeIndex:(NSInteger)episodeIndex {
    @synchronized(self){
        NSDictionary *parts=MediaPlaybackComponents(context ?: @{}, lineIndex, episodeIndex);
        if(![parts[@"identityReliable"] boolValue])return nil;
        for (NSDictionary *entry in self.watchHistory) {
            if(![entry[@"sourceID"] isEqual:parts[@"sourceID"]]||![entry[@"provider"] isEqual:parts[@"provider"]]||![entry[@"itemID"] isEqual:parts[@"itemID"]])continue;
            if(!MediaPlaybackSavedIdentityMatches(parts[@"lineStableKey"],parts[@"lineNameKey"],MediaPlaybackString(entry[@"lineID"]),MediaPlaybackString(entry[@"lineName"])))continue;
            NSString *savedEpisodeID=MediaPlaybackString(entry[@"episodeID"]);
            NSString *savedEpisodeName=MediaPlaybackString(entry[@"episodeName"]);
            BOOL synthetic=[entry[@"episodeNameSynthetic"] boolValue];
            if(!entry[@"episodeNameSynthetic"]&&!savedEpisodeID.length){
                NSString *legacyFallback=[NSString stringWithFormat:@"第 %ld 集",(long)[entry[@"episodeIndex"] integerValue]+1];
                synthetic=[savedEpisodeName isEqual:legacyFallback];
            }
            if(synthetic&&!savedEpisodeID.length)continue;
            if(!MediaPlaybackSavedIdentityMatches(parts[@"episodeStableKey"],parts[@"episodeNameKey"],savedEpisodeID,savedEpisodeName))continue;
            BOOL hasSeason=[parts[@"seasonIndex"] integerValue]>=0;
            BOOL savedSeason=[entry[@"seasonIndex"] respondsToSelector:@selector(integerValue)]&&[entry[@"seasonIndex"] integerValue]>=0;
            if(hasSeason!=savedSeason)continue;
            if(hasSeason&&!MediaPlaybackSavedIdentityMatches(parts[@"seasonStableKey"],parts[@"seasonNameKey"],MediaPlaybackString(entry[@"seasonID"]),MediaPlaybackString(entry[@"seasonName"])))continue;
            return entry;
        }
        return nil;
    }
}
+ (NSDictionary *)latestHistoryForSourceID:(NSString *)sourceID provider:(NSString *)provider itemID:(NSString *)itemID {
    @synchronized(self){
        for (NSDictionary *entry in self.watchHistory) {
            if ([entry[@"sourceID"] isEqual:sourceID ?: @""] && [entry[@"provider"] isEqual:provider ?: @""] && [entry[@"itemID"] isEqual:itemID ?: @""]) return entry;
        }
        return nil;
    }
}
+ (void)recordContext:(NSDictionary *)context lineIndex:(NSInteger)lineIndex episodeIndex:(NSInteger)episodeIndex position:(NSTimeInterval)position duration:(NSTimeInterval)duration completed:(BOOL)completed {
    @synchronized(self){
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
    NSDictionary *previous=[self historyEntryForContext:context lineIndex:lineIndex episodeIndex:episodeIndex];
    NSMutableArray *rows = [self.watchHistory mutableCopy];
    NSIndexSet *matches = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
        return [candidate[@"key"] isEqual:entry[@"key"]]||(previous&&[candidate[@"key"] isEqual:previous[@"key"]]);
    }];
    [rows removeObjectsAtIndexes:matches];
    [rows insertObject:entry atIndex:0];
    if (rows.count > HostMediaWatchHistoryLimit) [rows removeObjectsInRange:NSMakeRange(HostMediaWatchHistoryLimit, rows.count - HostMediaWatchHistoryLimit)];
    [HostLibraryStore.shared replaceMediaWatchHistory:rows];

    }
}
+ (void)removeHistoryEntryWithKey:(NSString *)key {
    @synchronized(self){
    if (!key.length) return;
    NSMutableArray *rows = [self.watchHistory mutableCopy];
    NSIndexSet *matches = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) { return [entry[@"key"] isEqual:key]; }];
    [rows removeObjectsAtIndexes:matches];
    [HostLibraryStore.shared replaceMediaWatchHistory:rows];

    }
}
+ (void)clearWatchHistory {
    @synchronized(self){ [HostLibraryStore.shared clearMediaWatchHistory];
    }
}
+ (NSDictionary *)skipPointsForContext:(NSDictionary *)context {
    @synchronized(self){
        NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, 0, 0);
        return [NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSkipPointsDefaultsKey][parts[@"seriesKey"]] ?: @{};
    }
}
+ (NSTimeInterval)introEndForContext:(NSDictionary *)context { id value=[self skipPointsForContext:context][@"introEnd"];return [value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:0; }
+ (NSTimeInterval)outroSkipForContext:(NSDictionary *)context { id value=[self skipPointsForContext:context][@"outroSkip"];return [value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:0; }
+ (void)setSkipValue:(NSTimeInterval)value key:(NSString *)key context:(NSDictionary *)context {
    @synchronized(self){
    NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, 0, 0);
    NSString *seriesKey = parts[@"seriesKey"];
    if (![parts[@"sourceID"] length] || ![parts[@"itemID"] length] || !seriesKey.length) return;
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSkipPointsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *entry = [all[seriesKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value > 0) entry[key] = @(MIN(value, 3600.0)); else [entry removeObjectForKey:key];
    if (entry.count) all[seriesKey] = entry; else [all removeObjectForKey:seriesKey];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:MediaSkipPointsDefaultsKey];

    }
}
+ (void)setIntroEnd:(NSTimeInterval)seconds forContext:(NSDictionary *)context { [self setSkipValue:seconds key:@"introEnd" context:context]; }
+ (void)setOutroSkip:(NSTimeInterval)seconds forContext:(NSDictionary *)context { [self setSkipValue:seconds key:@"outroSkip" context:context]; }
+ (void)clearSkipPointsForContext:(NSDictionary *)context {
    @synchronized(self){
    NSDictionary *parts = MediaPlaybackComponents(context ?: @{}, 0, 0);
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:MediaSkipPointsDefaultsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    [all removeObjectForKey:parts[@"seriesKey"]];
    [NSUserDefaults.standardUserDefaults setObject:all forKey:MediaSkipPointsDefaultsKey];

    }
}
@end
