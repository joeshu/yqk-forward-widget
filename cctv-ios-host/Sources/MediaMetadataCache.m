#import "MediaMetadataCache.h"
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger MediaMetadataCacheEntryLimit = 64;
static const NSUInteger MediaMetadataCacheByteLimit = 8 * 1024 * 1024;
static const NSUInteger MediaMetadataCacheSingleEntryLimit = 1024 * 1024;
static const NSTimeInterval MediaMetadataFreshLifetime = 5 * 60;

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
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *order;
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
        _order=[NSMutableDictionary dictionary];
    }
    return self;
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
    dispatch_sync(self.queue, ^{ entry=[self.entries objectForKey:key]; if(entry)self.order[key]=@(NSDate.date.timeIntervalSince1970); });
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
    dispatch_sync(self.queue, ^{
        [self.entries setObject:entry forKey:key cost:entry.cost];self.order[key]=@(entry.storedAt);
        while(self.order.count>MediaMetadataCacheEntryLimit){
            NSString *oldest=[self.order keysSortedByValueUsingSelector:@selector(compare:)].firstObject;
            if(!oldest)break;[self.entries removeObjectForKey:oldest];[self.order removeObjectForKey:oldest];
        }
    });
}
- (void)removeResultsForSourceID:(NSString *)sourceID {
    if(!sourceID.length)return;
    dispatch_sync(self.queue, ^{for(NSString *key in self.order.allKeys.copy){MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];if(!entry||[entry.sourceID isEqual:sourceID]){[self.entries removeObjectForKey:key];[self.order removeObjectForKey:key];}}});
}
- (NSDictionary<NSString *,NSNumber *> *)summary {
    __block NSUInteger bytes=0,count=0;
    dispatch_sync(self.queue, ^{for(NSString *key in self.order){MediaMetadataCacheEntry *entry=[self.entries objectForKey:key];if(!entry)continue;count++;bytes+=entry.cost;}});
    return @{@"entries":@(count),@"bytes":@(bytes)};
}
- (void)clear { dispatch_sync(self.queue, ^{[self.entries removeAllObjects];[self.order removeAllObjects];}); }
@end
