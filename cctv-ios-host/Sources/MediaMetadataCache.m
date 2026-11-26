#import "MediaMetadataCache.h"
#import "RuntimeDiagnostics.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger MediaMetadataCacheEntryLimit = 64;
static const NSUInteger MediaMetadataCacheByteLimit = 8 * 1024 * 1024;
static const NSUInteger MediaMetadataCacheSingleEntryLimit = 1024 * 1024;
static const NSUInteger MediaMetadataPersistentEntryLimit = 32;
static const NSUInteger MediaMetadataPersistentByteLimit = 4 * 1024 * 1024;
static const NSTimeInterval MediaMetadataFreshLifetime = 5 * 60;
static const NSTimeInterval MediaDetailFreshLifetime = 60;

// Detail is memory-only and short-lived. Do not keep signed episode URLs,
// localhost proxy tokens or credentials across page visits.
static BOOL MediaDetailContainsTransientAddress(id value, NSUInteger depth) {
    if(depth>24)return YES;
    if([value isKindOfClass:NSDictionary.class]){
        for(id key in value){
            if(![key isKindOfClass:NSString.class])return YES;
            NSString *lower=[key lowercaseString];
            if([@[@"cookie",@"authorization",@"header",@"headers",@"customheaders",@"drmkey",@"token"] containsObject:lower])return YES;
            if(MediaDetailContainsTransientAddress(value[key],depth+1))return YES;
        }
    }else if([value isKindOfClass:NSArray.class]){
        for(id child in value)if(MediaDetailContainsTransientAddress(child,depth+1))return YES;
    }else if([value isKindOfClass:NSString.class]){
        NSString *lower=[value lowercaseString];
        if([lower containsString:@"token="]||[lower containsString:@"sign="]||[lower containsString:@"signature="]||[lower containsString:@"auth="])return YES;
        NSURLComponents *url=[NSURLComponents componentsWithString:value];
        if(url.user.length||url.password.length)return YES;
        NSString *host=url.host.lowercaseString;
        if([@[@"127.0.0.1",@"localhost",@"::1"] containsObject:host])return YES;
        for(NSURLQueryItem *item in url.queryItems){
            NSString *name=item.name.lowercaseString;
            for(NSString *marker in @[@"token",@"sign",@"auth",@"secret",@"credential",@"password",@"expire"])
                if([name containsString:marker])return YES;
            if([name isEqual:@"key"]||[name isEqual:@"policy"])return YES;
        }
    }
    return NO;
}

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
-  (void)loadPersistentRecordsAsync;
-  (void)loadPersistentRecords;
-  (void)schedulePersistentWrite;
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
        if(directory){[NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];[NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:@"MediaMetadataCache-v1.json"] error:NULL];[NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:@"MediaMetadataCache-v2.json"] error:NULL];_persistentPath=[[directory URLByAppendingPathComponent:@"MediaMetadataCache-v3.json"] path];}
        [self loadPersistentRecordsAsync];
