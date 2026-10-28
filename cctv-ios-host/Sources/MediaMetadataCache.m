#import "MediaMetadataCache.h"
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger MediaMetadataCacheEntryLimit = 64;
static const NSUInteger MediaMetadataCacheByteLimit = 8 * 1024 * 1024;
static const NSUInteger MediaMetadataCacheSingleEntryLimit = 1024 * 1024;
static const NSUInteger MediaMetadataPersistentEntryLimit = 32;
static const NSUInteger MediaMetadataPersistentByteLimit = 4 * 1024 * 1024;
static const NSTimeInterval MediaMetadataFreshLifetime = 5 * 60;

static BOOL MediaMetadataKeyIsSensitive(NSString *key) {
    NSString *lower=key.lowercaseString;
    for(NSString *marker in @[@"token",@"cookie",@"authorization",@"signature",@"secret",@"credential",@"password",@"header",@"auth",@"play",@"stream",@"episode",@"mediaurl",@"media_url",@"m3u8",@"playlist",@"sourceurl",@"source_url",@"referer",@"url",@"link"])
        if([lower containsString:marker])return YES;
    return NO;
}
static BOOL MediaMetadataKeyIsPublicImage(NSString *key) {
    NSString *lower=key.lowercaseString;
    for(NSString *marker in @[@"poster",@"pic",@"image",@"thumb",@"banner",@"logo",@"avatar"])
        if([lower containsString:marker])return YES;
    return NO;
}
static id MediaMetadataPersistentSafeValue(id value, NSString *key, NSUInteger depth) {
    if(!value||depth>24||(MediaMetadataKeyIsSensitive(key?:@"")&&!MediaMetadataKeyIsPublicImage(key?:@"")))return nil;
    if([value isKindOfClass:NSDictionary.class]){
        NSMutableDictionary *safe=[NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id childKey,id child,BOOL *stop){
            if(![childKey isKindOfClass:NSString.class])return;
            id converted=MediaMetadataPersistentSafeValue(child,childKey,depth+1);
            if(converted)safe[childKey]=converted;
        }];
        return safe;
    }
    if([value isKindOfClass:NSArray.class]){
        NSMutableArray *safe=[NSMutableArray array];
        for(id child in (NSArray *)value){id converted=MediaMetadataPersistentSafeValue(child,key,depth+1);if(converted)[safe addObject:converted];}
        return safe;
    }
    if([value isKindOfClass:NSString.class]){
        NSString *string=(NSString *)value;
        NSURLComponents *components=[NSURLComponents componentsWithString:string];
        BOOL absoluteURL=([components.scheme.lowercaseString isEqual:@"http"]||[components.scheme.lowercaseString isEqual:@"https"])&&components.host.length;
        if(absoluteURL){
            if(!MediaMetadataKeyIsPublicImage(key?:@"")||components.user.length||components.password.length)return nil;
            for(NSURLQueryItem *item in components.queryItems){NSString *queryKey=item.name.lowercaseString;for(NSString *marker in @[@"token",@"sign",@"auth",@"key",@"secret",@"expire",@"credential",@"password"])if([queryKey containsString:marker])return nil;}
        }
        NSString *lower=string.lowercaseString;
        if([lower containsString:@".m3u8"]||[lower containsString:@".mp4"]||[lower containsString:@".mpd"])return nil;
        if(!MediaMetadataKeyIsPublicImage(key?:@"")&&([lower containsString:@"token="]||[lower containsString:@"signature="]||[lower containsString:@"sign="]))return nil;
        return string;
    }
    if([value isKindOfClass:NSNumber.class]||value==NSNull.null)return value;
    return nil;
}

@interface MediaMetadataCacheEntry : NSObject
@property(nonatomic, copy) id result;
@property(nonatomic, copy) NSString *sourceID;
@property(nonatomic) NSTimeInterval storedAt;
@property(nonatomic) NSUInteger cost;
@end
@implementation MediaMetadataCacheEntry
@end

@interface MediaMetadataCache ()
@property(nonatomic, strong) NSCache<NSString *, MediaMetadataCacheEntry *> *entries;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_queue_t persistenceQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *order;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *persistentRecords;
@property(nonatomic, copy) NSString *persistentPath;
@property(nonatomic) BOOL persistenceWriteScheduled;
@end

@implementation MediaMetadataCache
+ (instancetype)shared {
    static MediaMetadataCache *cache; static dispatch_once_t once;
    dispatch_once(&once, ^{ cache=[MediaMetadataCache new]; });
    return cache;
}
- (instancetype)init {
    if((self=[super init])) {
        _entries=[NSCache new]; _entries.countLimit=MediaMetadataCacheEntryLimit; _entries.totalCostLimit=MediaMetadataCacheByteLimit;
        _queue=dispatch_queue_create("com.cctvhost.media-metadata-cache", DISPATCH_QUEUE_SERIAL);
        _persistenceQueue=dispatch_queue_create("com.cctvhost.media-metadata-cache.persistence", DISPATCH_QUEUE_SERIAL);
        _order=[NSMutableDictionary dictionary];
        _persistentRecords=[NSMutableDictionary dictionary];
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *directory=[support URLByAppendingPathComponent:@"CCTVHost" isDirectory:YES];
        if(directory){[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];_persistentPath=[[directory URLByAppendingPathComponent:@"MediaMetadataCache-v1.json"] path];}
        [self loadPersistentRecords];
    }
    return self;
}
- (void)loadPersistentRecords {
    if(!self.persistentPath.length)return;
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:self.persistentPath error:NULL];
    if([attributes[NSFileSize] unsignedLongLongValue]>MediaMetadataPersistentByteLimit+256*1024){[NSFileManager.defaultManager removeItemAtPath:self.persistentPath error:NULL];return;}
    NSData *data=[NSData dataWithContentsOfFile:self.persistentPath options:NSDataReadingMappedIfSafe error:NULL];
    NSDictionary *root=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
    if(![root isKindOfClass:NSDictionary.class])return;
    NSDictionary *records=[root[@"records"] isKindOfClass:NSDictionary.class]?root[@"records"]:@{};
    NSMutableArray<NSDictionary *> *valid=[NSMutableArray array];NSUInteger total=0;
    for(id key in records){NSDictionary *record=[records[key] isKindOfClass:NSDictionary.class]?records[key]:nil;id result=record[@"result"];NSString *sourceID=[record[@"source_id"] isKindOfClass:NSString.class]?record[@"source_id"]:@"";NSTimeInterval storedAt=[record[@"stored_at"] doubleValue];NSData *encoded=result?[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL]:nil;
        if(![key isKindOfClass:NSString.class]||[key length]!=64||!sourceID.length||storedAt<=0||!encoded.length||encoded.length>MediaMetadataCacheSingleEntryLimit)continue;
        NSString *operation=[record[@"operation"] isKindOfClass:NSString.class]?record[@"operation"]:@"";
        if(![@[@"home",@"category"] containsObject:operation])continue;
        id safeResult=MediaMetadataPersistentSafeValue(result,@"",0);NSData *safeData=safeResult?[NSJSONSerialization dataWithJSONObject:safeResult options:0 error:NULL]:nil;
        if(!safeData.length||safeData.length>MediaMetadataCacheSingleEntryLimit)continue;
        [valid addObject:@{@"key":key,@"record":@{@"source_id":sourceID,@"stored_at":@(storedAt),@"operation":operation,@"result":safeResult},@"cost":@(safeData.length)}];
    }
    [valid sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"record"][@"stored_at"] compare:b[@"record"][@"stored_at"]];}];
    for(NSDictionary *entry in [valid reverseObjectEnumerator]){NSUInteger cost=[entry[@"cost"] unsignedIntegerValue];if(self.persistentRecords.count>=MediaMetadataPersistentEntryLimit||total+cost>MediaMetadataPersistentByteLimit)continue;self.persistentRecords[entry[@"key"]]=entry[@"record"];total+=cost;}
    if([root[@"version"] integerValue]!=1||self.persistentRecords.count!=records.count)[self schedulePersistentWrite];
}
- (void)schedulePersistentWrite {
    if(!self.persistentPath.length)return;
    dispatch_async(self.persistenceQueue,^{
        if(self.persistenceWriteScheduled)return;
        self.persistenceWriteScheduled=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_MSEC),self.persistenceQueue,^{
            __block NSDictionary *records=nil;dispatch_sync(self.queue,^{records=[self.persistentRecords copy];});
            NSDictionary *root=@{@"version":@1,@"records":records?:@{}};NSData *data=[NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
            if(data.length&&data.length<=MediaMetadataPersistentByteLimit+256*1024)[data writeToFile:self.persistentPath options:NSDataWritingAtomic error:NULL];
            self.persistenceWriteScheduled=NO;
        });
    });
}
- (NSString *)keyForSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments {
    NSDictionary *identity=@{ @"id":[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:@"",
        @"port":[source[@"port"] respondsToSelector:@selector(stringValue)]?[source[@"port"] stringValue]:@"",
        @"protocol":[source[@"protocol"] isKindOfClass:NSString.class]?source[@"protocol"]:@"",
        @"packageRoot":[source[@"packageRoot"] isKindOfClass:NSString.class]?source[@"packageRoot"]:@"",
        @"api":[source[@"api"] isKindOfClass:NSString.class]?source[@"api"]:@"",
        @"header":source[@"header"]?:@{},@"playUrl":[source[@"playUrl"] isKindOfClass:NSString.class]?source[@"playUrl"]:@"",
        @"options":source[@"options"]?:@"",@"tvboxType":source[@"tvboxType"]?:@0,
        @"operation":operation?:@"", @"arguments":arguments?:@{} };
    NSData *data=[NSJSONSerialization dataWithJSONObject:identity options:NSJSONWritingSortedKeys error:NULL];
    if(!data.length)return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
- (id)resultForSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments maximumAge:(NSTimeInterval)maximumAge isStale:(BOOL *)isStale {
    if(isStale)*isStale=NO;
    if(![@[@"home",@"category",@"search"] containsObject:operation])return nil;
    NSString *key=[self keyForSource:source operation:operation arguments:arguments];if(!key.length)return nil;
    __block MediaMetadataCacheEntry *entry=nil;
    dispatch_sync(self.queue, ^{
        entry=[self.entries objectForKey:key];
        if(!entry&&[@[@"home",@"category"] containsObject:operation]){NSDictionary *record=self.persistentRecords[key];if(record){entry=[MediaMetadataCacheEntry new];entry.result=record[@"result"];entry.sourceID=record[@"source_id"];entry.storedAt=[record[@"stored_at"] doubleValue];NSData *encoded=[NSJSONSerialization dataWithJSONObject:entry.result options:0 error:NULL];entry.cost=encoded.length;[self.entries setObject:entry forKey:key cost:entry.cost];}}
        if(entry)self.order[key]=@(NSDate.date.timeIntervalSince1970);
    });
    if(!entry)return nil;
    NSTimeInterval age=NSDate.date.timeIntervalSince1970-entry.storedAt;
    if(age<0||age>MAX(0,maximumAge))return nil;
    if(isStale)*isStale=age>MediaMetadataFreshLifetime;
    return entry.result;
}
- (void)storeResult:(id)result forSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments {
    if(!result||![@[@"home",@"category",@"search"] containsObject:operation])return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    if(!data.length||data.length>MediaMetadataCacheSingleEntryLimit)return;
    NSString *key=[self keyForSource:source operation:operation arguments:arguments];if(!key.length)return;
    MediaMetadataCacheEntry *entry=[MediaMetadataCacheEntry new];entry.result=result;entry.sourceID=[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:@"";entry.storedAt=NSDate.date.timeIntervalSince1970;entry.cost=data.length;
    BOOL persist=[@[@"home",@"category"] containsObject:operation];id persistentResult=persist?MediaMetadataPersistentSafeValue(result,@"",0):nil;NSData *persistentData=persistentResult?[NSJSONSerialization dataWithJSONObject:persistentResult options:0 error:NULL]:nil;persist=persist&&persistentData.length&&persistentData.length<=MediaMetadataCacheSingleEntryLimit;
    __block BOOL persistenceChanged=NO;
    dispatch_sync(self.queue, ^{
        [self.entries setObject:entry forKey:key cost:entry.cost];self.order[key]=@(entry.storedAt);
        while(self.order.count>MediaMetadataCacheEntryLimit){
            NSString *oldest=[self.order keysSortedByValueUsingSelector:@selector(compare:)].firstObject;
            if(!oldest)break;[self.entries removeObjectForKey:oldest];[self.order removeObjectForKey:oldest];
        }
        if(persist){self.persistentRecords[key]=@{@"source_id":entry.sourceID,@"stored_at":@(entry.storedAt),@"operation":operation,@"result":persistentResult};persistenceChanged=YES;NSArray *oldestFirst=[self.persistentRecords keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"stored_at"] compare:b[@"stored_at"]];}];NSUInteger total=0;NSUInteger retained=0;for(NSString *candidate in [oldestFirst reverseObjectEnumerator]){NSDictionary *record=self.persistentRecords[candidate];NSData *encoded=[NSJSONSerialization dataWithJSONObject:record[@"result"] options:0 error:NULL];NSUInteger cost=encoded.length;if(retained>=MediaMetadataPersistentEntryLimit||total+cost>MediaMetadataPersistentByteLimit){[self.persistentRecords removeObjectForKey:candidate];[self.entries removeObjectForKey:candidate];[self.order removeObjectForKey:candidate];persistenceChanged=YES;continue;}retained++;total+=cost;}}
        else if(self.persistentRecords[key]){[self.persistentRecords removeObjectForKey:key];persistenceChanged=YES;}
    });
    if(persistenceChanged)[self schedulePersistentWrite];
}
- (void)removeResultsForSourceID:(NSString *)sourceID {
    if(!sourceID.length)return;
    dispatch_sync(self.queue, ^{for(NSString *key in self.order.allKeys.copy){MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];if(!entry||[entry.sourceID isEqual:sourceID]){[self.entries removeObjectForKey:key];[self.order removeObjectForKey:key];}}for(NSString *key in self.persistentRecords.allKeys.copy)if([self.persistentRecords[key][@"source_id"] isEqual:sourceID])[self.persistentRecords removeObjectForKey:key];});
    [self schedulePersistentWrite];
}
- (NSDictionary<NSString *,NSNumber *> *)summary {
    __block NSUInteger bytes=0,count=0;
    dispatch_sync(self.queue, ^{
        for(NSString *key in self.persistentRecords){NSDictionary *record=self.persistentRecords[key];NSData *data=[NSJSONSerialization dataWithJSONObject:record[@"result"] options:0 error:NULL];if(data.length){count++;bytes+=data.length;}}
        for(NSString *key in self.order){if(self.persistentRecords[key])continue;MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];if(!entry)continue;count++;bytes+=entry.cost;}
    });
    return @{@"entries":@(count),@"bytes":@(bytes)};
}
- (void)clear { dispatch_sync(self.queue, ^{[self.entries removeAllObjects];[self.order removeAllObjects];[self.persistentRecords removeAllObjects];});[self schedulePersistentWrite]; }
@end