#if TARGET_OS_IOS
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(evictMemoryCache) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
    return self;
}
- (void)loadPersistentRecordsAsync {
    // T19/PERF-09：冷启动持久化加载（读文件 + JSON 解析 + 逐条校验/序列化 + 排序）
    // 不再阻塞首次访问的调用线程；加载完成前读缓存只会 miss（缓存语义安全）。
    dispatch_async(self.persistenceQueue, ^{ [self loadPersistentRecords]; });
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
    for(id key in records){NSDictionary *record=[records[key] isKindOfClass:NSDictionary.class]?records[key]:nil;id result=record[@"result"];NSString *sourceID=[record[@"source_id"] isKindOfClass:NSString.class]?record[@"source_id"]:@"";NSTimeInterval storedAt=[record[@"stored_at"] doubleValue];
        if(![key isKindOfClass:NSString.class]||[key length]!=64||!sourceID.length||storedAt<=0||!result)continue;
        NSString *operation=[record[@"operation"] isKindOfClass:NSString.class]?record[@"operation"]:@"";
        if(![@[@"home",@"category"] containsObject:operation])continue;
        id safeResult=MediaMetadataPersistentSafeValue(result,@"",0);
        if(!safeResult)continue;
        NSUInteger savedCost=[record[@"cost"] isKindOfClass:NSNumber.class]?[record[@"cost"] unsignedIntegerValue]:0;
        NSData *safeData=(savedCost>0&&savedCost<=MediaMetadataCacheSingleEntryLimit&&[safeResult isEqual:result])?nil:[NSJSONSerialization dataWithJSONObject:safeResult options:0 error:NULL];
        NSUInteger resolvedCost=safeData?safeData.length:savedCost;
        if(!resolvedCost||resolvedCost>MediaMetadataCacheSingleEntryLimit)continue;
        [valid addObject:@{@"key":key,@"record":@{@"source_id":sourceID,@"stored_at":@(storedAt),@"operation":operation,@"result":safeResult,@"cost":@(resolvedCost)},@"cost":@(resolvedCost)}];
    }
    [valid sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [(a[@"record"][@"last_access"] ?: a[@"record"][@"stored_at"]) compare:(b[@"record"][@"last_access"] ?: b[@"record"][@"stored_at"])];}];
    NSMutableDictionary *loaded=[NSMutableDictionary dictionary];
    for(NSDictionary *entry in [valid reverseObjectEnumerator]){NSUInteger cost=[entry[@"cost"] unsignedIntegerValue];if(loaded.count>=MediaMetadataPersistentEntryLimit||total+cost>MediaMetadataPersistentByteLimit)continue;loaded[entry[@"key"]]=entry[@"record"];total+=cost;}
    // T19/PERF-09：发布走协调队列，且只补不存在的 key——加载期间 storeResult 已写入
    // 的新记录不被磁盘旧值覆盖。
    dispatch_sync(self.queue, ^{for(NSString *key in loaded)if(!self.persistentRecords[key])self.persistentRecords[key]=loaded[key];});
    if([root[@"version"] integerValue]!=1||loaded.count!=records.count)[self schedulePersistentWrite];
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
/// 连接配置身份（T04/M04：统一 revision 的唯一定义）。只取决定连接行为的字段，
/// 显示名等展示字段不参与。keyForSource 与指纹函数共用它，缓存键字节保持不变。
static NSDictionary *MediaSourceConnectionIdentity(NSDictionary *source) {
    if(![source isKindOfClass:NSDictionary.class])source=@{};
    return @{ @"id":[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:@"",
        @"port":[source[@"port"] respondsToSelector:@selector(stringValue)]?[source[@"port"] stringValue]:@"",
        @"protocol":[source[@"protocol"] isKindOfClass:NSString.class]?source[@"protocol"]:@"",
        @"packageRoot":[source[@"packageRoot"] isKindOfClass:NSString.class]?source[@"packageRoot"]:@"",
        @"api":[source[@"api"] isKindOfClass:NSString.class]?source[@"api"]:@"",
        @"header":source[@"header"]?:@{},@"headers":source[@"headers"]?:@{},@"manifest":source[@"manifest"]?:@{},@"playUrl":[source[@"playUrl"] isKindOfClass:NSString.class]?source[@"playUrl"]:@"",
        @"options":source[@"options"]?:@"",@"tvboxType":source[@"tvboxType"]?:@0,
        @"jar":[source[@"jar"] isKindOfClass:NSDictionary.class]?source[@"jar"]:@{},
        @"subscriptionURL":[source[@"subscriptionURL"] isKindOfClass:NSString.class]?source[@"subscriptionURL"]:@"" };
}
static NSString *MediaSourceSHA256Hex(NSData *data) {
    if(!data.length)return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
NSString *MediaSourceConnectionFingerprint(NSDictionary *source) {
    if(![source isKindOfClass:NSDictionary.class])return @"";
    NSData *data=[NSJSONSerialization dataWithJSONObject:MediaSourceConnectionIdentity(source) options:NSJSONWritingSortedKeys error:NULL];
    return MediaSourceSHA256Hex(data);
}
NSUInteger MediaSourceConnectionRevision(NSDictionary *source) {
    NSString *fingerprint=MediaSourceConnectionFingerprint(source);
    if(fingerprint.length<8)return 0;
    unsigned long long value=0;NSScanner *scanner=[NSScanner scannerWithString:[fingerprint substringToIndex:8]];
    if(![scanner scanHexLongLong:&value])return 0;
    return (NSUInteger)value;
}
- (NSString *)keyForSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments {
    NSMutableDictionary *cleanArgs=[NSMutableDictionary dictionary];
    if([arguments isKindOfClass:NSDictionary.class]){
        for(id k in arguments){
            if([k isEqual:@"refresh"]||[k isEqual:@"forceRefresh"])continue;
            cleanArgs[k]=arguments[k];
        }
    }
    NSMutableDictionary *identity=[MediaSourceConnectionIdentity(source) mutableCopy];
    identity[@"operation"]=operation?:@"";
    identity[@"arguments"]=cleanArgs;
    NSData *data=[NSJSONSerialization dataWithJSONObject:identity options:NSJSONWritingSortedKeys error:NULL];
    if(!data.length)return nil;
    return MediaSourceSHA256Hex(data);
}
- (id)resultForSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments maximumAge:(NSTimeInterval)maximumAge isStale:(BOOL *)isStale {
    if(isStale)*isStale=NO;
    if(![@[@"home",@"category",@"search",@"detail"] containsObject:operation])return nil;
    NSString *key=[self keyForSource:source operation:operation arguments:arguments];if(!key.length)return nil;
    __block MediaMetadataCacheEntry *entry=nil;
    // T19/PERF-09：先测——记录同步等待耗时与命中/未命中（诊断开启时才记，平时只有一次时钟读取）。
    CFTimeInterval readStartedAt=CFAbsoluteTimeGetCurrent();
    dispatch_sync(self.queue, ^{
        entry=[self.entries objectForKey:key];
        if(!entry&&[@[@"home",@"category"] containsObject:operation]){NSDictionary *record=self.persistentRecords[key];if(record){entry=[MediaMetadataCacheEntry new];entry.result=record[@"result"];entry.sourceID=record[@"source_id"];entry.storedAt=[record[@"stored_at"] doubleValue];NSUInteger cachedCost=[record[@"cost"] unsignedIntegerValue];if(cachedCost){entry.cost=cachedCost;[self.entries setObject:entry forKey:key cost:entry.cost];}}}
        // T19/PERF-09：cost 未知的持久记录不再在同步块里序列化求 cost（调用线程
        // 等待），只返回结果、不提升进内存缓存；cost 总是由 store/load 路径写入，
        // 未知只出现在损坏记录上。order 只记已提升的条目。
        if(entry){NSTimeInterval accessed=NSDate.date.timeIntervalSince1970;if([self.entries objectForKey:key])self.order[key]=@(accessed);NSMutableDictionary *record=[self.persistentRecords[key] mutableCopy];if(record){record[@"last_access"]=@(accessed);self.persistentRecords[key]=record;[self schedulePersistentWrite];}}
    });
    if(RuntimeDiagnostics.shared.enabled){[RuntimeDiagnostics.shared recordEvent:@"media_metadata_cache_read" category:@"media_api" fields:@{@"operation":operation?:@"",@"hit":@(entry!=nil),@"elapsed_ms":@((NSInteger)(MAX(0,CFAbsoluteTimeGetCurrent()-readStartedAt)*1000))}];}
    if(!entry)return nil;
    NSTimeInterval age=NSDate.date.timeIntervalSince1970-entry.storedAt;
    if(age<0||age>MAX(0,maximumAge))return nil;
    if(isStale)*isStale=age>([operation isEqual:@"detail"]?MediaDetailFreshLifetime:MediaMetadataFreshLifetime);
    return entry.result;
}
- (void)storeResult:(id)result forSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments {
    if(!result||![@[@"home",@"category",@"search",@"detail"] containsObject:operation])return;
    NSString *key=[self keyForSource:source operation:operation arguments:arguments];if(!key.length)return;
    if([operation isEqual:@"detail"]&&MediaDetailContainsTransientAddress(result,0)){
        dispatch_sync(self.queue,^{[self.entries removeObjectForKey:key];[self.order removeObjectForKey:key];});
        return;
    }
    // T19/PERF-09：先测——序列化 + 同步等待耗时（诊断开启时才记）。
    CFTimeInterval storeStartedAt=CFAbsoluteTimeGetCurrent();
    NSData *data=[NSJSONSerialization isValidJSONObject:result]?[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL]:nil;
    if(!data.length||data.length>MediaMetadataCacheSingleEntryLimit){
        if([operation isEqual:@"detail"])dispatch_sync(self.queue,^{[self.entries removeObjectForKey:key];[self.order removeObjectForKey:key];});
        return;
    }
    MediaMetadataCacheEntry *entry=[MediaMetadataCacheEntry new];entry.result=result;entry.sourceID=[source[@"id"] isKindOfClass:NSString.class]?source[@"id"]:@"";entry.storedAt=NSDate.date.timeIntervalSince1970;entry.cost=data.length;
    BOOL persist=[@[@"home",@"category"] containsObject:operation];id persistentResult=persist?MediaMetadataPersistentSafeValue(result,@"",0):nil;NSData *persistentData=persistentResult?([persistentResult isEqual:result]?data:[NSJSONSerialization dataWithJSONObject:persistentResult options:0 error:NULL]):nil;persist=persist&&persistentData.length&&persistentData.length<=MediaMetadataCacheSingleEntryLimit;
    __block BOOL persistenceChanged=NO;
    dispatch_sync(self.queue, ^{
        [self.entries setObject:entry forKey:key cost:entry.cost];self.order[key]=@(entry.storedAt);
        while(self.order.count>MediaMetadataCacheEntryLimit){
            NSString *oldest=[self.order keysSortedByValueUsingSelector:@selector(compare:)].firstObject;
            if(!oldest)break;[self.entries removeObjectForKey:oldest];[self.order removeObjectForKey:oldest];
        }
        if(persist){self.persistentRecords[key]=@{@"source_id":entry.sourceID,@"stored_at":@(entry.storedAt),@"operation":operation,@"result":persistentResult,@"cost":@(persistentData.length)};persistenceChanged=YES;NSArray *oldestFirst=[self.persistentRecords keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [(a[@"last_access"] ?: a[@"stored_at"]) compare:(b[@"last_access"] ?: b[@"stored_at"])];}];NSUInteger total=0;NSUInteger retained=0;for(NSString *candidate in [oldestFirst reverseObjectEnumerator]){NSDictionary *record=self.persistentRecords[candidate];NSUInteger cost=[record[@"cost"] unsignedIntegerValue];if(!cost){[self.persistentRecords removeObjectForKey:candidate];[self.entries removeObjectForKey:candidate];[self.order removeObjectForKey:candidate];persistenceChanged=YES;continue;}if(retained>=MediaMetadataPersistentEntryLimit||total+cost>MediaMetadataPersistentByteLimit){[self.persistentRecords removeObjectForKey:candidate];[self.entries removeObjectForKey:candidate];[self.order removeObjectForKey:candidate];persistenceChanged=YES;continue;}retained++;total+=cost;}}
        else if(self.persistentRecords[key]){[self.persistentRecords removeObjectForKey:key];persistenceChanged=YES;}
    });
    if(persistenceChanged)[self schedulePersistentWrite];
    // T19/PERF-09：先测——序列化 + 同步等待耗时（诊断开启时才记）。
    if(RuntimeDiagnostics.shared.enabled){[RuntimeDiagnostics.shared recordEvent:@"media_metadata_cache_store" category:@"media_api" fields:@{@"operation":operation?:@"",@"bytes":@(data.length),@"elapsed_ms":@((NSInteger)(MAX(0,CFAbsoluteTimeGetCurrent()-storeStartedAt)*1000))}];}
}
- (NSTimeInterval)ageOfResultForSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments {
    if(![@[@"home",@"category",@"search",@"detail"] containsObject:operation])return -1;
    NSString *key=[self keyForSource:source operation:operation arguments:arguments];if(!key.length)return -1;
    __block NSTimeInterval storedAt=-1;
    dispatch_sync(self.queue, ^{
        MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];
        if(entry)storedAt=entry.storedAt;
        else if([@[@"home",@"category"] containsObject:operation]){NSDictionary *record=self.persistentRecords[key];if(record)storedAt=[record[@"stored_at"] doubleValue];}
    });
    if(storedAt<=0)return -1;
    NSTimeInterval age=NSDate.date.timeIntervalSince1970-storedAt;
    return age<0?-1:age;
}
- (void)removeResultForSource:(NSDictionary *)source operation:(NSString *)operation arguments:(NSDictionary *)arguments {
    NSString *key=[self keyForSource:source operation:operation arguments:arguments];
    if(!key.length)return;
    __block BOOL removedPersistent=NO;
    dispatch_sync(self.queue, ^{
        [self.entries removeObjectForKey:key];
        [self.order removeObjectForKey:key];
        if(self.persistentRecords[key]){
            [self.persistentRecords removeObjectForKey:key];
            removedPersistent=YES;
        }
    });
    if(removedPersistent)[self schedulePersistentWrite];
}
- (void)removeResultsForSourceID:(NSString *)sourceID {
    if(!sourceID.length)return;
    dispatch_sync(self.queue, ^{for(NSString *key in self.order.allKeys.copy){MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];if(!entry||[entry.sourceID isEqual:sourceID]){[self.entries removeObjectForKey:key];[self.order removeObjectForKey:key];}}for(NSString *key in self.persistentRecords.allKeys.copy)if([self.persistentRecords[key][@"source_id"] isEqual:sourceID])[self.persistentRecords removeObjectForKey:key];});
    [self schedulePersistentWrite];
}
- (NSDictionary<NSString *,NSNumber *> *)summary {
    __block NSUInteger bytes=0,count=0;
    dispatch_sync(self.queue, ^{
        for(NSString *key in self.persistentRecords){NSDictionary *record=self.persistentRecords[key];NSUInteger cost=[record[@"cost"] unsignedIntegerValue];if(!cost){NSData *data=[NSJSONSerialization dataWithJSONObject:record[@"result"] options:0 error:NULL];cost=data.length;}if(cost){count++;bytes+=cost;}}
        for(NSString *key in self.order){if(self.persistentRecords[key])continue;MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];if(!entry)continue;count++;bytes+=entry.cost;}
    });
    return @{@"entries":@(count),@"bytes":@(bytes)};
}
- (void)evictMemoryCache { dispatch_async(self.queue, ^{[self.entries removeAllObjects];[self.order removeAllObjects];}); }
- (void)clear { dispatch_sync(self.queue, ^{[self.entries removeAllObjects];[self.order removeAllObjects];[self.persistentRecords removeAllObjects];});[self schedulePersistentWrite]; }
@end
